import Foundation

/// Turns build or test output into a short list of failures, keeping the raw output on this Mac
/// ([ADR 0023](../../../../docs/decisions/0023-condensing-tools.md)).
///
/// The output is captured whole (bounded), cut into chunks a small model can read, and each chunk is
/// judged in a fresh, tool-less model turn with a schema, so the answer is data. The lists are merged,
/// duplicates dropped, and the result capped. The model never sees the whole output at once and the
/// caller never sees any of it.
public struct Triage: Sendable {
    /// Knobs for one triage.
    public struct Options: Equatable, Sendable {
        /// Bytes per chunk shown to the model; cut at line ends.
        public var chunkBytes: Int
        /// Findings kept after merging; the rest is reported as `more`.
        public var maxFindings: Int
        /// Bytes of output captured; only the tail beyond this.
        public var maxOutputBytes: Int

        /// Creates options; the defaults suit a model with a 4k-token window.
        public init(chunkBytes: Int = 4096, maxFindings: Int = 20, maxOutputBytes: Int = 1 << 20) {
            self.chunkBytes = chunkBytes
            self.maxFindings = maxFindings
            self.maxOutputBytes = maxOutputBytes
        }
    }

    /// Where the output comes from.
    public enum Source: Equatable, Sendable {
        /// Run this command line, under the policy, gate, and sandbox, and triage what it prints.
        case command(String, workingDirectory: String?)
        /// Triage a file already on this Mac.
        case path(String)

        /// What to call the output in prompts and results.
        public var label: String {
            switch self {
            case .command(let line, _): "the command `\(line)`"
            case .path(let path): "the file \(path)"
            }
        }
    }

    /// One failure the model reported.
    public struct Finding: Equatable, Sendable {
        /// `error`, `test-failure`, `warning`, `crash`, or `other`.
        public var kind: String
        /// `file:line`, a test name, or nil when the output gave none.
        public var location: String?
        /// The failure in one line.
        public var message: String

        /// Creates a finding.
        public init(kind: String, location: String?, message: String) {
            self.kind = kind
            self.location = location
            self.message = message
        }

        /// What two findings must share to be the same one.
        var key: String {
            let place = (location ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return "\(kind)|\(place)|\(message.trimmingCharacters(in: .whitespaces).lowercased())"
        }
    }

    /// The captured output and how it came to be.
    public struct Captured: Equatable, Sendable {
        /// The text to triage.
        public var text: String
        /// The command's exit status; nil for a file.
        public var exitStatus: Int32?
        /// Whether the command hit its timeout.
        public var timedOut: Bool
        /// Whether leading bytes were dropped to fit `maxOutputBytes`.
        public var truncated: Bool

        /// A command's outcome as a capture: standard output, then standard error on a line of its own.
        public init(_ outcome: CommandRunner.Outcome) {
            var text = outcome.stdout
            if !outcome.stderr.isEmpty {
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += outcome.stderr
            }
            self.init(
                text: text, exitStatus: outcome.exitStatus, timedOut: outcome.timedOut, truncated: outcome.truncated)
        }

        /// Creates a capture.
        public init(text: String, exitStatus: Int32? = nil, timedOut: Bool = false, truncated: Bool = false) {
            self.text = text
            self.exitStatus = exitStatus
            self.timedOut = timedOut
            self.truncated = truncated
        }
    }

    /// The result of a triage.
    public struct Report: Equatable, Sendable {
        /// What was triaged.
        public var source: Source
        /// How the output was captured.
        public var captured: Captured
        /// How many chunks the output was cut into.
        public var chunks: Int
        /// The failures, deduplicated, in the order first seen.
        public var findings: [Finding]
        /// Whether findings beyond `maxFindings` were dropped.
        public var more: Bool
        /// Chunks whose failures `KnownFailures` read exactly, needing no model turn.
        public var exactChunks = 0

        /// The report as JSON, the shape the MCP tool returns (`docs/mcp.md`).
        public var json: JSONValue {
            var source: [String: JSONValue]
            switch self.source {
            case .command(let line, let directory):
                source = ["command": .string(line), "workingDirectory": directory.map { .string($0) } ?? .null]
            case .path(let path):
                source = ["path": .string(path)]
            }
            source["exitStatus"] = captured.exitStatus.map { .int(Int($0)) } ?? .null
            source["timedOut"] = .bool(captured.timedOut)
            source["truncated"] = .bool(captured.truncated)
            source["bytes"] = .int(captured.text.utf8.count)
            return .object([
                "source": .object(source), "chunks": .int(chunks), "exactChunks": .int(exactChunks),
                "more": .bool(more),
                "findings": .array(
                    findings.map {
                        .object([
                            "kind": .string($0.kind), "location": $0.location.map { .string($0) } ?? .null,
                            "message": .string($0.message),
                        ])
                    }),
            ])
        }

        /// The report as lines for a reader: a headline, then one finding per line.
        public var rendered: String {
            var head: [String] = []
            if let status = captured.exitStatus { head.append("exit status \(status)") }
            if captured.timedOut { head.append("timed out") }
            head.append("\(findings.count)\(more ? "+" : "") finding\(findings.count == 1 ? "" : "s")")
            head.append("\(captured.text.utf8.count) bytes in \(chunks) chunk\(chunks == 1 ? "" : "s")")
            if exactChunks > 0 { head.append("\(exactChunks) read exactly") }
            if captured.truncated { head.append("output truncated to its tail") }
            var lines = [head.joined(separator: "; ")]
            for finding in findings {
                lines.append("\(finding.kind)\t\(finding.location ?? "-")\t\(finding.message)")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Answers one chunk's prompt with JSON of `Triage.schemaJSON`'s shape.
    public typealias Judge = @Sendable (String) async throws -> String

    /// The shape each chunk's answer must take.
    public static let schemaJSON: JSONValue = [
        "type": "object",
        "properties": [
            "failures": [
                "type": "array", "maxItems": 20,
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": [
                            "type": "string", "enum": ["error", "test-failure", "warning", "crash", "other"],
                            "description": "What kind of failure",
                        ],
                        "location": [
                            "type": "string", "description": "file:line, or the test name, exactly as printed",
                        ],
                        "message": ["type": "string", "description": "The failure in one line"],
                    ],
                    "required": ["kind", "message"],
                ],
            ]
        ],
        "required": ["failures"],
    ]

    /// The options in force.
    public let options: Options
    /// Judges one chunk.
    private let judge: Judge

    /// Creates a triage that judges chunks with `judge`.
    ///
    /// - Parameters:
    ///   - options: Chunk size and caps.
    ///   - judge: Answers a chunk's prompt with JSON of the schema's shape; a fresh model turn each time.
    public init(options: Options = Options(), judge: @escaping Judge) {
        self.options = options
        self.judge = judge
    }

    /// Cuts `text` into pieces of at most `maxBytes` UTF-8 bytes at line ends; a line longer than that
    /// is cut mid-line. Empty text gives no chunks.
    public static func chunks(_ text: String, maxBytes: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentBytes = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var piece = Substring(line)
            while piece.utf8.count > maxBytes {
                let cut = String(decoding: piece.utf8.prefix(maxBytes), as: UTF8.self)
                if !current.isEmpty { chunks.append(current) }
                chunks.append(cut)
                current = ""
                currentBytes = 0
                piece = piece.dropFirst(cut.count)
            }
            let lineBytes = piece.utf8.count + (current.isEmpty ? 0 : 1)
            if currentBytes + lineBytes > maxBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentBytes = 0
            }
            if !current.isEmpty { current += "\n" }
            current += piece
            currentBytes = current.utf8.count
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }

    /// The prompt for one chunk.
    public static func prompt(chunk: String, index: Int, count: Int, label: String) -> String {
        """
        Below is part \(index) of \(count) of the output of \(label). List every failure it reports: \
        compiler errors, test failures, crashes, warnings. Give the kind, the file:line or test name as the \
        location exactly as printed when there is one, and the message in one line. Report nothing that is not \
        a failure; an empty list is a correct answer when nothing failed.

        OUTPUT:
        \(chunk)
        """
    }

    /// Reads the findings out of one chunk's JSON answer; anything malformed reads as none.
    public static func findings(in json: String) -> [Finding] {
        guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
            let items = value.objectValue?["failures"]?.arrayValue
        else { return [] }
        return items.compactMap { item in
            guard let fields = item.objectValue, let message = fields["message"]?.stringValue,
                !message.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let location = fields["location"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            return Finding(
                kind: fields["kind"]?.stringValue ?? "other", location: location?.isEmpty == false ? location : nil,
                message: message)
        }
    }

    /// Merges per-chunk findings in order, dropping duplicates and capping at `max`.
    public static func merge(_ lists: [[Finding]], max: Int) -> (findings: [Finding], more: Bool) {
        var seen: Set<String> = []
        var merged: [Finding] = []
        var dropped = false
        for finding in lists.joined() where seen.insert(finding.key).inserted {
            if merged.count < max { merged.append(finding) } else { dropped = true }
        }
        return (merged, dropped)
    }

    /// Reads every chunk of `captured` and merges the findings. `KnownFailures` reads each chunk first;
    /// a chunk it explains completely needs no model turn, and any other goes to the judge, whose
    /// findings follow the exact ones.
    ///
    /// - Parameters:
    ///   - captured: The output, however it was obtained.
    ///   - source: What it came from, for the prompt and the report.
    /// - Returns: The report.
    /// - Throws: Whatever the judge throws; one failed chunk fails the triage.
    public func run(_ captured: Captured, from source: Source) async throws -> Report {
        let pieces = Self.chunks(captured.text, maxBytes: options.chunkBytes)
        var lists: [[Finding]] = []
        var exact = 0
        for (index, piece) in pieces.enumerated() {
            let known = KnownFailures.scan(piece)
            lists.append(known.findings)
            if known.explainsEverything {
                exact += 1
                continue
            }
            let answer = try await judge(
                Self.prompt(chunk: piece, index: index + 1, count: pieces.count, label: source.label))
            // The model rewords what the rules already read exactly; keep the exact finding for a place.
            let located = Set(known.findings.compactMap { $0.location?.lowercased() })
            lists.append(Self.findings(in: answer).filter { !located.contains($0.location?.lowercased() ?? "") })
        }
        let merged = Self.merge(lists, max: options.maxFindings)
        return Report(
            source: source, captured: captured, chunks: pieces.count, findings: merged.findings, more: merged.more,
            exactChunks: exact)
    }

    /// Obtains the output for `source`: runs the command through `runner` (its policy, gate, sandbox,
    /// and audit apply), or reads the file after the gate clears the path. Keeps the tail beyond
    /// `options.maxOutputBytes`.
    ///
    /// - Parameters:
    ///   - source: What to capture.
    ///   - runner: Runs commands; its output cap is raised to `options.maxOutputBytes` for this run.
    ///   - gate: Clears file reads, as `read_file` does; nil skips the check.
    /// - Returns: The capture.
    /// - Throws: `CommandRunner.Failure`, `ApprovalGate.Failure`, or `FileFailure`.
    public func capture(_ source: Source, runner: CommandRunner, gate: ApprovalGate?) async throws -> Captured {
        try await Self.capture(source, runner: runner, gate: gate, maxOutputBytes: options.maxOutputBytes)
    }

    /// The capture every condensing tool shares; see the instance method.
    ///
    /// - Parameters:
    ///   - source: What to capture.
    ///   - runner: Runs commands.
    ///   - gate: Clears file reads; nil skips the check.
    ///   - maxOutputBytes: Bytes kept; only the tail beyond.
    /// - Returns: The capture.
    /// - Throws: `CommandRunner.Failure`, `ApprovalGate.Failure`, or `FileFailure`.
    public static func capture(
        _ source: Source, runner: CommandRunner, gate: ApprovalGate?, maxOutputBytes: Int
    ) async throws -> Captured {
        switch source {
        case .command(let line, let directory):
            var runner = runner
            runner.options.maxOutputBytes = maxOutputBytes
            return Captured(try await runner.run(line, in: directory))
        case .path(let path):
            try await gate?.clear(readingFile: path, workingDirectory: FileManager.default.currentDirectoryPath)
            let read = try readTail(of: path, maxBytes: maxOutputBytes)
            return Captured(text: String(decoding: read.data, as: UTF8.self), truncated: read.truncated)
        }
    }

    /// Why a `path` source could not be read.
    public enum FileFailure: Error, CustomStringConvertible, Equatable {
        /// The path, symlinks resolved, is not a regular file: a device (`/dev/zero` never ends), a FIFO (it
        /// waits for a writer), a socket, or a directory.
        case notARegularFile(path: String, kind: String)
        /// The file could not be opened or read.
        case unreadable(path: String, reason: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notARegularFile(let path, let kind):
                "\(path) is \(kind), not a regular file; only saved output files can be read"
            case .unreadable(let path, let reason): "cannot read \(path): \(reason)"
            }
        }
    }

    /// Reads the last `maxBytes` of the regular file at `path`, never more: symlinks are resolved, and anything
    /// that is not a regular file is refused before a byte is read, since a device or a FIFO never ends or
    /// never starts, and `/dev/stdin` under `wisp mcp` is the protocol channel. The file is opened without
    /// blocking and checked through its descriptor, so what is checked is what is read.
    ///
    /// - Parameters:
    ///   - path: The file.
    ///   - maxBytes: The most bytes read; a longer file is read from `size - maxBytes`.
    /// - Returns: The bytes, and whether the file was longer.
    /// - Throws: `FileFailure`.
    static func readTail(of path: String, maxBytes: Int) throws(FileFailure) -> (data: Data, truncated: Bool) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard lstat(resolved, &info) == 0 else {
            throw .unreadable(path: path, reason: String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile(path: path, kind: kind(info.st_mode)) }
        let descriptor = open(resolved, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw .unreadable(path: path, reason: String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw .notARegularFile(path: path, kind: kind(info.st_mode))
        }
        let size = UInt64(max(info.st_size, 0))
        let limit = UInt64(max(maxBytes, 0))
        let truncated = size > limit
        do {
            if truncated { try handle.seek(toOffset: size - limit) }
            let data = try handle.read(upToCount: Int(limit)) ?? Data()
            return (data, truncated)
        } catch {
            throw .unreadable(path: path, reason: "\(error.localizedDescription)")
        }
    }

    /// What a file mode names, for the refusal.
    private static func kind(_ mode: mode_t) -> String {
        switch mode & S_IFMT {
        case S_IFDIR: "a directory"
        case S_IFCHR: "a character device"
        case S_IFBLK: "a block device"
        case S_IFIFO: "a FIFO"
        case S_IFSOCK: "a socket"
        case S_IFLNK: "a symbolic link"
        default: "not a regular file"
        }
    }
}

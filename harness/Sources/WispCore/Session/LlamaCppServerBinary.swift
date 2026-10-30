import CryptoKit
import Foundation

/// The `llama-server` wisp's own llama.cpp server would run, and the person's approval of it
/// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 5).
///
/// `llamacpp.serverPath` in `config.json` names the file; never the first `llama-server` on `PATH`, and there is no
/// default. Setting it with `wisp config set` is the approval: wisp records the path as given, the real path it
/// resolves to, the SHA-256 of that file, and when, in `<support>/llamacpp/server.json`
/// (`~/Library/Application Support/Wisp/llamacpp/server.json`, owner only), out of `config.json`, so a path written
/// into the file by hand, or by anything else, is not approved. Before every start the server is checked against the
/// record (`check(_:)`): a different file at the path, as every `brew upgrade llama.cpp` makes, is refused until the
/// person sets the path again.
///
/// The digest covers the executable alone: the libraries `llama-server` loads from its install (Homebrew's
/// `libllama`, `libggml*`) are not checked.
public struct LlamaCppServerBinary: Equatable, Sendable {
    /// The setting that names the file, whose `wisp config set` approves it.
    public static let setting = "llamacpp.serverPath"

    /// What the person approved, as recorded in `server.json`.
    public struct Approval: Codable, Equatable, Sendable {
        /// The path as given, made absolute but not resolved: a Homebrew link such as
        /// `/opt/homebrew/bin/llama-server` stays the link.
        public var path: String
        /// The real path it resolved to when approved.
        public var resolved: String
        /// The SHA-256 of the resolved file, lower-case hex.
        public var sha256: String
        /// When it was approved.
        public var approved: Date

        /// Creates a record.
        public init(path: String, resolved: String, sha256: String, approved: Date) {
            self.path = path
            self.resolved = resolved
            self.sha256 = sha256
            self.approved = approved
        }
    }

    /// A file as read for approval or for a check: where the path resolves, and its digest.
    public struct Inspected: Equatable, Sendable {
        /// The path as given, made absolute.
        public var path: String
        /// The real file.
        public var resolved: URL
        /// Its SHA-256, lower-case hex.
        public var sha256: String
    }

    /// Why a path cannot be approved, as `wisp config set llamacpp.serverPath` says it.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Nothing is at the path.
        case notFound(String)
        /// What is there, resolved, is not a regular file.
        case notAFile(String, resolved: String)
        /// The file is not executable by this user.
        case notExecutable(String, resolved: String)
        /// The file does not begin with a Mach-O magic number.
        case notMachO(String, resolved: String)
        /// The file could not be read.
        case unreadable(String, reason: String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .notFound(let path): "nothing is at \(path); name the llama-server you want wisp to run"
            case .notAFile(let path, let resolved): "\(path) is not a file (it resolves to \(resolved))"
            case .notExecutable(let path, let resolved):
                "\(path) is not executable by you (it resolves to \(resolved))"
            case .notMachO(let path, let resolved):
                "\(path) is not a macOS executable: \(resolved) does not begin with a Mach-O header"
            case .unreadable(let path, let reason): "\(path) cannot be read: \(reason)"
            }
        }
    }

    /// Why wisp would not start the server named by the setting, as the check before each start and `wisp doctor`
    /// say it; each but `notSet` ends with the one command that approves the file now at the path.
    public enum Refusal: Error, CustomStringConvertible, Equatable {
        /// `llamacpp.serverPath` is not set.
        case notSet
        /// No approval is recorded, or the record cannot be read.
        case notApproved(path: String, reason: String?)
        /// The record approves another path: the setting was changed without `wisp config set`.
        case approvedOther(path: String, approved: String)
        /// The path resolves to another file than it did when approved.
        case moved(path: String, approved: String, now: String)
        /// The file the path resolves to is missing.
        case missing(path: String, resolved: String)
        /// The file is there and could not be read.
        case unreadable(path: String, reason: String)
        /// The file's digest is not the one approved.
        case changed(path: String, approved: String, now: String)

        /// A short name for the audit's `refusal` field.
        public var kind: String {
            switch self {
            case .notSet: "not set"
            case .notApproved: "not approved"
            case .approvedOther: "approved for another path"
            case .moved: "moved"
            case .missing: "missing"
            case .unreadable: "unreadable"
            case .changed: "changed"
            }
        }

        /// The path the setting names; nil when it is not set.
        public var path: String? {
            switch self {
            case .notSet: nil
            case .notApproved(let path, _), .approvedOther(let path, _), .moved(let path, _, _),
                .missing(let path, _), .unreadable(let path, _), .changed(let path, _, _):
                path
            }
        }

        /// The refusal as said to the person.
        public var description: String {
            let again = path.map { " approve the file now there with: \(LlamaCppServerBinary.command($0))" } ?? ""
            switch self {
            case .notSet:
                return "no llama-server is approved: set llamacpp.serverPath to the one wisp should run, such as "
                    + "\(LlamaCppServerBinary.command("/opt/homebrew/bin/llama-server"))"
            case .notApproved(let path, let reason):
                return "\(path) is not approved\(reason.map { " (\($0))" } ?? ""); a path set in config.json by hand "
                    + "is not approved;\(again)"
            case .approvedOther(let path, let approved):
                return "\(path) is not approved: the approval is for \(approved), and llamacpp.serverPath was changed "
                    + "without wisp config set;\(again)"
            case .moved(let path, let approved, let now):
                return "\(path) now resolves to \(now), not \(approved) as approved (an upgrade moves it);\(again)"
            case .missing(let path, let resolved):
                return "\(path) resolves to \(resolved), which is missing; install llama-server again or name "
                    + "another, then\(again)"
            case .unreadable(let path, let reason):
                return "\(path) cannot be read (\(reason)), so its digest cannot be checked"
            case .changed(let path, let approved, let now):
                return "\(path) has changed: sha256 \(LlamaCppServerBinary.short(now)), not "
                    + "\(LlamaCppServerBinary.short(approved)) as approved (brew upgrade llama.cpp changes it);"
                    + again
            }
        }
    }

    /// A file that passed the check: what to run.
    ///
    /// Stage 4 runs `executable`, the resolved path that was hashed, not the setting's path, so a link re-pointed
    /// after the check is not followed. What remains is the moment between hashing and running: whoever can write
    /// the file itself (for Homebrew, the person's own account, which owns its Cellar) can replace it in that window,
    /// and could as well have replaced it before; macOS has no `fexecve` to run the very bytes hashed.
    public struct Approved: Equatable, Sendable {
        /// The real file to run.
        public var executable: URL
        /// Its SHA-256, as checked.
        public var sha256: String
        /// The approval it matched.
        public var approval: Approval
    }

    /// What `wisp config set` or `unset` of the setting did.
    public struct Change: Equatable, Sendable {
        /// The edit to `config.json`, as written.
        public var outcome: ConfigEdit.Outcome
        /// The lines for the person.
        public var lines: [String]
    }

    /// The approval record.
    public let file: URL

    /// The record at `file`.
    public init(file: URL) {
        self.file = file
    }

    /// The record in `home`'s Application Support folder, `<support>/llamacpp/server.json`.
    public init(home: Home) {
        self.init(file: home.support.appending(path: "llamacpp/server.json"))
    }

    /// The command that approves `path`, for every message that asks for it.
    ///
    /// - Parameter path: The path.
    /// - Returns: `wisp config set llamacpp.serverPath <path>`, the path quoted when the shell needs it.
    static func command(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+@:".contains($0) }
        return "wisp config set \(setting) \(safe ? path : "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'")"
    }

    /// A digest's short form, its first 12 hex digits, as messages show it.
    ///
    /// - Parameter digest: The digest.
    /// - Returns: The short form.
    static func short(_ digest: String) -> String {
        String(digest.prefix(12))
    }

    /// The path as typed, made absolute: `~` expanded, a relative path taken from `workingDirectory`; links and `..`
    /// are kept, so the approval names the path the person gave.
    ///
    /// - Parameters:
    ///   - text: The path as typed.
    ///   - workingDirectory: Where a relative path starts.
    /// - Returns: The absolute path.
    static func absolute(_ text: String, workingDirectory: URL) -> String {
        let expanded = (text as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : workingDirectory.appending(path: expanded).path
    }

    /// The first four bytes of a Mach-O file: thin 32- and 64-bit, either byte order, and universal (fat) files.
    static let machOMagics: Set<Data> = [
        Data([0xCF, 0xFA, 0xED, 0xFE]), Data([0xCE, 0xFA, 0xED, 0xFE]),
        Data([0xFE, 0xED, 0xFA, 0xCF]), Data([0xFE, 0xED, 0xFA, 0xCE]),
        Data([0xCA, 0xFE, 0xBA, 0xBE]), Data([0xCA, 0xFE, 0xBA, 0xBF]),
    ]

    /// Reads the file `path` resolves to for approval: it must be a regular file, executable by this user, and begin
    /// with a Mach-O magic number. Its name is not checked, since a person may rename it. The magic and the digest
    /// come from one open file.
    ///
    /// - Parameter path: The absolute path, as given.
    /// - Returns: Where it resolves and its digest.
    /// - Throws: `Failure`.
    static func inspect(_ path: String) throws -> Inspected {
        let resolved = CommandPolicy.canonical(path)
        let manager = FileManager.default
        guard manager.fileExists(atPath: resolved) else { throw Failure.notFound(path) }
        let values = try? URL(filePath: resolved).resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw Failure.notAFile(path, resolved: resolved) }
        guard manager.isExecutableFile(atPath: resolved) else { throw Failure.notExecutable(path, resolved: resolved) }
        guard let handle = FileHandle(forReadingAtPath: resolved) else {
            throw Failure.unreadable(path, reason: "it cannot be opened")
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? nil
        guard let head, machOMagics.contains(head) else { throw Failure.notMachO(path, resolved: resolved) }
        var hasher = SHA256()
        hasher.update(data: head)
        return Inspected(
            path: path, resolved: URL(filePath: resolved), sha256: digest(continuing: hasher, from: handle))
    }

    /// Finishes a digest over the rest of an open file, read in pieces.
    ///
    /// - Parameters:
    ///   - hasher: The digest so far.
    ///   - handle: The file, positioned where the digest has reached.
    /// - Returns: The SHA-256, lower-case hex.
    static func digest(continuing hasher: SHA256, from handle: FileHandle) -> String {
        var hasher = hasher
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The recorded approval; nil when there is none.
    ///
    /// - Returns: The record.
    /// - Throws: The decoder's error for a record that does not read.
    public func approval() throws -> Approval? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Approval.self, from: data)
    }

    /// Records `inspected` as approved, replacing any earlier approval. The folder is made owner only (0700), the
    /// file is readable by the owner only (0600).
    ///
    /// - Parameters:
    ///   - inspected: The file, as read for approval.
    ///   - now: When.
    /// - Returns: The record written.
    /// - Throws: The file system's error.
    func save(_ inspected: Inspected, now: Date) throws -> Approval {
        let approval = Approval(
            path: inspected.path, resolved: inspected.resolved.path, sha256: inspected.sha256, approved: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let folder = file.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try encoder.encode(approval).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return approval
    }

    /// Removes the approval, if any.
    ///
    /// - Throws: The file system's error when a record there cannot be removed.
    func revoke() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    /// Checks the file the setting names against the approval, for the start of wisp's own server and for
    /// `wisp doctor`; nothing is recorded (`verify(_:audit:source:)` records a refusal).
    ///
    /// - Parameter path: `llamacpp.serverPath`, or nil when unset.
    /// - Returns: The real file to run, with its digest.
    /// - Throws: `Refusal`.
    public func check(_ path: String?) throws -> Approved {
        guard let path, !path.isEmpty else { throw Refusal.notSet }
        let approval: Approval
        do {
            guard let recorded = try self.approval() else { throw Refusal.notApproved(path: path, reason: nil) }
            approval = recorded
        } catch let refusal as Refusal {
            throw refusal
        } catch {
            throw Refusal.notApproved(path: path, reason: "the approval in \(file.path) does not read")
        }
        guard approval.path == path else { throw Refusal.approvedOther(path: path, approved: approval.path) }
        let resolved = CommandPolicy.canonical(path)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw Refusal.missing(path: path, resolved: resolved)
        }
        guard resolved == approval.resolved else {
            throw Refusal.moved(path: path, approved: approval.resolved, now: resolved)
        }
        guard let handle = FileHandle(forReadingAtPath: resolved) else {
            throw Refusal.unreadable(path: path, reason: "it cannot be opened")
        }
        defer { try? handle.close() }
        let sha256 = Self.digest(continuing: SHA256(), from: handle)
        guard sha256 == approval.sha256 else {
            throw Refusal.changed(path: path, approved: approval.sha256, now: sha256)
        }
        return Approved(executable: URL(filePath: resolved), sha256: sha256, approval: approval)
    }

    /// `check(_:)`, recording a refusal as `llamacpp.server.refused`: what the start of wisp's own server calls.
    ///
    /// - Parameters:
    ///   - path: `llamacpp.serverPath`, or nil when unset.
    ///   - audit: Where the refusal is recorded.
    ///   - source: Who asked, for the audit.
    /// - Returns: The real file to run, with its digest.
    /// - Throws: `Refusal`.
    public func verify(_ path: String?, audit: AuditLog?, source: String) throws -> Approved {
        do {
            return try check(path)
        } catch let refusal as Refusal {
            let approved = (try? approval()) ?? nil
            var found: (resolved: String?, sha256: String?) = (nil, nil)
            switch refusal {
            case .moved(_, _, let now): found.resolved = now
            case .missing(_, let resolved): found.resolved = resolved
            case .changed(let path, _, let now): found = (CommandPolicy.canonical(path), now)
            default: break
            }
            audit?.record(
                .llamaCppServerRefused,
                details: [
                    "path": refusal.path.map { .string($0) } ?? .null, "refusal": .string(refusal.kind),
                    "resolved": found.resolved.map { .string($0) } ?? .null,
                    "sha256": found.sha256.map { .string($0) } ?? .null,
                    "approvedSha256": approved.map { .string($0.sha256) } ?? .null,
                    "reason": .string(refusal.description), "source": .string(source),
                ])
            throw refusal
        }
    }

    /// Sets `llamacpp.serverPath` to the file `text` names and approves it, or, for nil, unsets it and removes the
    /// approval: what `wisp config set` and `unset` of the setting do, the person's alone. A path is refused unless
    /// it resolves to a regular Mach-O file executable by this user. Setting the same path again approves the file
    /// now there, which is how a person approves an upgraded `llama-server`. The record is written before
    /// `config.json`, so a failure between them leaves at worst an approval no setting names. Recorded as
    /// `llamacpp.server.approve`, a refusal too, and the file's edit as `config.change`.
    ///
    /// - Parameters:
    ///   - text: The path as typed, or nil to unset.
    ///   - configFile: `config.json`.
    ///   - workingDirectory: Where a relative path starts.
    ///   - audit: Where the change is recorded.
    ///   - source: Who changed it, for the audit (`cli`).
    ///   - now: When.
    /// - Returns: The edit and the lines for the person.
    /// - Throws: `Failure` for a path that cannot be approved; `ConfigEdit.Failure` or `ConfigEdit.Unreadable` when
    ///   `config.json` cannot be edited; the file system's error.
    public func change(
        _ text: String?, configFile: URL, workingDirectory: URL, audit: AuditLog?, source: String, now: Date = Date()
    ) throws -> Change {
        let previous = (try? approval()) ?? nil
        func record(_ outcome: String, _ inspected: Inspected?, path: String?, reason: String?) {
            audit?.record(
                .llamaCppServerApprove,
                details: [
                    "path": path.map { .string($0) } ?? .null,
                    "resolved": inspected.map { .string($0.resolved.path) } ?? .null,
                    "sha256": inspected.map { .string($0.sha256) } ?? .null,
                    "previousPath": previous.map { .string($0.path) } ?? .null,
                    "previousResolved": previous.map { .string($0.resolved) } ?? .null,
                    "previousSha256": previous.map { .string($0.sha256) } ?? .null, "outcome": .string(outcome),
                    "reason": reason.map { .string($0) } ?? .null, "source": .string(source),
                ])
        }
        let data = try ConfigEdit.existing(at: configFile)
        guard let text else {
            let outcome = try ConfigEdit.unset(Self.setting, in: data)
            try revoke()
            try ConfigEdit.write(outcome, to: configFile)
            audit?.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: source))
            record("revoked", nil, path: previous?.path, reason: nil)
            let gone = previous.map { "the approval of \($0.path) (sha256 \(Self.short($0.sha256))) is removed" }
            return Change(outcome: outcome, lines: [gone ?? "no llama-server was approved"])
        }
        let path = Self.absolute(text, workingDirectory: workingDirectory)
        let inspected: Inspected
        let outcome: ConfigEdit.Outcome
        do {
            inspected = try Self.inspect(path)
            outcome = try ConfigEdit.set(Self.setting, to: path, in: data)
        } catch {
            record("refused", nil, path: path, reason: "\(error)")
            throw error
        }
        let unchanged =
            previous.map {
                $0.path == path && $0.resolved == inspected.resolved.path && $0.sha256 == inspected.sha256
            } ?? false
        _ = try save(inspected, now: now)
        try ConfigEdit.write(outcome, to: configFile)
        audit?.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: source))
        record(unchanged ? "unchanged" : "approved", inspected, path: path, reason: nil)
        var lines = [
            "approved \(path): it resolves to \(inspected.resolved.path), sha256 \(Self.short(inspected.sha256)); "
                + "wisp checks it before every start of its own llama.cpp server"
        ]
        if let previous, !unchanged {
            lines.append(
                previous.sha256 == inspected.sha256
                    ? "it replaces the approval of \(previous.path), the same file"
                    : "it replaces the approval of \(previous.path) (sha256 \(Self.short(previous.sha256)))")
        } else if unchanged {
            lines.append("it was approved already, unchanged")
        }
        lines.append(
            "after brew upgrade llama.cpp, or any change to the file, approve it again with: \(Self.command(path))")
        return Change(outcome: outcome, lines: lines)
    }
}

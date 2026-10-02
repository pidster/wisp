import CryptoKit
import Darwin
import Foundation

/// The channel through which a command waiting for approval under `wisp mcp` is answered from another of
/// wisp's faces: `wisp approvals approve|deny`, or a running `wisp-tui`
/// ([ADR 0046](../../../../docs/decisions/0046-approval-and-notifications-over-mcp.md)).
///
/// A directory under the home, `pending/`, mode 0700, the same trust boundary as `approvals.json`. The
/// waiting server writes one request file per question (`<id>.request.json`, mode 0600, by rename so a
/// reader never sees half of one); an answering process writes `<id>.answer.json` beside it by a hard link
/// from a private temporary file, which fails when an answer is already there, so the first answer wins
/// and is always whole. The server polls for the answer, checks it is bound to the request it filed, takes
/// it (deleting the answer, then the request), and deletes the request when it stops waiting for any other
/// reason. A request whose server has died, or whose wait has expired, is stale: listing skips it and a
/// sweep removes it.
///
/// **Binding.** Each request carries `binding`, a SHA-256 over its id, command, whole line, pattern,
/// directory, level, thread, server process, and creation time. The answering process recomputes it from
/// the fields it shows the person and refuses a request whose stored binding does not match (the file was
/// altered after it was filed); the answer carries the recomputed binding; the server accepts only an
/// answer whose binding equals the one it computed when it filed the request. An answer can therefore
/// approve only the command the person was shown, in that directory, for that thread, and only once: the id
/// is fresh for every request, and taking the answer deletes both files.
public struct PendingApprovals: Sendable {
    /// One command waiting for approval in a `wisp mcp` process.
    public struct Request: Codable, Equatable, Sendable {
        /// Random, fresh for every request; what `wisp approvals approve` takes.
        public var id: String
        /// The simple command being approved.
        public var command: String
        /// The whole line it is part of.
        public var line: String
        /// The key a remembered approval is kept under, such as `git push *`.
        public var pattern: String
        /// Where it would run.
        public var directory: String
        /// The classifier's level.
        public var level: RiskLevel
        /// Why it needs approval.
        public var reasons: [String]
        /// The conversation it is for (the MCP `thread_id`), when known.
        public var thread: String?
        /// The MCP client's name, when it gave one at initialize.
        public var client: String?
        /// The waiting server's process id; a request whose process has gone is stale.
        public var pid: Int32
        /// When it was filed, to the second.
        public var createdAt: Date
        /// When the server stops waiting (`approval.timeoutSeconds`); nil waits for ever.
        public var expiresAt: Date?
        /// The SHA-256 binding the answer to exactly these fields.
        public var binding: String

        /// The binding these fields hash to.
        public var expectedBinding: String {
            PendingApprovals.binding(
                id: id, command: command, line: line, pattern: pattern, directory: directory, level: level,
                thread: thread, pid: pid, createdAt: createdAt)
        }
    }

    /// An answer to a request, written by the process the person answered in.
    public struct Answer: Codable, Equatable, Sendable {
        /// The request's id.
        public var id: String
        /// The binding the answering process computed from what it showed.
        public var binding: String
        /// `once`, `session`, `project`, `always`, or `no`.
        public var decision: String
        /// Where the person answered: `cli` or `tui`.
        public var via: String
        /// The answering process.
        public var pid: Int32
        /// When.
        public var answeredAt: Date
    }

    /// Why a request could not be filed or answered.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No request has this id: answered elsewhere, withdrawn, expired, or never filed.
        case unknown(String)
        /// The request's file no longer matches its binding; it is not answered.
        case altered(String)
        /// Someone answered it first.
        case answered(String)
        /// The request has expired or its server has gone.
        case stale(String)
        /// The decision is not one of `once`, `session`, `project`, `always`, `no`.
        case invalidDecision(String)
        /// The directory is not safe to use: not a directory, not the user's, or open to others.
        case unsafeDirectory(String)
        /// A file-system error.
        case io(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .unknown(let id): "no pending request \(id): it was answered elsewhere, withdrawn, or has expired"
            case .altered(let id): "pending request \(id) was altered after it was filed; it is not answered"
            case .answered(let id): "pending request \(id) already has an answer"
            case .stale(let id): "pending request \(id) is no longer waiting: its wait expired or its server stopped"
            case .invalidDecision(let text): "'\(text)' is not once, session, project, always, or no"
            case .unsafeDirectory(let detail): "the pending directory is not safe to use: \(detail)"
            case .io(let detail): detail
            }
        }
    }

    /// What the server found when it looked for an answer.
    public enum Taken: Equatable, Sendable {
        /// An answer bound to the request; both files are gone.
        case answer(Answer)
        /// An answer that was not bound to the request (or did not decode); it was removed and the wait goes on.
        case rejected(String)
    }

    /// The decisions an answer may carry.
    public static let decisions = ["once", "session", "project", "always", "no"]

    /// The directory.
    public let directory: URL

    /// A channel in `directory`.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The channel under `home`: `<home>/pending`.
    public init(home: Home) {
        self.init(directory: home.pending)
    }

    /// Whether process `pid` is running (or exists under another user, which `kill` reports as `EPERM`).
    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// A fresh request id: eight lowercase hex characters, as other wisp ids.
    static func makeID() -> String { ShortID.make() }

    /// The SHA-256, in hex, of the fields an answer is bound to, encoded as a JSON array so no field can run
    /// into the next.
    static func binding(
        id: String, command: String, line: String, pattern: String, directory: String, level: RiskLevel,
        thread: String?, pid: Int32, createdAt: Date
    ) -> String {
        let fields: [JSONValue] = [
            .string(id), .string(command), .string(line), .string(pattern), .string(directory),
            .string(level.rawValue), .string(thread ?? ""), .int(Int(pid)),
            .int(Int(createdAt.timeIntervalSince1970)),
        ]
        let data = (try? JSONEncoder().encode(JSONValue.array(fields))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A request for `approval`, bound and ready to file.
    ///
    /// - Parameters:
    ///   - approval: The gate's request.
    ///   - client: The MCP client's name.
    ///   - pid: The waiting process.
    ///   - now: The time, truncated to the second so the binding survives the file's date format.
    ///   - timeout: How long the server waits; nil for ever.
    /// - Returns: The request.
    public static func request(
        for approval: ApprovalRequest, client: String?, pid: Int32 = getpid(), now: Date = Date(),
        timeout: Duration?
    ) -> Request {
        let id = makeID()
        let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let expires = timeout.map { created.addingTimeInterval(TimeInterval($0.components.seconds)) }
        return Request(
            id: id, command: approval.command, line: approval.line, pattern: approval.pattern,
            directory: approval.workingDirectory, level: approval.assessment.level,
            reasons: approval.assessment.reasons, thread: approval.thread, client: client, pid: pid,
            createdAt: created, expiresAt: expires,
            binding: binding(
                id: id, command: approval.command, line: approval.line, pattern: approval.pattern,
                directory: approval.workingDirectory, level: approval.assessment.level, thread: approval.thread,
                pid: pid, createdAt: created))
    }

    private func requestFile(_ id: String) -> URL { directory.appending(path: "\(id).request.json") }
    private func answerFile(_ id: String) -> URL { directory.appending(path: "\(id).answer.json") }

    /// Whether `id` could name a request file: lowercase hex, so it never reaches outside the directory.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Creates the directory (mode 0700) if it is missing, and checks it is a directory of this user's that
    /// no one else can open.
    ///
    /// - Throws: `Failure.unsafeDirectory` or `Failure.io`.
    public func ensureDirectory() throws {
        let path = directory.path
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch  where !FileManager.default.fileExists(atPath: path) {
                // Another waiting command may create it at the same moment; only a directory still missing fails.
                throw Failure.io("could not create \(path): \(error.localizedDescription)")
            }
        }
        if let problem = Self.problem(with: path) { throw Failure.unsafeDirectory(problem) }
    }

    /// What is wrong with the directory at `path` for this channel, or nil: it must be a directory (not a
    /// link), owned by this user, with no access for group or others.
    static func problem(with path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "\(path) cannot be read: \(String(cString: strerror(errno)))" }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "\(path) is not a directory" }
        guard info.st_uid == getuid() else { return "\(path) belongs to another user" }
        let mode = Int(info.st_mode) & 0o777
        guard mode & 0o077 == 0 else {
            return "\(path) is mode \(String(mode, radix: 8)), open to others; run: chmod 700 \(path)"
        }
        return nil
    }

    /// Writes `data` to `url` with mode 0600 by way of a temporary file in the same directory, so the final
    /// name appears whole or not at all. With `exclusive`, the final name is made by a hard link, which
    /// fails when it already exists.
    ///
    /// - Returns: False when `exclusive` and the file already existed.
    /// - Throws: `Failure.io`.
    private func write(_ data: Data, to url: URL, exclusive: Bool) throws -> Bool {
        let temporary = directory.appending(path: ".\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw Failure.io("could not write \(temporary.path)") }
        defer { unlink(temporary.path) }
        if exclusive {
            guard link(temporary.path, url.path) == 0 else {
                if errno == EEXIST { return false }
                throw Failure.io("could not write \(url.path): \(String(cString: strerror(errno)))")
            }
            return true
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw Failure.io("could not write \(url.path): \(String(cString: strerror(errno)))")
        }
        return true
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: The waiting server

    /// Files `request` for another face to answer.
    ///
    /// - Throws: `Failure.unsafeDirectory` or `Failure.io`.
    public func file(_ request: Request) throws {
        try ensureDirectory()
        let data: Data
        do { data = try Self.encoder.encode(request) } catch { throw Failure.io("\(error)") }
        _ = try write(data, to: requestFile(request.id), exclusive: false)
    }

    /// Whether `request` is still filed.
    public func isFiled(_ request: Request) -> Bool {
        FileManager.default.fileExists(atPath: requestFile(request.id).path)
    }

    /// Takes the answer to `request`, if one has arrived: an answer bound to it removes both files; one that
    /// is not (or does not decode) is removed and reported, and the request stays.
    ///
    /// - Parameter request: The request as the server filed it, from memory, not from the file.
    /// - Returns: What was found, or nil when there is no answer yet.
    public func take(_ request: Request) -> Taken? {
        let file = answerFile(request.id)
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        unlink(file.path)
        guard let answer = try? Self.decoder.decode(Answer.self, from: data) else {
            return .rejected("the answer file did not decode")
        }
        guard answer.id == request.id, answer.binding == request.binding else {
            return .rejected("the answer was not bound to this request")
        }
        guard Self.decisions.contains(answer.decision) else {
            return .rejected("the answer's decision '\(answer.decision)' is not one wisp knows")
        }
        unlink(requestFile(request.id).path)
        return .answer(answer)
    }

    /// Removes `request`: it was answered another way, timed out, or was abandoned. An answer written after
    /// this is never read; the answering process sees the request gone and removes its answer.
    public func withdraw(_ request: Request) {
        unlink(requestFile(request.id).path)
    }

    // MARK: Listing and answering

    /// The request with `id` as filed, whatever its state.
    ///
    /// - Throws: `Failure.unknown` when there is none or the id is malformed.
    public func request(id: String) throws -> Request {
        guard Self.isValidID(id), let data = FileManager.default.contents(atPath: requestFile(id).path),
            let request = try? Self.decoder.decode(Request.self, from: data)
        else { throw Failure.unknown(id) }
        return request
    }

    /// Every request file that decodes, oldest first.
    private func all() -> [Request] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".request.json") }
            .compactMap { FileManager.default.contents(atPath: directory.appending(path: $0).path) }
            .compactMap { try? Self.decoder.decode(Request.self, from: $0) }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Whether `request` is stale at `now`: its wait has expired or its server has gone.
    static func isStale(_ request: Request, now: Date, alive: (Int32) -> Bool) -> Bool {
        if let expires = request.expiresAt, expires < now { return true }
        return !alive(request.pid)
    }

    /// The requests still waiting, oldest first; stale ones are left for `sweep`.
    ///
    /// - Parameters:
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    /// - Returns: The live requests.
    public func waiting(now: Date = Date(), alive: (Int32) -> Bool = PendingApprovals.isAlive) -> [Request] {
        all().filter { !Self.isStale($0, now: now, alive: alive) }
    }

    /// Removes stale requests, answers left without a request for more than a minute, temporary files left
    /// by a crash, and files that do not decode.
    ///
    /// - Parameters:
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    /// - Returns: The stale requests removed.
    @discardableResult
    public func sweep(now: Date = Date(), alive: (Int32) -> Bool = PendingApprovals.isAlive) -> [Request] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed: [Request] = []
        for name in names {
            let url = directory.appending(path: name)
            let modified =
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
            let old = now.timeIntervalSince(modified) > 60
            if name.hasSuffix(".request.json") {
                guard let data = FileManager.default.contents(atPath: url.path),
                    let request = try? Self.decoder.decode(Request.self, from: data)
                else {
                    if old { unlink(url.path) }
                    continue
                }
                if Self.isStale(request, now: now, alive: alive) {
                    unlink(url.path)
                    removed.append(request)
                }
            } else if name.hasSuffix(".answer.json") {
                let id = String(name.dropLast(".answer.json".count))
                if old, !FileManager.default.fileExists(atPath: requestFile(id).path) { unlink(url.path) }
            } else if name.hasSuffix(".tmp"), old {
                unlink(url.path)
            }
        }
        return removed.sorted { $0.createdAt < $1.createdAt }
    }

    /// Answers the request with `id`, after checking that it is still waiting and that its file matches its
    /// binding. The first answer wins; a second is refused.
    ///
    /// - Parameters:
    ///   - id: The request.
    ///   - decision: `once`, `session`, `project`, `always`, or `no`.
    ///   - via: Where the person answered: `cli` or `tui`.
    ///   - now: The time.
    ///   - alive: Whether a process is running.
    /// - Returns: The request answered, as it was shown.
    /// - Throws: `Failure`: unknown, stale, altered, already answered, an invalid decision, or a write error.
    @discardableResult
    public func answer(
        _ id: String, decision: String, via: String, now: Date = Date(),
        alive: (Int32) -> Bool = PendingApprovals.isAlive
    ) throws -> Request {
        guard Self.decisions.contains(decision) else { throw Failure.invalidDecision(decision) }
        let request = try request(id: id)
        guard !Self.isStale(request, now: now, alive: alive) else { throw Failure.stale(id) }
        let binding = request.expectedBinding
        guard binding == request.binding else { throw Failure.altered(id) }
        try ensureDirectory()
        let answer = Answer(
            id: id, binding: binding, decision: decision, via: via, pid: getpid(),
            answeredAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        let data: Data
        do { data = try Self.encoder.encode(answer) } catch { throw Failure.io("\(error)") }
        guard try write(data, to: answerFile(id), exclusive: true) else { throw Failure.answered(id) }
        return request
    }

    /// What became of an answer this process wrote, once the server has had time to look.
    public enum Delivery: Equatable, Sendable {
        /// The server took it: both files are gone.
        case taken
        /// The request went another way first (the client's dialog, a timeout); the answer was removed.
        case tooLate
        /// The server has not looked yet; the answer stands and is taken if the request is still waiting.
        case waiting
    }

    /// Whether the server took the answer to `id`: the request and the answer both gone is taken; the request
    /// gone and the answer left is too late, and the answer is removed.
    ///
    /// - Parameter id: The request answered.
    /// - Returns: The delivery as it stands now.
    public func delivery(of id: String) -> Delivery {
        let requestGone = !FileManager.default.fileExists(atPath: requestFile(id).path)
        let answerGone = !FileManager.default.fileExists(atPath: answerFile(id).path)
        switch (requestGone, answerGone) {
        case (true, true): return .taken
        case (true, false):
            unlink(answerFile(id).path)
            return .tooLate
        default: return .waiting
        }
    }
}

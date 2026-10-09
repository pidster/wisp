import CryptoKit
import Foundation
import WispCore

/// Fetches an `mlx-community` model from Hugging Face into the Hugging Face cache, in `huggingface_hub`'s own
/// layout, and links the MLX models directory to its snapshot, for `wisp models pull`
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-04).
///
/// The cache is shared: a model any Hugging Face tool fetched is reused, file by file, and what wisp fetches
/// other tools find. `plan` lists the repository and checks each wanted file against the cache (present, the
/// listed size, and the content: for weights the listed SHA-256, for any other file its git blob id), so the question names only what will be downloaded;
/// nothing is fetched without the person's approval, and a complete snapshot fetches nothing. A file the model's own
/// directory already holds (an earlier copy, not a link), checked the same way, is copied into the cache instead of
/// fetched; a blob left half-fetched is resumed with an HTTP range request whose answer must start where the part
/// stops. The fetch is
/// bounded: one organisation, the files an MLX model directory needs and nothing else, every size known before
/// the question and checked after each file, LFS files checked against their SHA-256 and the rest against their git
/// blob id, and the whole refused
/// when the disk lacks room for what will be downloaded. `link` then makes `<models>/<name>` a link to the
/// snapshot; a real directory already there is left unless the person agrees to replace it.
public struct ModelPull: Sendable {
    /// Why a pull could not be planned or finished.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The repository is not `mlx-community/<name>`.
        case notAllowed(String)
        /// Hugging Face answered with an error status.
        case http(status: Int, url: String)
        /// The listing could not be read.
        case badListing(String)
        /// The repository has no `config.json` or no `*.safetensors`.
        case notAModel(String)
        /// Something other than a directory or a link into this model's cache folder is at the link's path.
        case exists(String)
        /// The disk has less room than the files need.
        case noRoom(needed: Int, available: Int)
        /// A fetched or cached file is not the size or digest the listing gave.
        case mismatch(file: String, detail: String)
        /// The request failed.
        case transport(String)
        /// Another program holds the cache's lock on a blob wisp would fetch.
        case busy(String)
        /// The cache holds no complete snapshot of the repository to link without fetching.
        case notCached(String)
        /// A file of the model's own directory could not be copied into the cache.
        case copy(file: String, detail: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notAllowed(let repository):
                "'\(repository)' is not an mlx-community model; wisp fetches only mlx-community/<name> "
                    + "(put any other model directory under the models directory yourself)"
            case .http(let status, let url): "Hugging Face returned HTTP \(status) for \(url)"
            case .badListing(let detail): "unexpected listing from Hugging Face: \(detail)"
            case .notAModel(let repository):
                "\(repository) is not an MLX model directory (it needs config.json and *.safetensors)"
            case .exists(let path):
                "\(path) is already there and is not a directory or a link into this model's Hugging Face "
                    + "cache folder; remove it, or rename it, to link the model there"
            case .noRoom(let needed, let available):
                "the files need \(Self.size(needed)) and the disk has \(Self.size(available)) free"
            case .mismatch(let file, let detail): "\(file) did not arrive intact (\(detail)); run the pull again"
            case .transport(let detail): "the fetch failed: \(detail); run the pull again to resume"
            case .busy(let path):
                "another program is fetching into the Hugging Face cache (\(path) is locked); try again when it "
                    + "has finished"
            case .notCached(let repository):
                "the Hugging Face cache holds no complete snapshot of \(repository); wisp models pull \(repository) "
                    + "fetches it, after asking"
            case .copy(let file, let detail): "could not copy \(file) into the Hugging Face cache: \(detail)"
            }
        }

        /// Bytes for people.
        static func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// One file of the repository.
    public struct File: Equatable, Sendable {
        /// Its path in the repository, at the top level.
        public var path: String
        /// Its size in bytes.
        public var size: Int
        /// The SHA-256 of an LFS file's content, as hex; nil for a small file kept in git.
        public var sha256: String?
        /// Its git blob id (the listing's `oid`), the cache's name for a file not in LFS.
        public var oid: String?

        /// Creates a record.
        public init(path: String, size: Int, sha256: String? = nil, oid: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.oid = oid
        }

        /// The blob's name in the cache: the SHA-256 for an LFS file, the git blob id otherwise, as
        /// `huggingface_hub` names it.
        public var blob: String { (sha256 ?? oid ?? "").lowercased() }
    }

    /// What is at the link's path in the MLX models directory.
    public enum Link: Equatable, Sendable {
        /// Nothing: the link will be made.
        case absent
        /// A link to this snapshot already.
        case current
        /// A link to another snapshot of the same model (an older revision): it will point at this one.
        case stale(String)
        /// A real directory, such as an earlier pull's copy: left unless the person agrees to replace it.
        case directory
    }

    /// What `link` did, as `model.pull` records it.
    public enum LinkOutcome: String, Equatable, Sendable {
        /// The link was made.
        case created
        /// The link already pointed at the snapshot.
        case unchanged
        /// A link to another snapshot was pointed at this one.
        case replacedLink = "replaced link"
        /// A real directory was moved aside (to the Trash) and the link made.
        case replacedDirectory = "replaced directory"
        /// A real directory was there and stays; no link was made.
        case keptDirectory = "kept directory"
    }

    /// What a pull would fetch and link, for the person to approve.
    public struct Plan: Equatable, Sendable {
        /// `mlx-community/<name>`.
        public var repository: String
        /// The link's name, and what follows `mlx:` to select it.
        public var name: String
        /// The commit `main` is at, whose snapshot the pull fills.
        public var revision: String
        /// The Hugging Face cache.
        public var cache: HubCache
        /// The link's path in the MLX models directory.
        public var destination: URL
        /// What is at that path now.
        public var link: Link
        /// The files to have.
        public var files: [File]
        /// The files already in the cache, checked: the listed size, and the SHA-256 for weights or the git blob id
        /// for any other file.
        public var reused: [String]
        /// The files the model's own directory at `destination` holds, checked as the cache's are, which `fetch`
        /// copies into the cache (a clone on APFS) instead of fetching them.
        public var seeded: [String] = []

        /// The snapshot directory the link points at.
        public var snapshot: URL { cache.snapshot(revision, of: repository) }
        /// The files to download.
        public var missing: [File] { files.filter { !reused.contains($0.path) && !seeded.contains($0.path) } }
        /// The files to copy from the model's own directory.
        public var seeding: [File] { files.filter { seeded.contains($0.path) } }
        /// Bytes of every file.
        public var bytes: Int { files.reduce(0) { $0 + $1.size } }
        /// Bytes still to download.
        public var remaining: Int { missing.reduce(0) { $0 + $1.size } }
    }

    /// What a download's response said: its status and, for a partial response, where the bytes it sent start.
    public struct Download: Equatable, Sendable {
        /// The HTTP status.
        public var status: Int
        /// The first byte of a 206's body, from its `Content-Range`; nil for any other status, or a 206 without one.
        public var rangeStart: Int?

        /// Creates a record.
        public init(status: Int, rangeStart: Int? = nil) {
            self.status = status
            self.rangeStart = rangeStart
        }
    }

    /// How a pull talks to Hugging Face; a protocol so tests serve the repository from memory.
    public protocol Transport: Sendable {
        /// The body and status of a GET.
        ///
        /// - Throws: When the request fails.
        func data(from url: URL) async throws -> (Data, Int)
        /// Writes a GET's body into `file` as it arrives, so an interrupted fetch leaves what it had. With an
        /// `offset` above 0 it asks for the bytes from there on (`Range: bytes=<offset>-`): a server that honours
        /// it answers 206 with a `Content-Range` starting at `offset`, and the body is appended after `offset` bytes
        /// of `file`; one that ignores it answers 200 and `file` is written from the start. A 206 whose range starts
        /// anywhere else, and any other status, writes nothing.
        ///
        /// - Parameters:
        ///   - url: What to fetch.
        ///   - offset: The bytes `file` already holds, to resume after; 0 for the whole.
        ///   - file: Where the body goes, created when absent.
        /// - Returns: The status and, for a 206, where its range starts.
        /// - Throws: When the request fails; what arrived before stays in `file`.
        func download(from url: URL, resumingAt offset: Int, into file: URL) async throws -> Download
    }

    /// URLSession, with a minute's limit on silence and none on a large file's total time.
    public struct SessionTransport: Transport {
        /// The session.
        private let session: URLSession

        /// Creates the transport.
        public init() {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            session = URLSession(configuration: configuration)
        }

        /// The body and status of a GET.
        ///
        /// - Throws: When the request fails.
        public func data(from url: URL) async throws -> (Data, Int) {
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        /// Streams a GET's body into `file`, from `offset` when the server honours the range from there.
        ///
        /// - Parameters:
        ///   - url: What to fetch.
        ///   - offset: The bytes `file` already holds; 0 for the whole.
        ///   - file: Where the body goes.
        /// - Returns: The status and, for a 206, where its `Content-Range` starts.
        /// - Throws: When the request fails or `file` cannot be written.
        public func download(from url: URL, resumingAt offset: Int, into file: URL) async throws -> Download {
            var request = URLRequest(url: url)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let start = status == 206 ? ModelPull.rangeStart(http?.value(forHTTPHeaderField: "Content-Range")) : nil
            let answer = Download(status: status, rangeStart: start)
            // A partial body is appended only when it starts where the file stops.
            guard status == 200 || (status == 206 && offset > 0 && start == offset) else { return answer }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            if status == 206 { try handle.seek(toOffset: UInt64(offset)) } else { try handle.truncate(atOffset: 0) }
            var buffer = Data()
            buffer.reserveCapacity(Self.piece)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.piece {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            return answer
        }

        /// Bytes gathered before each write.
        static let piece = 1 << 20
    }

    /// The first byte a `Content-Range` header names (`bytes 100-199/200` is 100); nil when there is none or it
    /// does not parse.
    ///
    /// - Parameter header: The header's value.
    /// - Returns: The first byte.
    static func rangeStart(_ header: String?) -> Int? {
        guard let header, let match = header.firstMatch(of: #/^\s*bytes\s+(\d+)-\d+\/(?:\d+|\*)\s*$/#) else {
            return nil
        }
        return Int(match.1)
    }

    /// The only organisation wisp fetches from.
    public static let organisation = "mlx-community"
    /// Hugging Face.
    public static let hub = URL(string: "https://huggingface.co") ?? URL(filePath: "/")
    /// The free space kept after the files are in.
    public static let margin = 1 << 30

    /// Where Hugging Face is; a test server elsewhere.
    public var hub: URL
    /// How requests are made.
    public var transport: any Transport
    /// The Hugging Face cache the files go into.
    public var cache: HubCache

    /// Creates a pull against Hugging Face, into the cache this process's environment names.
    public init(hub: URL = ModelPull.hub, transport: any Transport = SessionTransport(), cache: HubCache = .current()) {
        self.hub = hub
        self.transport = transport
        self.cache = cache
    }

    /// The repository a request names: `mlx-community/<name>`, with or without `mlx:` before it.
    ///
    /// - Parameter text: What the person typed.
    /// - Returns: The repository and the model's name.
    /// - Throws: `Failure.notAllowed` for any other organisation or a name with characters a path must not
    ///   carry.
    public static func repository(_ text: String) throws -> (repository: String, name: String) {
        let trimmed = text.hasPrefix("mlx:") ? String(text.dropFirst(4)) : text
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts[0] == organisation, let name = parts.last, !name.isEmpty,
            !name.hasPrefix("."), name.allSatisfy(allowed.contains)
        else { throw Failure.notAllowed(text) }
        return (trimmed, String(name))
    }

    /// Whether a repository file belongs in an MLX model directory: the configuration, weights, and
    /// tokenizer files at the top level, and nothing else (no README, images, or other formats).
    ///
    /// - Parameter path: The file's path in the repository.
    /// - Returns: Whether to fetch it.
    public static func wanted(_ path: String) -> Bool {
        guard !path.contains("/"), !path.hasPrefix(".") else { return false }
        return ["json", "safetensors", "jinja", "txt", "model", "tiktoken"].contains(
            (path as NSString).pathExtension)
    }

    /// Reads the commit a revision is at from the Hub's model information (`/api/models/<repo>/revision/main`).
    ///
    /// - Parameter data: The body.
    /// - Returns: The commit's sha.
    /// - Throws: `Failure.badListing` when there is no 40-digit sha.
    static func revision(fromInfo data: Data) throws -> String {
        guard let sha = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?["sha"]?.stringValue,
            HubCache.isRevision(sha.lowercased())
        else { throw Failure.badListing(String(decoding: data.prefix(120), as: UTF8.self)) }
        return sha.lowercased()
    }

    /// Reads the repository's file list from the Hub's tree listing, keeping the wanted files.
    ///
    /// - Parameter data: The listing's body.
    /// - Returns: The files, sorted by path.
    /// - Throws: `Failure.badListing`, also when a wanted file has no id the cache can name its blob by.
    static func files(fromListing data: Data) throws -> [File] {
        guard let entries = (try? JSONDecoder().decode(JSONValue.self, from: data))?.arrayValue else {
            throw Failure.badListing(String(decoding: data.prefix(120), as: UTF8.self))
        }
        let files = entries.compactMap { entry -> File? in
            guard let object = entry.objectValue, object["type"]?.stringValue == "file",
                let path = object["path"]?.stringValue, wanted(path)
            else { return nil }
            let lfs = object["lfs"]?.objectValue
            guard let size = lfs?["size"]?.intValue ?? object["size"]?.intValue else { return nil }
            return File(path: path, size: size, sha256: lfs?["oid"]?.stringValue, oid: object["oid"]?.stringValue)
        }.sorted { $0.path < $1.path }
        if let unnamed = files.first(where: { !HubCache.isBlobID($0.blob) }) {
            throw Failure.badListing("\(unnamed.path) has no blob id")
        }
        return files
    }

    /// Lists the repository and says what a pull would fetch: the files already in the cache are checked
    /// (size, and the SHA-256 of weights, which reads them) and left out. Nothing is written.
    ///
    /// - Parameters:
    ///   - text: The repository, as the person typed it.
    ///   - directory: The MLX models directory.
    ///   - checking: Told of each cached weights file before its digest is read.
    /// - Returns: The plan.
    /// - Throws: `Failure`, `exists` before anything is listed when the link's path holds something else.
    public func plan(_ text: String, into directory: URL, checking: (File) -> Void = { _ in }) async throws -> Plan {
        let (repository, name) = try Self.repository(text)
        let destination = directory.appending(path: name)
        // Refused before any request when the path holds something wisp must not replace.
        _ = try Self.linkState(at: destination, snapshot: nil, cache: cache, repository)
        let information = hub.appending(path: "api/models/\(repository)/revision/main")
        let (info, infoStatus) = try await request { try await transport.data(from: information) }
        guard infoStatus == 200 else { throw Failure.http(status: infoStatus, url: information.absoluteString) }
        let revision = try Self.revision(fromInfo: info)
        let listing = hub.appending(path: "api/models/\(repository)/tree/\(revision)")
        let (data, status) = try await request { try await transport.data(from: listing) }
        guard status == 200 else { throw Failure.http(status: status, url: listing.absoluteString) }
        let files = try Self.files(fromListing: data)
        guard files.contains(where: { $0.path == "config.json" }),
            files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else { throw Failure.notAModel(repository) }
        let link = try Self.linkState(
            at: destination, snapshot: cache.snapshot(revision, of: repository), cache: cache, repository)
        let reused = files.filter { file in
            Self.holds(cache.blob(file.blob, of: repository), file, checking: checking)
        }.map(\.path)
        // A real directory of the model's own (an earlier copy) seeds the cache with the files it holds intact.
        let seeded =
            link == .directory
            ? files.filter { file in
                !reused.contains(file.path)
                    && Self.holds(destination.appending(path: file.path), file, checking: checking)
            }.map(\.path) : []
        return Plan(
            repository: repository, name: name, revision: revision, cache: cache, destination: destination,
            link: link, files: files, reused: reused, seeded: seeded)
    }

    /// Whether `url` is the listed file: its size, and its content (`check(_:against:)`): for weights its SHA-256,
    /// which `checking` is told of before it is read, for any other file its git blob id.
    ///
    /// - Parameters:
    ///   - url: The candidate, followed through links.
    ///   - file: The listing's record.
    ///   - checking: Told of a weights file of the right size before its digest is read.
    /// - Returns: Whether it matches.
    static func holds(_ url: URL, _ file: File, checking: (File) -> Void) -> Bool {
        if file.sha256 != nil, size(of: url) == file.size { checking(file) }
        return (try? check(url, against: file)) != nil
    }

    /// The plan for a model whose `main` snapshot is already complete in the cache, made from the snapshot alone,
    /// without asking Hugging Face: every file is reused, so `link` makes the link and nothing is fetched. Enabling a
    /// cached model links it this way (ADR 0056).
    ///
    /// - Parameters:
    ///   - text: The repository.
    ///   - directory: The MLX models directory.
    /// - Returns: The plan.
    /// - Throws: `Failure.notAllowed`, `Failure.notCached` when there is no complete snapshot, or `Failure.exists`.
    public func cachedPlan(_ text: String, into directory: URL) throws -> Plan {
        let (repository, name) = try Self.repository(text)
        guard let revision = cache.mainRevision(of: repository),
            HubCache.looksComplete(cache.snapshot(revision, of: repository))
        else { throw Failure.notCached(repository) }
        let snapshot = cache.snapshot(revision, of: repository)
        let destination = directory.appending(path: name)
        let link = try Self.linkState(at: destination, snapshot: snapshot, cache: cache, repository)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: snapshot.path)) ?? []
        let files = names.filter(Self.wanted).sorted().map { path in
            File(path: path, size: Self.size(of: snapshot.appending(path: path)))
        }
        return Plan(
            repository: repository, name: name, revision: revision, cache: cache, destination: destination, link: link,
            files: files, reused: files.map(\.path))
    }

    /// Copies the files the model's own directory holds into the cache's blobs, fetches the rest the plan lacks,
    /// checking each, then links every file into the snapshot and points `refs/main` at it. With nothing to fetch
    /// or copy it only links.
    ///
    /// Each blob is written under `huggingface_hub`'s lock for it, into `<id>.incomplete`, which takes the
    /// blob's name once checked. An `.incomplete` left by an interrupted fetch, wisp's or another tool's, is
    /// resumed from where it stopped with a range request; the whole file is then checked, so a part that does not
    /// continue into the listed SHA-256 is refused. A server that ignores the range sends the whole file, and
    /// `notice` says it started again.
    ///
    /// - Parameters:
    ///   - plan: The approved plan.
    ///   - available: Bytes free on the cache's volume; nil reads them.
    ///   - progress: Told of each file as it starts, with its index from 1 among those to fetch.
    ///   - notice: Told, in a line for the person, of a file copied from the model's directory, resumed, or
    ///     started again because the server ignored the range.
    /// - Returns: Bytes fetched by this run.
    /// - Throws: `Failure`; the blobs fetched so far, and the part of one being fetched, stay for the next run.
    public func fetch(
        _ plan: Plan, available: Int? = nil, progress: (File, Int) -> Void = { _, _ in },
        notice: (String) -> Void = { _ in }
    ) async throws -> Int {
        let fileManager = FileManager.default
        let blobs = cache.folder(of: plan.repository).appending(path: "blobs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: plan.snapshot, withIntermediateDirectories: true)
        let missing = plan.missing
        if !missing.isEmpty {
            let free = available ?? Self.available(at: blobs)
            guard plan.remaining + Self.margin <= free else {
                throw Failure.noRoom(needed: plan.remaining + Self.margin, available: free)
            }
        }
        for file in plan.seeding {
            notice("copying \(file.path) from \(plan.destination.path) into the Hugging Face cache")
            try await Self.locked(cache.lock(file.blob, of: plan.repository)) {
                try seedBlob(file, of: plan)
            }
        }
        var fetched = 0
        for (index, file) in missing.enumerated() {
            progress(file, index + 1)
            fetched += try await Self.locked(cache.lock(file.blob, of: plan.repository)) {
                try await fetchBlob(file, of: plan, notice: notice)
            }
        }
        for file in plan.files {
            try Self.linkIntoSnapshot(file, at: plan.snapshot)
        }
        let refs = cache.folder(of: plan.repository).appending(path: "refs", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: refs, withIntermediateDirectories: true)
        if cache.mainRevision(of: plan.repository) != plan.revision {
            try Data(plan.revision.utf8).write(to: refs.appending(path: "main"), options: .atomic)
        }
        return fetched
    }

    /// Fetches one blob into `<id>.incomplete`, resuming a part already there, checks it, and gives it the blob's
    /// name.
    ///
    /// - Returns: Bytes this request downloaded.
    /// - Throws: `Failure`; a file that fails its check is removed, so the next run fetches it whole.
    private func fetchBlob(_ file: File, of plan: Plan, notice: (String) -> Void) async throws -> Int {
        let fileManager = FileManager.default
        let blob = cache.blob(file.blob, of: plan.repository)
        let incomplete = Self.incomplete(of: blob)
        let held = Self.size(of: incomplete)
        // A part as long as the file may be whole already; one longer, or that fails the check, starts again.
        if held == file.size, (try? Self.check(incomplete, against: file)) != nil {
            try Self.complete(incomplete, as: blob)
            return 0
        }
        var offset = held > 0 && held < file.size ? held : 0
        if offset == 0 { try? fileManager.removeItem(at: incomplete) }
        if offset > 0 {
            notice("resuming \(file.path) after \(Failure.size(offset)) of \(Failure.size(file.size))")
        }
        let url = hub.appending(path: "\(plan.repository)/resolve/\(plan.revision)/\(file.path)")
        var answer = try await request {
            try await transport.download(from: url, resumingAt: offset, into: incomplete)
        }
        // A part that starts anywhere but where the file stops would splice two pieces: the file starts again.
        if answer.status == 206, offset > 0, answer.rangeStart != offset {
            notice(
                "Hugging Face sent \(file.path) from \(answer.rangeStart.map { "byte \($0)" } ?? "an unnamed offset"), "
                    + "not byte \(offset); it was fetched from the start")
            try? fileManager.removeItem(at: incomplete)
            offset = 0
            let restart = offset
            answer = try await request {
                try await transport.download(from: url, resumingAt: restart, into: incomplete)
            }
        }
        let status = answer.status
        guard status == 200 || (status == 206 && offset > 0) else {
            throw Failure.http(status: status, url: url.absoluteString)
        }
        if offset > 0, status == 200 {
            notice("Hugging Face ignored the range for \(file.path) and sent it whole; it was fetched from the start")
        }
        do {
            try Self.check(incomplete, against: file)
        } catch {
            try? fileManager.removeItem(at: incomplete)
            throw error
        }
        try Self.complete(incomplete, as: blob)
        return status == 206 ? file.size - offset : file.size
    }

    /// Copies one file from the model's own directory into `<id>.incomplete` (a clone where the volume can make
    /// one, a copy otherwise), checks it again, since the directory may have changed since the plan, and gives it
    /// the blob's name.
    ///
    /// - Throws: `Failure.mismatch` when it no longer matches the listing, or the copy's error.
    private func seedBlob(_ file: File, of plan: Plan) throws {
        let blob = cache.blob(file.blob, of: plan.repository)
        let incomplete = Self.incomplete(of: blob)
        try? FileManager.default.removeItem(at: incomplete)
        let source = plan.destination.appending(path: file.path).resolvingSymlinksInPath()
        try Self.clone(source, to: incomplete)
        do {
            try Self.check(incomplete, against: file)
        } catch {
            try? FileManager.default.removeItem(at: incomplete)
            throw error
        }
        try Self.complete(incomplete, as: blob)
    }

    /// `<id>.incomplete` beside a blob, where it is written before it is checked.
    static func incomplete(of blob: URL) -> URL {
        blob.deletingLastPathComponent().appending(path: "\(blob.lastPathComponent).incomplete")
    }

    /// Gives a checked `.incomplete` the blob's name, replacing whatever was there.
    ///
    /// - Throws: The file system's error.
    static func complete(_ incomplete: URL, as blob: URL) throws {
        try? FileManager.default.removeItem(at: blob)
        try FileManager.default.moveItem(at: incomplete, to: blob)
    }

    /// Copies `source` to `destination`, which must not exist, as an APFS clone when the volume allows it
    /// (`copyfile`'s `COPYFILE_CLONE`, which copies when it cannot clone), so seeding the cache from a directory on
    /// the same volume takes no space until one of them changes.
    ///
    /// - Throws: `Failure.copy` naming the error when neither works.
    static func clone(_ source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw Failure.copy(file: source.path, detail: String(cString: strerror(errno)))
        }
    }

    /// Makes `snapshot/<path>` the relative link `../../blobs/<id>`, replacing whatever else was there.
    ///
    /// - Throws: When the link cannot be made.
    static func linkIntoSnapshot(_ file: File, at snapshot: URL) throws {
        let fileManager = FileManager.default
        let entry = snapshot.appending(path: file.path)
        let target = "../../blobs/\(file.blob)"
        if (try? fileManager.destinationOfSymbolicLink(atPath: entry.path)) == target { return }
        if HubCache.occupied(entry) { try fileManager.removeItem(at: entry) }
        try fileManager.createSymbolicLink(atPath: entry.path, withDestinationPath: target)
    }

    /// Checks every file of the plan reaches a blob of its listed size through the snapshot, as the last
    /// check before a directory is replaced by a link.
    ///
    /// - Throws: `Failure.mismatch` naming the first file that does not.
    static func verifySnapshot(_ plan: Plan) throws {
        for file in plan.files {
            let size = Self.size(of: plan.snapshot.appending(path: file.path).resolvingSymlinksInPath())
            guard size == file.size else {
                throw Failure.mismatch(file: file.path, detail: "the snapshot has \(size) bytes, expected \(file.size)")
            }
        }
    }

    /// Makes the link's path in the MLX models directory a link to the snapshot, once the snapshot is
    /// complete. A link to another snapshot of the model is repointed; a real directory is replaced only
    /// with `replacingDirectory`, through `discard` (the Trash, by default), and otherwise left as it is.
    ///
    /// - Parameters:
    ///   - plan: The plan, after `fetch`.
    ///   - replacingDirectory: Whether the person agreed to replace a real directory there.
    ///   - discard: Moves the directory aside.
    /// - Returns: What was done.
    /// - Throws: `Failure`, or the file system's error.
    public func link(
        _ plan: Plan, replacingDirectory: Bool = false,
        discard: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws -> LinkOutcome {
        try Self.verifySnapshot(plan)
        let fileManager = FileManager.default
        let state = try Self.linkState(
            at: plan.destination, snapshot: plan.snapshot, cache: cache, plan.repository)
        let outcome: LinkOutcome
        switch state {
        case .current: return .unchanged
        case .absent: outcome = .created
        case .stale:
            try fileManager.removeItem(at: plan.destination)
            outcome = .replacedLink
        case .directory:
            guard replacingDirectory else { return .keptDirectory }
            try discard(plan.destination)
            outcome = .replacedDirectory
        }
        try fileManager.createDirectory(
            at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: plan.destination.path, withDestinationPath: plan.snapshot.path)
        return outcome
    }

    /// What is at `destination`, judged against the model's cache folder by real path.
    ///
    /// - Parameters:
    ///   - destination: The link's path.
    ///   - snapshot: The snapshot the link should reach; nil before the revision is known.
    ///   - cache: The cache.
    ///   - repository: The repository.
    /// - Returns: The state.
    /// - Throws: `Failure.exists` when something else is there: a file, or a link elsewhere.
    static func linkState(
        at destination: URL, snapshot: URL?, cache: HubCache, _ repository: String
    ) throws -> Link {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path) else { return .absent }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) ?? ""
            let absolute =
                target.hasPrefix("/")
                ? target : destination.deletingLastPathComponent().appending(path: target).standardizedFileURL.path
            let real = CommandPolicy.canonical(absolute)
            if let snapshot, real == CommandPolicy.canonical(snapshot.path) { return .current }
            let snapshots = CommandPolicy.canonical(cache.folder(of: repository).appending(path: "snapshots").path)
            if real.hasPrefix(snapshots + "/") { return .stale(target) }
            throw Failure.exists(destination.path)
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.exists(destination.path) }
        return .directory
    }

    /// Runs `body` holding `huggingface_hub`'s lock file (an exclusive `flock`, as its `filelock` takes),
    /// refusing at once when another program holds it.
    ///
    /// - Throws: `Failure.busy`, or what `body` throws.
    static func locked<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw Failure.busy(url.path) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy(url.path) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await body()
    }

    /// Runs a request, turning a thrown error into `Failure.transport`.
    ///
    /// - Throws: `Failure.transport`.
    private func request<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// A file's size, following links; -1 when it is not there.
    static func size(of url: URL) -> Int {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
    }

    /// Checks a file's size, then its content: an LFS file's SHA-256, or a file kept in git by its git blob id (the
    /// SHA-1 of `blob <size>\0` and the content), the listing's `oid` and the name its blob takes in the cache, so
    /// a blob's name never claims content it does not hold. A file the listing gave neither for (a cached plan's,
    /// read from the snapshot itself) is checked by size alone.
    ///
    /// - Throws: `Failure.mismatch`.
    static func check(_ url: URL, against file: File) throws {
        let size = size(of: url)
        guard size == file.size else {
            throw Failure.mismatch(file: file.path, detail: "\(size) bytes, expected \(file.size)")
        }
        if let expected = file.sha256 {
            let digest = try sha256(of: url)
            guard digest == expected.lowercased() else {
                throw Failure.mismatch(file: file.path, detail: "SHA-256 \(digest), expected \(expected)")
            }
        } else if let expected = file.oid {
            let id = try gitBlobID(of: url, size: size)
            guard id == expected.lowercased() else {
                throw Failure.mismatch(file: file.path, detail: "git blob id \(id), expected \(expected)")
            }
        }
    }

    /// A file's git blob id as hex: the SHA-1 of `blob <size>\0` followed by its content, read in 4 MiB pieces.
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - size: Its size in bytes.
    /// - Returns: The id, as hex.
    /// - Throws: When the file cannot be read.
    static func gitBlobID(of url: URL, size: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A file's SHA-256 as hex, read in 4 MiB pieces.
    ///
    /// - Throws: When the file cannot be read.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: 4 << 20), !piece.isEmpty {
            hasher.update(data: piece)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes free for important use on the volume holding `url`.
    static func available(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

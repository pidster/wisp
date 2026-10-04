import CryptoKit
import Foundation
import WispCore

/// Fetches an `mlx-community` model from Hugging Face into the MLX models directory, for `wisp models pull`
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md)).
///
/// Nothing is fetched without the person's approval: `plan` only lists the repository, and the command asks
/// before `fetch` runs. The fetch is bounded: one organisation, the files an MLX model directory needs and
/// nothing else, every size known before the question and checked after each file, LFS files checked
/// against their SHA-256, and the whole refused when the disk lacks room. It resumes by file: the files of
/// an interrupted fetch stay in a hidden directory beside the destination, and the next run fetches only
/// those missing; the directory takes the model's name only when every file is in.
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
        /// A directory of that name is already there.
        case exists(String)
        /// The disk has less room than the files need.
        case noRoom(needed: Int, available: Int)
        /// A fetched file is not the size or digest the listing gave.
        case mismatch(file: String, detail: String)
        /// The request failed.
        case transport(String)

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
            case .exists(let path): "\(path) already exists; remove it first to fetch the model again"
            case .noRoom(let needed, let available):
                "the files need \(Self.size(needed)) and the disk has \(Self.size(available)) free"
            case .mismatch(let file, let detail): "\(file) did not arrive intact (\(detail)); run the pull again"
            case .transport(let detail): "the fetch failed: \(detail); run the pull again to resume"
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

        /// Creates a record.
        public init(path: String, size: Int, sha256: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// What a pull would fetch, for the person to approve.
    public struct Plan: Equatable, Sendable {
        /// `mlx-community/<name>`.
        public var repository: String
        /// The directory's name, and what follows `mlx:` to select it.
        public var name: String
        /// Where the model will be.
        public var destination: URL
        /// Where files wait until every one is in.
        public var partial: URL
        /// The files to have.
        public var files: [File]
        /// The files a previous, interrupted pull already fetched.
        public var present: [String]

        /// Bytes of every file.
        public var bytes: Int { files.reduce(0) { $0 + $1.size } }
        /// Bytes still to fetch.
        public var remaining: Int { files.filter { !present.contains($0.path) }.reduce(0) { $0 + $1.size } }
    }

    /// How a pull talks to Hugging Face; a protocol so tests serve the repository from memory.
    public protocol Transport: Sendable {
        /// The body and status of a GET.
        ///
        /// - Throws: When the request fails.
        func data(from url: URL) async throws -> (Data, Int)
        /// Downloads a GET's body to a temporary file, returning it and the status.
        ///
        /// - Throws: When the request fails.
        func download(from url: URL) async throws -> (URL, Int)
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

        /// Downloads a GET's body to a temporary file.
        ///
        /// - Throws: When the request fails.
        public func download(from url: URL) async throws -> (URL, Int) {
            let (file, response) = try await session.download(from: url)
            return (file, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
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

    /// Creates a pull against Hugging Face.
    public init(hub: URL = ModelPull.hub, transport: any Transport = SessionTransport()) {
        self.hub = hub
        self.transport = transport
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

    /// Reads the repository's file list from the Hub's tree listing, keeping the wanted files.
    ///
    /// - Parameter data: The listing's body.
    /// - Returns: The files, sorted by path.
    /// - Throws: `Failure.badListing`.
    static func files(fromListing data: Data) throws -> [File] {
        guard let entries = (try? JSONDecoder().decode(JSONValue.self, from: data))?.arrayValue else {
            throw Failure.badListing(String(decoding: data.prefix(120), as: UTF8.self))
        }
        return entries.compactMap { entry -> File? in
            guard let object = entry.objectValue, object["type"]?.stringValue == "file",
                let path = object["path"]?.stringValue, wanted(path)
            else { return nil }
            let lfs = object["lfs"]?.objectValue
            guard let size = lfs?["size"]?.intValue ?? object["size"]?.intValue else { return nil }
            return File(path: path, size: size, sha256: lfs?["oid"]?.stringValue)
        }.sorted { $0.path < $1.path }
    }

    /// Lists the repository and says what a pull would fetch, and what an interrupted one already has.
    ///
    /// - Parameters:
    ///   - text: The repository, as the person typed it.
    ///   - directory: The MLX models directory.
    /// - Returns: The plan.
    /// - Throws: `Failure`.
    public func plan(_ text: String, into directory: URL) async throws -> Plan {
        let (repository, name) = try Self.repository(text)
        let destination = directory.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.exists(destination.path)
        }
        let listing = hub.appending(path: "api/models/\(repository)/tree/main")
        let (data, status) = try await request { try await transport.data(from: listing) }
        guard status == 200 else { throw Failure.http(status: status, url: listing.absoluteString) }
        let files = try Self.files(fromListing: data)
        guard files.contains(where: { $0.path == "config.json" }),
            files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else { throw Failure.notAModel(repository) }
        let partial = directory.appending(path: ".\(name).partial", directoryHint: .isDirectory)
        let present = files.filter { file in
            let url = partial.appending(path: file.path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            return size == file.size
        }.map(\.path)
        return Plan(
            repository: repository, name: name, destination: destination, partial: partial, files: files,
            present: present)
    }

    /// Fetches the files the plan still lacks, checks each, and moves the directory into place.
    ///
    /// - Parameters:
    ///   - plan: The approved plan.
    ///   - available: Bytes free on the destination's volume; nil reads them.
    ///   - progress: Told of each file as it starts, with its index from 1.
    /// - Returns: Bytes fetched by this run.
    /// - Throws: `Failure`; the files fetched so far stay for the next run.
    public func fetch(
        _ plan: Plan, available: Int? = nil, progress: (File, Int) -> Void = { _, _ in }
    ) async throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: plan.partial, withIntermediateDirectories: true)
        let free = available ?? Self.available(at: plan.partial)
        guard plan.remaining + Self.margin <= free else {
            throw Failure.noRoom(needed: plan.remaining + Self.margin, available: free)
        }
        var fetched = 0
        for (index, file) in plan.files.enumerated() where !plan.present.contains(file.path) {
            progress(file, index + 1)
            let url = hub.appending(path: "\(plan.repository)/resolve/main/\(file.path)")
            let (temporary, status) = try await request { try await transport.download(from: url) }
            defer { try? fileManager.removeItem(at: temporary) }
            guard status == 200 else { throw Failure.http(status: status, url: url.absoluteString) }
            try Self.check(temporary, against: file)
            let target = plan.partial.appending(path: file.path)
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: temporary, to: target)
            fetched += file.size
        }
        guard !fileManager.fileExists(atPath: plan.destination.path) else {
            throw Failure.exists(plan.destination.path)
        }
        try fileManager.moveItem(at: plan.partial, to: plan.destination)
        return fetched
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

    /// Checks a fetched file's size, and an LFS file's SHA-256.
    ///
    /// - Throws: `Failure.mismatch`.
    static func check(_ url: URL, against file: File) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard size == file.size else {
            throw Failure.mismatch(file: file.path, detail: "\(size) bytes, expected \(file.size)")
        }
        guard let expected = file.sha256 else { return }
        let digest = try sha256(of: url)
        guard digest == expected.lowercased() else {
            throw Failure.mismatch(file: file.path, detail: "SHA-256 \(digest), expected \(expected)")
        }
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

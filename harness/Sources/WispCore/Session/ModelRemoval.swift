import Foundation

/// What `wisp models uninstall` removes for one model, as its backend reads it before anything changes
/// ([ADR 0075](../../../../docs/decisions/0075-wisp-models-uninstall.md)): Ollama's copy through Ollama's own delete;
/// a link in wisp's models folder, removed, leaving what it points to; a real folder there, moved to the Bin; and,
/// asked for with `--purge-cache`, an MLX model's whole folder in the Hugging Face cache, removed. Apple's models are
/// the system's, and llama.cpp's and LM Studio's their servers', so their backends refuse.
public struct ModelRemoval: Equatable, Sendable {
    /// One thing removed.
    public enum Step: Equatable, Sendable {
        /// Ollama's copy, by its name, through `DELETE /api/delete`.
        case ollama(String)
        /// A link in the models folder, and what it points to, which stays.
        case unlink(URL, pointsTo: URL)
        /// A real folder in the models folder, moved to the Bin.
        case trash(URL)
        /// A repository's folder in the Hugging Face cache, every revision and blob in it, removed. Blobs its blobs
        /// link to in a store at the cache's root, which another tool keeps, are not touched.
        case purge(URL)

        /// The step as the plan shows it.
        public var described: String {
            switch self {
            case .ollama(let name): "Ollama's copy of \(name), through Ollama's delete"
            case .unlink(let link, let target): "the link \(link.path) (it points to \(target.path), which stays)"
            case .trash(let folder): "\(folder.path), moved to the Bin"
            case .purge(let folder): "\(folder.path) in the Hugging Face cache, every revision, removed"
            }
        }
    }

    /// Why a model cannot be removed.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Its runtime or the system keeps it; where to remove it instead.
        case notWisps(model: String, reason: String)
        /// It is not there to remove.
        case notInstalled(model: String, reason: String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .notWisps(let model, let reason): "\(model) is not wisp's to remove: \(reason)"
            case .notInstalled(let model, let reason): "\(model) is not installed: \(reason)"
            }
        }
    }

    /// The model, as `--model` spells it.
    public var model: String
    /// What goes, in order.
    public var steps: [Step]
    /// The bytes the steps free; a link frees none, and Ollama's figure is its listing's.
    public var bytes: Int64
    /// What stays that the person may want to know of, such as the cache a link points into and what purging it
    /// would free.
    public var kept: [String]

    /// Creates a plan.
    public init(model: String, steps: [Step], bytes: Int64, kept: [String] = []) {
        self.model = model
        self.steps = steps
        self.bytes = bytes
        self.kept = kept
    }

    /// The bytes of the regular files under `url`, links not followed, so a cache's blobs count once; zero when
    /// nothing can be read.
    ///
    /// - Parameter url: A file or folder.
    /// - Returns: The total.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            guard let found = try? file.resourceValues(forKeys: Set(keys)), found.isSymbolicLink != true,
                found.isRegularFile == true
            else { continue }
            total += Int64(found.fileSize ?? 0)
        }
        return total
    }

    /// The plan for a model in a models folder: a link removed, leaving its target, or a real folder moved to the
    /// Bin; for an MLX model whose link points into the Hugging Face cache, its repository's folder there named as
    /// kept, or removed with `purgeCache`.
    ///
    /// - Parameters:
    ///   - model: The model, as `--model` spells it.
    ///   - entry: Its path in the models folder.
    ///   - cacheRoot: The Hugging Face cache's root, for an MLX model; nil for a backend without one.
    ///   - purgeCache: Whether the cache's folder goes too.
    /// - Returns: The plan.
    /// - Throws: `Failure.notInstalled` when nothing is at `entry`.
    public static func folder(
        model: String, entry: URL, cacheRoot: URL?, purgeCache: Bool
    ) throws -> ModelRemoval {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: entry.path) {
            let target =
                destination.hasPrefix("/")
                ? URL(filePath: destination) : entry.deletingLastPathComponent().appending(path: destination)
            let resolved = target.standardizedFileURL.resolvingSymlinksInPath()
            var steps: [Step] = [.unlink(entry, pointsTo: resolved)]
            var kept: [String] = []
            var bytes: Int64 = 0
            if let cacheRoot, let repository = repositoryFolder(of: resolved, in: cacheRoot) {
                let size = Self.size(of: repository)
                let stored = storedBlobs(of: repository, in: cacheRoot)
                if !stored.isEmpty {
                    let storedBytes = stored.reduce(Int64(0)) { $0 + Self.size(of: $1) }
                    kept.append(
                        "\(formatted(storedBytes)) of its files are in \(cacheRoot.path)/blobs, a store another tool "
                            + "keeps; wisp leaves it to that tool")
                }
                if purgeCache {
                    steps.append(.purge(repository))
                    bytes = size
                } else {
                    kept.append(
                        "\(repository.path) stays in the Hugging Face cache (\(formatted(size))); --purge-cache "
                            + "removes it too, for every tool that shares the cache")
                }
            } else if purgeCache {
                kept.append("--purge-cache does nothing here: the link does not point into the Hugging Face cache")
            }
            return ModelRemoval(model: model, steps: steps, bytes: bytes, kept: kept)
        }
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: entry.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw Failure.notInstalled(model: model, reason: "nothing at \(entry.path)")
        }
        var kept: [String] = []
        if purgeCache { kept.append("--purge-cache does nothing here: the model is a folder, not a link into a cache") }
        return ModelRemoval(model: model, steps: [.trash(entry)], bytes: size(of: entry), kept: kept)
    }

    /// The repository's folder in the cache (`models--org--name`) a snapshot path is under, or nil outside it.
    ///
    /// - Parameters:
    ///   - path: A path, links resolved.
    ///   - cacheRoot: The cache's root.
    /// - Returns: The folder.
    static func repositoryFolder(of path: URL, in cacheRoot: URL) -> URL? {
        let root = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let full = path.standardizedFileURL.path
        guard full.hasPrefix(root + "/") else { return nil }
        guard let first = full.dropFirst(root.count + 1).split(separator: "/").first, first.hasPrefix("models--")
        else { return nil }
        return URL(filePath: root).appending(path: String(first))
    }

    /// The files in a store at the cache's root (`<cache>/blobs`, which another tool keeps) that `repository`'s own
    /// blobs link to: listed and sized for the plan, never removed (ADR 0075).
    ///
    /// - Parameters:
    ///   - repository: The repository's folder, `models--org--name`.
    ///   - cacheRoot: The cache's root.
    /// - Returns: Their real paths, sorted.
    static func storedBlobs(of repository: URL, in cacheRoot: URL) -> [URL] {
        let manager = FileManager.default
        let root = cacheRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let folder = repository.standardizedFileURL.resolvingSymlinksInPath()
        let blobs = folder.appending(path: "blobs")
        var found: Set<String> = []
        for name in (try? manager.contentsOfDirectory(atPath: blobs.path)) ?? [] {
            let blob = blobs.appending(path: name)
            guard (try? manager.destinationOfSymbolicLink(atPath: blob.path)) != nil else { continue }
            let real = blob.resolvingSymlinksInPath().path
            if real.hasPrefix(root + "/"), !real.hasPrefix(folder.path + "/") { found.insert(real) }
        }
        return found.sorted().map { URL(filePath: $0) }
    }

    /// Bytes as the plan shows them.
    public static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Carries out the steps in order, telling `report` each as it is done, and stopping at the first that fails.
    ///
    /// - Parameters:
    ///   - ollama: The Ollama server, for an Ollama step.
    ///   - report: Told a line for each step done, as it is done.
    ///   - trash: Moves a folder to the Bin; tests replace it.
    ///   - delete: Asks Ollama to delete a model; tests replace it.
    /// - Throws: The failing step's error; the steps before it were reported.
    public func perform(
        ollama: OllamaSettings, report: (String) -> Void,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
        delete: (String, OllamaSettings) async throws -> Void = { try await OllamaModel.delete($0, at: $1) }
    ) async throws {
        for step in steps {
            switch step {
            case .ollama(let name):
                try await delete(name, ollama)
                report("deleted \(name) from Ollama")
            case .unlink(let link, _):
                try FileManager.default.removeItem(at: link)
                report("removed the link \(link.path)")
            case .trash(let folder):
                try trash(folder)
                report("moved \(folder.path) to the Bin")
            case .purge(let folder):
                try FileManager.default.removeItem(at: folder)
                report("removed \(folder.path) from the Hugging Face cache")
            }
        }
    }
}

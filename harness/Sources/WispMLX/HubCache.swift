import Foundation
import WispCore

/// The Hugging Face cache, in `huggingface_hub`'s own layout, which `wisp models pull` fills and reads so a
/// model fetched by any Hugging Face tool is stored once
/// ([ADR 0052](../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), refined 2026-10-04).
///
/// One folder per repository, `models--<org>--<name>`, holding `blobs/<id>` (the content, named by the LFS
/// SHA-256 for LFS files and by the git blob id otherwise), `snapshots/<revision>/<file>` (relative links
/// `../../blobs/<id>`), and `refs/main` (the revision `main` was at). A download in progress is
/// `blobs/<id>.incomplete`, and `huggingface_hub` serialises fetches of one blob with a lock file under
/// `.locks/<folder>/<id>.lock`, which wisp takes too.
public struct HubCache: Equatable, Sendable {
    /// The cache's root, the directory holding the `models--…` folders.
    public var root: URL

    /// Creates a cache at `root`.
    public init(root: URL) {
        self.root = root
    }

    /// The root `huggingface_hub` uses: `HF_HUB_CACHE`, else the older `HUGGINGFACE_HUB_CACHE`, else
    /// `$HF_HOME/hub`, else `$XDG_CACHE_HOME/huggingface/hub`, else `~/.cache/huggingface/hub`. A leading `~`
    /// is expanded; an empty variable counts as unset.
    ///
    /// - Parameters:
    ///   - environment: The process's environment.
    ///   - home: The home directory, for `~` and the default.
    /// - Returns: The cache.
    public static func resolve(environment: [String: String], home: URL) -> HubCache {
        func value(_ name: String) -> String? {
            guard let text = environment[name], !text.isEmpty else { return nil }
            if text == "~" { return home.path }
            if text.hasPrefix("~/") { return home.appending(path: String(text.dropFirst(2))).path }
            return text
        }
        if let hub = value("HF_HUB_CACHE") ?? value("HUGGINGFACE_HUB_CACHE") {
            return HubCache(root: URL(filePath: hub, directoryHint: .isDirectory))
        }
        let caches = URL(
            filePath: value("XDG_CACHE_HOME") ?? home.appending(path: ".cache").path, directoryHint: .isDirectory)
        let huggingFace = URL(
            filePath: value("HF_HOME") ?? caches.appending(path: "huggingface").path, directoryHint: .isDirectory)
        return HubCache(root: huggingFace.appending(path: "hub", directoryHint: .isDirectory))
    }

    /// The cache this process's environment names.
    public static func current() -> HubCache {
        let environment = ProcessInfo.processInfo.environment
        let home =
            environment["HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return resolve(environment: environment, home: home)
    }

    /// The folder name of a model repository: `models--<org>--<name>`.
    ///
    /// - Parameter repository: `<org>/<name>`.
    /// - Returns: The folder's name.
    public static func folderName(of repository: String) -> String {
        "models--" + repository.replacing("/", with: "--")
    }

    /// The repository's folder.
    public func folder(of repository: String) -> URL {
        root.appending(path: Self.folderName(of: repository), directoryHint: .isDirectory)
    }

    /// Where a blob is.
    public func blob(_ id: String, of repository: String) -> URL {
        folder(of: repository).appending(path: "blobs/\(id)")
    }

    /// A revision's snapshot directory.
    public func snapshot(_ revision: String, of repository: String) -> URL {
        folder(of: repository).appending(path: "snapshots/\(revision)", directoryHint: .isDirectory)
    }

    /// The revision `refs/main` names, if the repository is cached.
    public func mainRevision(of repository: String) -> String? {
        let url = folder(of: repository).appending(path: "refs/main")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let revision = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isRevision(revision) ? revision : nil
    }

    /// The lock file `huggingface_hub` takes while it fetches a blob.
    func lock(_ id: String, of repository: String) -> URL {
        root.appending(path: ".locks/\(Self.folderName(of: repository))/\(id).lock")
    }

    /// Whether `text` is a commit sha, safe to use as a directory name.
    static func isRevision(_ text: String) -> Bool { text.count == 40 && isHex(text) }

    /// Whether `text` is a blob id: a git blob id (40 hex) or a SHA-256 (64 hex), safe as a file name.
    static func isBlobID(_ text: String) -> Bool { (text.count == 40 || text.count == 64) && isHex(text) }

    /// Whether every character is a lowercase hexadecimal digit.
    private static func isHex(_ text: String) -> Bool {
        text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Whether a snapshot directory looks like a whole MLX model, judged without the Hub's listing: a
    /// `config.json` and at least one `*.safetensors`, every entry reaching its blob (none dangling), and,
    /// when `model.safetensors.index.json` is there, every shard it names present.
    ///
    /// - Parameter snapshot: The snapshot directory.
    /// - Returns: Whether it is complete as far as the directory can tell.
    public static func looksComplete(_ snapshot: URL) -> Bool {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: snapshot.path),
            entries.contains("config.json"), entries.contains(where: { $0.hasSuffix(".safetensors") }),
            entries.allSatisfy({ fileManager.fileExists(atPath: snapshot.appending(path: $0).path) })
        else { return false }
        let index = snapshot.appending(path: "model.safetensors.index.json")
        guard let data = try? Data(contentsOf: index) else { return true }
        guard
            let shards = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue?["weight_map"]?
                .objectValue?.values.compactMap(\.stringValue)
        else { return false }
        return Set(shards).allSatisfy(entries.contains)
    }

    /// The `mlx-community` models whose `main` snapshot looks complete here and that nothing in the models
    /// directory names yet, so `wisp models pull` would link them without fetching. Sorted by repository.
    ///
    /// - Parameter modelsDirectory: The MLX models directory.
    /// - Returns: The repositories, `mlx-community/<name>`.
    public func unlinked(in modelsDirectory: URL) -> [String] {
        let prefix = Self.folderName(of: "\(ModelPull.organisation)/")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return folders.filter { $0.hasPrefix(prefix) }.sorted().compactMap { folder in
            let repository = "\(ModelPull.organisation)/\(folder.dropFirst(prefix.count))"
            guard let (_, name) = try? ModelPull.repository(repository),
                let revision = mainRevision(of: repository),
                Self.looksComplete(snapshot(revision, of: repository)),
                !Self.occupied(modelsDirectory.appending(path: name))
            else { return nil }
            return repository
        }
    }

    /// Whether anything is at `url`, a dangling link included.
    static func occupied(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}

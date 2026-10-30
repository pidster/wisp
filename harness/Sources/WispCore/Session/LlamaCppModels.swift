import Foundation

/// The models wisp's own llama.cpp server serves under `llamacpp.server wisp`
/// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 2): a folder of links,
/// `<support>/llamacpp/models` (`~/Library/Application Support/Wisp/llamacpp/models`), each `<name>.gguf` pointing to
/// a GGUF file the person added with `wisp models add`. The name is the file's name without `.gguf`, as llama-server's
/// router names each file in `--models-dir` (probed on 2026-10-29). wisp never copies, moves, or deletes a GGUF file,
/// and does not scan the disk for them: only what the person adds is here.
public struct LlamaCppModels: Equatable, Sendable {
    /// Why a file was not added.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Adding is for wisp's own server; the setting names another.
        case notWispsServer(LlamaCppServer)
        /// The path is not a regular file wisp can read.
        case notAFile(String)
        /// The file is not a GGUF file: its name or its first four bytes.
        case notGGUF(String, reason: String)
        /// The file's name would not make a model name.
        case badName(String)
        /// Another file is linked under the name already.
        case taken(name: String, linksTo: String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .notWispsServer(let server):
                server == .llamaApp
                    ? "llamacpp.server is llama-app: Llama.app keeps its own models; add the model in Llama.app"
                    : "models are added for wisp's own llama.cpp server, and llamacpp.server is \(server.rawValue) "
                        + "(a llama-server you start, serving the file it was started with); set llamacpp.server "
                        + "wisp first"
            case .notAFile(let path): "\(path) is not a file wisp can read"
            case .notGGUF(let path, let reason): "\(path) is not a GGUF file: \(reason)"
            case .badName(let name):
                "'\(name)' cannot name a model: a GGUF file's name, without .gguf, must be \(SafeName.rule), not "
                    + "starting with '.'; rename the file"
            case .taken(let name, let target):
                "llamacpp:\(name) is linked already, to \(target); wisp models uninstall llamacpp:\(name) removes "
                    + "that link first"
            }
        }
    }

    /// One link in the folder.
    public struct Link: Equatable, Sendable {
        /// The model's name, after `llamacpp:`.
        public var name: String
        /// The link's path in the folder.
        public var link: URL
        /// The file it points to, as the link records it.
        public var target: URL
        /// The file's bytes; nil when it is missing, the link broken.
        public var bytes: Int?

        /// Whether the file it points to is missing.
        public var broken: Bool { bytes == nil }

        /// Creates a record.
        public init(name: String, link: URL, target: URL, bytes: Int?) {
            self.name = name
            self.link = link
            self.target = target
            self.bytes = bytes
        }
    }

    /// What adding a file did.
    public struct Added: Equatable, Sendable {
        /// The link, as it now stands.
        public var link: Link
        /// Whether it was there already, pointing to the same file, so nothing changed.
        public var unchanged: Bool

        /// Creates a record.
        public init(link: Link, unchanged: Bool) {
            self.link = link
            self.unchanged = unchanged
        }
    }

    /// The folder.
    public let folder: URL

    /// The links in `folder`.
    public init(folder: URL) {
        self.folder = folder
    }

    /// The folder in `home`'s Application Support folder.
    public init(home: Home) {
        self.init(folder: home.support.appending(path: "llamacpp/models", directoryHint: .isDirectory))
    }

    /// A model file's extension.
    static let fileExtension = "gguf"
    /// The first four bytes of every GGUF file.
    static let magic = Data("GGUF".utf8)

    /// The link for `name`, whether or not it exists.
    ///
    /// - Parameter name: The model's name, after `llamacpp:`.
    /// - Returns: Its path in the folder.
    func path(of name: String) -> URL {
        folder.appending(path: "\(name).\(Self.fileExtension)")
    }

    /// Every link in the folder, by name; anything else there (a real file, a folder) is not wisp's and is left out.
    public func linked() -> [Link] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return
            names
            .filter { $0.hasSuffix(".\(Self.fileExtension)") }
            .compactMap { link(named: String($0.dropLast(Self.fileExtension.count + 1))) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The link for `name`, or nil when there is none (or something there is not a link).
    ///
    /// - Parameter name: The model's name, after `llamacpp:`.
    /// - Returns: The link.
    public func link(named name: String) -> Link? {
        let link = self.path(of: name)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        let target =
            destination.hasPrefix("/") ? URL(filePath: destination) : folder.appending(path: destination)
        let values = try? target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let bytes = values?.isRegularFile == true ? values?.fileSize ?? 0 : nil
        return Link(name: name, link: link, target: target, bytes: bytes)
    }

    /// The model name a GGUF file's path gives: its last component without `.gguf`, any case.
    ///
    /// - Parameter path: The file, as given.
    /// - Returns: The name.
    /// - Throws: `Failure.notGGUF` for a name not ending in `.gguf`; `Failure.badName` for one that cannot name a
    ///   model.
    static func name(of path: URL) throws -> String {
        let file = path.lastPathComponent
        guard path.pathExtension.lowercased() == fileExtension else {
            throw Failure.notGGUF(path.path, reason: "its name does not end in .gguf")
        }
        let name = String(file.dropLast(fileExtension.count + 1))
        guard SafeName.isValid(name), !name.hasPrefix(".") else { throw Failure.badName(name) }
        return name
    }

    /// Links a GGUF file into the folder as `<name>.gguf`, pointing to its real path, so wisp's server serves it as
    /// `llamacpp:<name>`; the name comes from the path as given, so a link to a file named otherwise (such as a
    /// Hugging Face cache's snapshot) keeps the name the person sees. The folder is made, owner only, when missing.
    /// The file is never copied or moved. Adding the same file again changes nothing.
    ///
    /// - Parameters:
    ///   - path: The file, as typed: absolute, `~/…`, or relative to `workingDirectory`.
    ///   - workingDirectory: Where a relative path starts.
    /// - Returns: The link, and whether it was there already.
    /// - Throws: `Failure` for a path that is not a readable GGUF file whose name makes a model name, or a name
    ///   linked to another file; the file system's error when the link cannot be made.
    public func add(_ path: String, workingDirectory: URL) throws -> Added {
        let manager = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        // Not standardised: Foundation's standardising, like its resolving, drops `/private` from `/private/var`.
        let given = expanded.hasPrefix("/") ? URL(filePath: expanded) : workingDirectory.appending(path: expanded)
        // The real path, by realpath(3), `..` and links resolved.
        let real = URL(filePath: CommandPolicy.canonical(given.path))
        let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, manager.isReadableFile(atPath: real.path) else {
            throw Failure.notAFile(given.path)
        }
        let name = try Self.name(of: given)
        guard let handle = FileHandle(forReadingAtPath: real.path) else { throw Failure.notAFile(given.path) }
        let head = (try? handle.read(upToCount: Self.magic.count)) ?? nil
        try? handle.close()
        guard head == Self.magic else {
            throw Failure.notGGUF(given.path, reason: "it does not begin with GGUF's magic bytes")
        }
        let link = self.path(of: name)
        if let existing = self.link(named: name) {
            guard CommandPolicy.canonical(existing.target.path) == real.path else {
                throw Failure.taken(name: name, linksTo: existing.target.path)
            }
            return Added(link: existing, unchanged: true)
        }
        // Something at the path that is not a link (on a case-insensitive volume, also another case of the name).
        if (try? manager.attributesOfItem(atPath: link.path)) != nil {
            throw Failure.taken(name: name, linksTo: "\(link.path), which is not a link wisp made")
        }
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.createSymbolicLink(at: link, withDestinationURL: real)
        return Added(
            link: Link(name: name, link: link, target: real, bytes: values?.fileSize ?? 0), unchanged: false)
    }

    /// What `wisp models uninstall llamacpp:<name>` removes under `llamacpp.server wisp`: the link only; the GGUF file
    /// it points to stays where it is (ADR 0075's flow, ADR 0082).
    ///
    /// - Parameters:
    ///   - name: The model's name, after `llamacpp:`.
    ///   - purgeCache: Whether `--purge-cache` was given, which does nothing here.
    /// - Returns: The plan.
    /// - Throws: `ModelRemoval.Failure.notInstalled` when no link has the name.
    func removal(_ name: String, purgeCache: Bool) throws -> ModelRemoval {
        let model = "\(OpenAICompatibleDialect.llamaCpp.scheme):\(name)"
        guard let link = link(named: name) else {
            throw ModelRemoval.Failure.notInstalled(
                model: model, reason: "no link \(path(of: name).path); wisp models lists the models added")
        }
        var kept = [
            link.broken
                ? "\(link.target.path), the file it pointed to, is missing already"
                : "the GGUF file \(link.target.path) stays where it is; wisp never deletes it"
        ]
        if purgeCache { kept.append("--purge-cache does nothing here: a llama.cpp model has no cache") }
        return ModelRemoval(
            model: model, steps: [.unlink(link.link, pointsTo: link.target)], bytes: 0, kept: kept)
    }
}

import Foundation
import Synchronization

/// What a pull would fetch and link, as the person, the approval, and the audit are told of it
/// ([ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)). Made by a `ModelPuller` from its plan, so
/// `WispCore` can put the publisher question and the approval without knowing how a runtime fetches.
public struct PullSummary: Equatable, Sendable {
    /// `<organisation>/<name>`.
    public var repository: String
    /// The model's name: the link's name, and what follows `mlx:` to select it.
    public var name: String
    /// The commit the pull fills the snapshot of.
    public var revision: String
    /// The licence the Hub gives; nil when it gives none.
    public var licence: String?
    /// The files the model needs.
    public var files: Int
    /// Bytes of every file.
    public var bytes: Int
    /// The files still to download.
    public var missing: Int
    /// Bytes still to download.
    public var remaining: Int
    /// The link's path in the models directory.
    public var destination: String
    /// The snapshot in the Hugging Face cache the link points at.
    public var snapshot: String
    /// Whether a real directory of its own is at the link's path, so linking asks to replace it.
    public var replacesDirectory: Bool
    /// The files the cache already holds, checked.
    public var reused: Int
    /// The files copied from the model's own directory instead of fetched.
    public var seeded: Int
    /// The plan for the person: each file and where it comes from, the snapshot, and the link.
    public var lines: [String]

    /// Creates a summary.
    public init(
        repository: String, name: String, revision: String, licence: String?, files: Int, bytes: Int, missing: Int,
        remaining: Int, destination: String, snapshot: String, replacesDirectory: Bool, reused: Int, seeded: Int,
        lines: [String]
    ) {
        self.repository = repository
        self.name = name
        self.revision = revision
        self.licence = licence
        self.files = files
        self.bytes = bytes
        self.missing = missing
        self.remaining = remaining
        self.destination = destination
        self.snapshot = snapshot
        self.replacesDirectory = replacesDirectory
        self.reused = reused
        self.seeded = seeded
        self.lines = lines
    }

    /// The organisation that publishes the repository, the part before the `/`.
    public var publisher: String { String(repository.prefix { $0 != "/" }) }
    /// The selection the model becomes.
    public var selection: String { "mlx:\(name)" }

    /// Bytes for people.
    ///
    /// - Parameter bytes: The count.
    /// - Returns: Such as `2.3 GB`.
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// How far a pull's download has gone, for a face's status line (ADR 0059).
public struct PullProgress: Equatable, Sendable {
    /// The repository.
    public var repository: String
    /// The file being fetched.
    public var file: String
    /// Its size in bytes.
    public var size: Int
    /// Its position among the files to fetch, from 1.
    public var index: Int
    /// The files to fetch.
    public var files: Int
    /// Bytes this run has fetched so far, across every file.
    public var fetched: Int
    /// Bytes this run has to fetch.
    public var total: Int

    /// Creates a record.
    public init(repository: String, file: String, size: Int, index: Int, files: Int, fetched: Int, total: Int) {
        self.repository = repository
        self.file = file
        self.size = size
        self.index = index
        self.files = files
        self.fetched = fetched
        self.total = total
    }

    /// What a face shows: `pulling mlx-community/q: 1.2 GB of 4.5 GB, file 2 of 7`.
    public var line: String {
        "pulling \(repository): \(PullSummary.size(fetched)) of \(PullSummary.size(total)), file \(index) of \(files)"
    }
}

/// A pull planned and not yet run: what it would do, and how to do it once decided. Its closures hold the runtime's
/// own plan, so nothing outside the runtime handles it.
public struct PreparedPull: Sendable {
    /// What it would fetch and link.
    public var summary: PullSummary
    /// Fetches what is missing, checking each file, telling the first closure how far it has gone and the second of a
    /// file copied, resumed, or started again; returns the bytes fetched. Cancelled with its task, it stops, keeping the
    /// part of the file being fetched for the next pull to resume.
    public var fetch:
        @Sendable (
            _ progress: @escaping @Sendable (PullProgress) -> Void, _ notice: @escaping @Sendable (String) -> Void
        ) async throws -> Int
    /// Links the models directory to the snapshot, replacing a real directory there only when told to; returns what
    /// happened at the link's path (`ModelPull.LinkOutcome`'s words) and the line for the person.
    public var link: @Sendable (_ replacingDirectory: Bool) throws -> (outcome: String, closing: String)

    /// Creates one.
    public init(
        summary: PullSummary,
        fetch:
            @escaping @Sendable (
                _ progress: @escaping @Sendable (PullProgress) -> Void, _ notice: @escaping @Sendable (String) -> Void
            ) async throws -> Int,
        link: @escaping @Sendable (_ replacingDirectory: Bool) throws -> (outcome: String, closing: String)
    ) {
        self.summary = summary
        self.fetch = fetch
        self.link = link
    }
}

/// A runtime that fetches models (MLX, from Hugging Face, ADR 0052), registered by the executable so `WispCore` never
/// links it; `ModelActions` puts the questions around it.
public protocol ModelPuller: Sendable {
    /// The repository a request names, and the model's name, refusing anything that is not one.
    ///
    /// - Parameter text: What was typed or asked for.
    /// - Returns: The repository and the name.
    /// - Throws: The runtime's failure, which says what a name must be.
    func repository(_ text: String) throws -> (repository: String, name: String)
    /// Lists the repository and says what a pull would fetch and link, writing nothing.
    ///
    /// - Parameters:
    ///   - text: The repository, as asked for.
    ///   - session: The session, for its configuration and home.
    ///   - notice: Told of a slow step, such as a cached file's digest being read.
    /// - Returns: The pull, ready to run.
    /// - Throws: The runtime's failure.
    func prepare(
        _ text: String, session: Session, notice: @escaping @Sendable (String) -> Void
    ) async throws
        -> PreparedPull
}

/// The puller this process registered, if any.
public enum ModelPullers {
    /// The registered puller.
    private static let registered = Mutex<(any ModelPuller)?>(nil)

    /// Registers the puller; the executable calls this at launch.
    ///
    /// - Parameter puller: The puller.
    public static func register(_ puller: any ModelPuller) {
        registered.withLock { $0 = puller }
    }

    /// The registered puller; nil in a build that registers none.
    public static var current: (any ModelPuller)? { registered.withLock { $0 } }
}

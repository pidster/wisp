import Foundation
import WispCore

/// `ModelPull` as `WispCore`'s `ModelPuller` ([ADR 0059](../../../docs/decisions/0059-one-set-of-model-actions.md)), so
/// `wisp models pull`, chat's `/models pull`, and the model's `models` tool all reach the same plan, fetch, and link,
/// with `ModelActions` putting the questions around them. The executable registers it at launch.
public struct MLXPuller: ModelPuller {
    /// Where Hugging Face is; a test server elsewhere.
    public var hub: URL
    /// How requests are made.
    public var transport: any ModelPull.Transport
    /// The Hugging Face cache; nil reads the environment's when a pull is prepared.
    public var cache: HubCache?
    /// How often a fetch's progress is reported while a file arrives.
    public var interval: Duration

    /// Creates a puller against Hugging Face.
    ///
    /// - Parameters:
    ///   - hub: Hugging Face, or a test server.
    ///   - transport: How requests are made.
    ///   - cache: The cache; nil for the one this process's environment names.
    ///   - interval: How often progress is reported while a file arrives.
    public init(
        hub: URL = ModelPull.hub, transport: any ModelPull.Transport = ModelPull.SessionTransport(),
        cache: HubCache? = nil, interval: Duration = .milliseconds(500)
    ) {
        self.hub = hub
        self.transport = transport
        self.cache = cache
        self.interval = interval
    }

    /// The repository a request names, as `ModelPull.repository` accepts it.
    ///
    /// - Throws: `ModelPull.Failure.notAllowed`.
    public func repository(_ text: String) throws -> (repository: String, name: String) {
        try ModelPull.repository(text)
    }

    /// Plans the pull into the session's MLX models directory, and wraps the plan's fetch and link.
    ///
    /// - Throws: `ModelPull.Failure`.
    public func prepare(
        _ text: String, session: Session, notice: @escaping @Sendable (String) -> Void
    ) async throws
        -> PreparedPull
    {
        let directory = MLXBackend.modelsDirectory(config: session.config, home: session.home)
        let pull = ModelPull(hub: hub, transport: transport, cache: cache ?? .current())
        let plan = try await pull.plan(text, into: directory) { file in
            notice("checking \(file.path) (\(PullSummary.size(file.size))) against the listing's SHA-256")
        }
        let interval = interval
        return PreparedPull(
            summary: plan.summary,
            fetch: { progress, notice in
                try await Self.fetch(pull, plan, interval: interval, progress: progress, notice: notice)
            },
            link: { replacing in
                let outcome = try pull.link(plan, replacingDirectory: replacing)
                return (outcome.rawValue, Self.closing(plan, outcome))
            })
    }

    /// Runs the plan's fetch, telling `progress` as each file starts and, every `interval` while it arrives, how many
    /// bytes have, read from the size of its `.incomplete` part. A cancelled task stops between files and inside one
    /// (the transport's request is cancelled with it), keeping the part for the next pull to resume.
    ///
    /// - Parameters:
    ///   - pull: The pull.
    ///   - plan: The approved plan.
    ///   - interval: How often progress is reported.
    ///   - progress: Told how far the fetch has gone.
    ///   - notice: Told of a file copied, resumed, or started again.
    /// - Returns: Bytes fetched.
    /// - Throws: `ModelPull.Failure`, or `CancellationError` when cancelled.
    static func fetch(
        _ pull: ModelPull, _ plan: ModelPull.Plan, interval: Duration,
        progress: @escaping @Sendable (PullProgress) -> Void, notice: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        let missing = plan.missing
        // The file arriving now, its index, and the bytes of the files before it.
        let current = Guarded<(file: ModelPull.File, index: Int, before: Int)?>(nil)
        let report: @Sendable () -> Void = {
            guard let (file, index, before) = current.value else { return }
            let part = ModelPull.incomplete(of: pull.cache.blob(file.blob, of: plan.repository))
            let held = min(max(0, ModelPull.size(of: part)), file.size)
            progress(
                PullProgress(
                    repository: plan.repository, file: file.path, size: file.size, index: index, files: missing.count,
                    fetched: before + held, total: plan.remaining))
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                report()
            }
        }
        defer { ticker.cancel() }
        let fetched: Int
        do {
            fetched = try await pull.fetch(
                plan,
                progress: { file, index in
                    let before = missing.prefix(index - 1).reduce(0) { $0 + $1.size }
                    current.update { $0 = (file, index, before) }
                    report()
                }, notice: notice)
        } catch {
            // A cancelled request surfaces as the transport's failure; the cancellation is what happened.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        return fetched
    }

    /// What the person reads at the end.
    ///
    /// - Parameters:
    ///   - plan: The plan.
    ///   - linked: What the link did.
    /// - Returns: The line.
    static func closing(_ plan: ModelPull.Plan, _ linked: ModelPull.LinkOutcome) -> String {
        let declare =
            "declare what it can do in config.json (mlx.models.\(plan.name).capabilities), only what you have "
            + "verified."
        switch linked {
        case .keptDirectory:
            return "The model is in the Hugging Face cache at \(plan.snapshot.path). \(plan.destination.path) "
                + "stays as it was, so mlx:\(plan.name) still runs that copy; run the pull again and answer yes "
                + "to replace it with a link."
        case .replacedDirectory:
            return "The directory is in the Trash and \(plan.destination.path) links to the snapshot. Use it as "
                + "--model mlx:\(plan.name); \(declare)"
        case .created, .replacedLink, .unchanged:
            return "\(plan.destination.path) links to the snapshot. Use it as --model mlx:\(plan.name); \(declare)"
        }
    }
}

extension ModelPull.Plan {
    /// The plan as `WispCore` sees it: what it would fetch, and the lines that say so.
    public var summary: PullSummary {
        PullSummary(
            repository: repository, name: name, revision: revision, licence: licence, files: files.count, bytes: bytes,
            missing: missing.count, remaining: remaining, destination: destination.path, snapshot: snapshot.path,
            replacesDirectory: link == .directory, reused: reused.count, seeded: seeded.count, lines: lines)
    }

    /// What the pull would do, for the question: each file and whether the cache has it, where the snapshot is, and
    /// what happens at the link's path.
    public var lines: [String] {
        func padded(_ text: String, _ width: Int) -> String {
            text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        let size = PullSummary.size
        let width = files.map(\.path.count).max() ?? 0
        let sizeWidth = files.map { size($0.size).count }.max() ?? 0
        var lines = ["\(repository) at \(revision.prefix(12)): \(files.count) files, \(size(bytes))"]
        for file in files {
            let state =
                reused.contains(file.path)
                ? "already in the Hugging Face cache"
                : seeded.contains(file.path) ? "to copy from \(destination.lastPathComponent)/" : "to fetch"
            lines.append("  \(padded(file.path, width))  \(padded(size(file.size), sizeWidth))  \(state)")
        }
        lines.append("Snapshot: \(snapshot.path)")
        let destination = destination.path
        switch link {
        case .absent: lines.append("Link: \(destination) to the snapshot, as mlx:\(name)")
        case .current: lines.append("Link: \(destination) already points at the snapshot")
        case .stale(let target):
            lines.append("Link: \(destination) points at another snapshot (\(target)); it will point at this one")
        case .directory:
            lines.append(
                "Link: \(destination) is a directory of its own (an earlier copy); it stays unless you agree to "
                    + "replace it")
        }
        if missing.isEmpty {
            lines.append(
                seeded.isEmpty
                    ? "Every file is already in the Hugging Face cache; nothing to fetch."
                    : "Every file is in the Hugging Face cache or \(destination); nothing to fetch.")
        }
        return lines
    }
}

extension PublisherCheck {
    /// Settles the publisher for a plan (`settle(_:screened:ask:)` on its summary).
    ///
    /// - Parameters:
    ///   - plan: What the pull would fetch.
    ///   - screened: What `screen` decided; nil to ask.
    ///   - ask: Shows the question's lines and returns the line typed, nil at end of input.
    /// - Returns: The decision.
    /// - Throws: `ConfigEdit.Failure`, or the file system's error, when the setting cannot be written.
    public func settle(_ plan: ModelPull.Plan, screened: Decision?, ask: ([String]) -> String?) throws -> Decision {
        try settle(plan.summary, screened: screened, ask: ask)
    }

    /// The question for a plan (`question(for:)` on its summary).
    ///
    /// - Parameter plan: What the pull would fetch.
    /// - Returns: The lines.
    public static func question(for plan: ModelPull.Plan) -> [String] {
        question(for: plan.summary)
    }
}

import CoreServices
import Foundation

/// Reports file changes under a set of directories through FSEvents, for `wisp watch`. Changes under
/// build output and version-control directories are ignored, since the watched command writes there
/// itself and would otherwise set itself off forever. FSEvents batches changes over `latency`, so a save
/// that touches several files arrives as one change. Not `Sendable`: the command that starts it owns it
/// for its life, and only the callback's sink crosses threads.
public final class FileWatcher {
    /// Directory names whose contents never count as a change.
    public static let ignoredDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "target", "node_modules", "DerivedData", ".venv", "__pycache__", "dist",
        ".next", ".cache",
    ]

    /// Whether a changed path counts: it has no ignored directory among its components and its file name
    /// is not an editor's scratch file (`~` and `.swp` endings, Emacs's `.#` lock files) or Finder's `.DS_Store`.
    ///
    /// - Parameter path: The changed path, as FSEvents reports it.
    /// - Returns: Whether it should start a run.
    public static func counts(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: ignoredDirectories.contains) { return false }
        let name = components.last ?? ""
        return !(name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasPrefix(".#") || name == ".DS_Store")
    }

    /// What the FSEvents callback reaches: where to send changes.
    private final class Sink: Sendable {
        /// Called once per batch that has a path that counts.
        let onChange: @Sendable () -> Void

        /// Creates a sink.
        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    /// The stream, owned for the watcher's life.
    private let stream: FSEventStreamRef
    /// The sink the stream's context points to; kept alive with the watcher.
    private let sink: Sink

    /// Starts watching; fails (nil) when the stream cannot be created or started.
    ///
    /// - Parameters:
    ///   - paths: Directories to watch, recursively.
    ///   - latency: Seconds FSEvents gathers changes before reporting them.
    ///   - onChange: Called on a private queue once per batch with a path that counts.
    public init?(paths: [String], latency: Double = 0.5, onChange: @escaping @Sendable () -> Void) {
        let sink = Sink(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray of CFStrings.
            let names = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            let changed = (0..<count).contains { index in
                (names[index] as? String).map(FileWatcher.counts) ?? false
            }
            if changed { sink.onChange() }
        }
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "wisp.watch.fsevents"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
        self.sink = sink
    }

    /// Stops the stream and releases it.
    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

import CoreServices
import Foundation
import Synchronization
import WispNotifierKit

/// wisp's side of `Wisp Notifier.app`, the `helper` route ([ADR 0070](../../../../docs/decisions/0070-a-notification-helper.md)):
/// where the bundle is, the person's permission, asking for it, and posting. Each is a closure, so tests answer
/// without a bundle and nothing in them runs one; `live` runs the bundle's executable with `NotifierProtocol`'s
/// command line.
public struct NotifierHelper: Sendable {
    /// The bundle, or nil when there is none beside `wisp`.
    public var locate: @Sendable () -> URL?
    /// The person's permission for the bundle, or nil when the helper could not be run.
    public var permission: @Sendable (URL) -> NotifierProtocol.Permission?
    /// Starts asking the person for permission and returns at once; the answer is read at a later notification. Asks
    /// at most once a process, so a prompt still on screen is not asked for again.
    public var askLater: @Sendable (URL) -> Void
    /// Asks the person and waits for the answer, for `wisp notify --route helper`; nil when the helper could not be run.
    public var askNow: @Sendable (URL) -> NotifierProtocol.Permission?
    /// Posts one notification; nil when posted, else why not.
    public var post: @Sendable (URL, NotifierProtocol.Request) -> String?

    /// Creates a helper from its parts.
    ///
    /// - Parameters:
    ///   - locate: Where the bundle is.
    ///   - permission: Reads the permission.
    ///   - askLater: Starts asking without waiting.
    ///   - askNow: Asks and waits.
    ///   - post: Posts one notification.
    public init(
        locate: @escaping @Sendable () -> URL?,
        permission: @escaping @Sendable (URL) -> NotifierProtocol.Permission? = { _ in nil },
        askLater: @escaping @Sendable (URL) -> Void = { _ in },
        askNow: @escaping @Sendable (URL) -> NotifierProtocol.Permission? = { _ in nil },
        post: @escaping @Sendable (URL, NotifierProtocol.Request) -> String? = { _, _ in "no helper" }
    ) {
        self.locate = locate
        self.permission = permission
        self.askLater = askLater
        self.askNow = askNow
        self.post = post
    }

    /// No helper: the route is skipped as missing.
    public static let none = NotifierHelper(locate: { nil })

    /// The bundle beside the running `wisp`, run for real, registered with LaunchServices first.
    public static let live = running(
        locate: { ExecutablePath.current.flatMap { bundle(besides: $0) } },
        register: { app in _ = LSRegisterURL(app as CFURL, true) })

    /// A helper that runs the bundle's executable; `register` is told each bundle once a process before it is run.
    ///
    /// - Parameters:
    ///   - locate: Where the bundle is.
    ///   - register: Registers a bundle with LaunchServices; tests pass one that does nothing.
    /// - Returns: The helper.
    static func running(
        locate: @escaping @Sendable () -> URL?, register: @escaping @Sendable (URL) -> Void
    ) -> NotifierHelper {
        let state = LiveState(register: register)
        return NotifierHelper(
            locate: locate,
            permission: { app in state.run(app, .status, timeout: 5).flatMap(Self.permission(from:)) },
            askLater: { app in state.askOnce(app) },
            askNow: { app in state.run(app, .ask, timeout: 120).flatMap(Self.permission(from:)) },
            post: { app, request in
                guard let result = state.run(app, .post(request), timeout: 5) else {
                    return "Wisp Notifier.app could not be run"
                }
                switch result.status {
                case NotifierProtocol.Exit.done.rawValue: return nil
                case NotifierProtocol.Exit.notAllowed.rawValue:
                    return "notifications for Wisp are \(result.output.isEmpty ? "not allowed" : result.output)"
                default: return "Wisp Notifier.app exited with status \(result.status)"
                }
            })
    }

    /// The bundle beside `executable`, when it holds the helper's executable.
    ///
    /// - Parameters:
    ///   - executable: The running `wisp`, links resolved.
    ///   - exists: Whether a path is an executable file.
    /// - Returns: The bundle, or nil.
    static func bundle(
        besides executable: URL, exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let app = executable.deletingLastPathComponent().appending(path: NotifierProtocol.bundleName)
        return exists(Self.executable(in: app).path) ? app : nil
    }

    /// The helper's executable inside `app`.
    static func executable(in app: URL) -> URL {
        app.appending(path: "Contents/MacOS").appending(path: NotifierProtocol.executableName)
    }

    /// The permission a run printed, or nil when it printed none.
    private static func permission(from result: (status: Int32, output: String)) -> NotifierProtocol.Permission? {
        NotifierProtocol.Permission(rawValue: result.output) ?? (result.output.isEmpty ? nil : .unknown)
    }

    /// What the live helper keeps for the process: the bundles registered with LaunchServices, and whether it has
    /// asked.
    private final class LiveState: Sendable {
        /// Registers a bundle with LaunchServices.
        private let registrar: @Sendable (URL) -> Void
        /// The bundles registered this process.
        private let registered = Mutex<Set<String>>([])
        /// Whether `askOnce` has started a request.
        private let asked = Mutex(false)

        /// Creates the state.
        ///
        /// - Parameter register: Registers a bundle with LaunchServices.
        init(register: @escaping @Sendable (URL) -> Void) {
            registrar = register
        }

        /// Registers `app` with LaunchServices, once a process: macOS refuses a bundle it does not know, with no
        /// prompt, when its executable is run directly (ADR 0070).
        private func register(_ app: URL) {
            let first = registered.withLock { $0.insert(app.path).inserted }
            if first { registrar(app) }
        }

        /// Runs the helper with `command` and waits up to `timeout` seconds.
        ///
        /// - Returns: Its exit status and what it printed, trimmed; nil when it could not start or outlived the limit.
        func run(
            _ app: URL, _ command: NotifierProtocol.Command, timeout: TimeInterval
        ) -> (
            status: Int32, output: String
        )? {
            register(app)
            let process = Process()
            process.executableURL = NotifierHelper.executable(in: app)
            process.arguments = NotifierProtocol.arguments(command)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning {
                process.terminate()
                return nil
            }
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, printed.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Starts `--ask` without waiting, once a process.
        func askOnce(_ app: URL) {
            let first = asked.withLock { asked in
                defer { asked = true }
                return !asked
            }
            guard first else { return }
            register(app)
            let process = Process()
            process.executableURL = NotifierHelper.executable(in: app)
            process.arguments = NotifierProtocol.arguments(.ask)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}

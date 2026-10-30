import Foundation

/// The per-user wisp directory: `$WISP_HOME`, or `~/.wisp` by default; and wisp's folder in Application Support
/// beside it (`support`).
///
/// Holds `config.json`, `logs/`, and `threads/`, among others. Nothing is created until `ensure()` is called, so
/// read-only commands never touch the file system.
public struct Home: Sendable, Equatable {
    /// Environment variable that overrides the default location.
    public static let environmentKey = "WISP_HOME"

    /// The directory itself.
    public let root: URL
    /// wisp's folder in Application Support, for what other agents should not reach (ADR 0082, decision 2): the
    /// models wisp's own llama.cpp server serves. `~/Library/Application Support/Wisp` for the person's home; for a
    /// home given its root, `$WISP_HOME` or a test's, `<root>/support`, so a scratch home never reads or changes the
    /// person's own.
    public let support: URL

    /// Creates a home rooted at `root`.
    ///
    /// - Parameters:
    ///   - root: The directory.
    ///   - support: wisp's folder in Application Support; nil puts it at `<root>/support`.
    public init(root: URL, support: URL? = nil) {
        self.root = root
        self.support = support ?? root.appending(path: "support", directoryHint: .isDirectory)
    }

    /// Resolves the home from `environment`, falling back to `~/.wisp` and `~/Library/Application Support/Wisp`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Home {
        if let override = environment[environmentKey], !override.isEmpty {
            return Home(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return Home(
            root: FileManager.default.homeDirectoryForCurrentUser.appending(
                path: ".wisp", directoryHint: .isDirectory),
            support: URL.applicationSupportDirectory.appending(path: "Wisp", directoryHint: .isDirectory))
    }

    /// The JSON configuration file.
    public var configFile: URL { root.appending(path: "config.json") }
    /// Where log files go.
    public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    /// The audit log (JSON Lines).
    public var auditFile: URL { logs.appending(path: "audit.jsonl") }
    /// Standing command approvals.
    public var approvalsFile: URL { root.appending(path: "approvals.json") }
    /// The shared store of permanent facts, which only the person admits facts to.
    public var factsFile: URL { root.appending(path: "facts.json") }
    /// Commands waiting for approval under `wisp mcp`, answered from another face (`PendingApprovals`).
    public var pending: URL { root.appending(path: "pending", directoryHint: .isDirectory) }
    /// Model assets kept under the home, one subdirectory per backend.
    public var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }

    /// Where chats were saved before 0.27.0: read by `wisp chat --resume` and listed by `/threads`, never written
    /// (ADR 0066).
    public var transcripts: URL { root.appending(path: "transcripts", directoryHint: .isDirectory) }
    /// Where the exact context a model saw is saved: by `/inspect context`, and before and after each condensation.
    public var contexts: URL { root.appending(path: "context", directoryHint: .isDirectory) }
    /// Where tool output larger than the tool-output budget is kept whole, one directory per audit session
    /// (`OutputStore`, ADR 0050).
    public var outputs: URL { root.appending(path: "output", directoryHint: .isDirectory) }
    /// Where every thread is saved as it goes, one directory per thread (`ThreadStore`, ADR 0066).
    public var threads: URL { root.appending(path: "threads", directoryHint: .isDirectory) }

    /// Creates the directory tree if it does not exist.
    ///
    /// - Throws: File-system errors from `FileManager`.
    public func ensure() throws {
        for directory in [root, logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

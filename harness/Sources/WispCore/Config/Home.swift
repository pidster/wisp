import Foundation

/// The per-user wisp directory: `$WISP_HOME`, or `~/.wisp` by default.
///
/// Holds `config.json`, `logs/`, and `transcripts/`. Nothing is created until
/// `ensure()` is called, so read-only commands never touch the file system.
public struct Home: Sendable, Equatable {
    /// Environment variable that overrides the default location.
    public static let environmentKey = "WISP_HOME"

    /// The directory itself.
    public let root: URL

    /// Creates a home rooted at `root`.
    public init(root: URL) {
        self.root = root
    }

    /// Resolves the home from `environment`, falling back to `~/.wisp`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Home {
        if let override = environment[environmentKey], !override.isEmpty {
            return Home(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return Home(
            root: FileManager.default.homeDirectoryForCurrentUser.appending(
                path: ".wisp", directoryHint: .isDirectory))
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

    /// Where saved conversation transcripts go.
    public var transcripts: URL { root.appending(path: "transcripts", directoryHint: .isDirectory) }
    /// Where the exact context a model saw is saved: by `/inspect context`, and before and after each condensation.
    public var contexts: URL { root.appending(path: "context", directoryHint: .isDirectory) }

    /// Creates the directory tree if it does not exist.
    ///
    /// - Throws: File-system errors from `FileManager`.
    public func ensure() throws {
        for directory in [root, logs, transcripts] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

import Foundation

/// Whose server `llamacpp:<name>` models are served by: `llamacpp.server` in `config.json`
/// ([ADR 0082](../../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 3). llama.cpp only; LM
/// Studio runs its own server.
public enum LlamaCppServer: String, Codable, CaseIterable, Sendable {
    /// A server the person starts: wisp connects to `llamacpp.baseURL` and starts nothing. The default, and wisp's
    /// behaviour before 0.33.0.
    case off
    /// wisp's own router, which wisp starts for the models it knows. Not built yet: every use says so
    /// (`unusable`) until it arrives in a later stage of 0.33.0.
    case wisp
    /// Llama.app's router: wisp connects to it and starts nothing; the person adds models in Llama.app.
    case llamaApp = "llama-app"

    /// The port Llama.app's router listens on: llama-server's own default, which Llama.app 0.46.1 passes as
    /// `--port 9931` and writes nowhere wisp could find (not its defaults, `models.ini`, or `models.user.ini`; probed
    /// on 2026-10-29).
    static let llamaAppPort = 9931

    /// What each value does, in plain words, for `wisp config` and `wisp doctor`.
    public var effect: String {
        switch self {
        case .off: "wisp connects to llamacpp.baseURL, a server you start, and starts nothing"
        case .wisp: "wisp starts its own llama.cpp server for the models it knows (not built yet)"
        case .llamaApp:
            "wisp uses Llama.app's server (port \(Self.llamaAppPort) unless llamacpp.baseURL is set) and starts "
                + "nothing; add models in Llama.app"
        }
    }

    /// The base URL this choice puts in place of llama.cpp's default when `llamacpp.baseURL` is unset: Llama.app's
    /// port for `llama-app`; nil for the others, which keep `http://127.0.0.1:8080`.
    var defaultBaseURL: URL? {
        guard self == .llamaApp else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Self.llamaAppPort
        return components.url
    }

    /// Why wisp will not ask this server anything, or nil when it may: `wisp`'s server is not built yet. The one
    /// place a later stage of 0.33.0 replaces with starting the server, or saying why it would not.
    var unusable: String? {
        guard self == .wisp else { return nil }
        return Self.notBuilt
    }

    /// What `wisp`'s server being missing means for the person.
    static let notBuilt =
        "llamacpp.server is wisp, wisp's own llama.cpp server, which arrives in a later stage of 0.33.0 and is not "
        + "built yet; set llamacpp.server to off (a llama-server you start) or llama-app (Llama.app's server)"
}

/// Llama.app (`app.llama.Llama`), found where it is installed, so `llamacpp.server llama-app` can say whether it is.
public struct LlamaApp: Equatable, Sendable {
    /// Llama.app's bundle identifier.
    public static let bundleIdentifier = "app.llama.Llama"

    /// The bundles looked at, in order.
    public var candidates: [URL]

    /// Creates a finder that looks at `candidates`.
    public init(candidates: [URL]) {
        self.candidates = candidates
    }

    /// `/Applications/Llama.app`, then `~/Applications/Llama.app`.
    public static let standard = LlamaApp(candidates: [
        URL(filePath: "/Applications/Llama.app"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Llama.app"),
    ])

    /// The installed bundle: the first candidate whose `Info.plist` names Llama.app's bundle identifier; nil when
    /// none does.
    public var installed: URL? {
        candidates.first { bundle in
            guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return plist["CFBundleIdentifier"] as? String == Self.bundleIdentifier
        }
    }

    /// The candidates' folders, for saying where wisp looked: `/Applications, ~/Applications`.
    var looked: String {
        candidates.map { $0.deletingLastPathComponent().path }.joined(separator: ", ")
    }

    /// What to do when Llama.app's server does not answer: start it, or install it.
    var startHint: String {
        installed == nil
            ? "Llama.app is not installed (looked in \(looked)); install it, or set llamacpp.server off and start "
                + "llama-server yourself"
            : "start Llama.app, whose server wisp uses under llamacpp.server llama-app; or set llamacpp.server off"
    }
}

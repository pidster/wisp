import Foundation

extension Doctor {
    /// What a llama.cpp server answered when asked for its models: how many it lists, or why it did not answer.
    enum ServerAnswer: Equatable, Sendable {
        /// It listed this many models.
        case listed(Int)
        /// A router listed these models, each with what it says of it (`loaded`, `unloaded`, …).
        case routed([RoutedModel])
        /// It did not answer, or not with a listing, for this reason.
        case failed(String)
    }

    /// One model a router lists, and its status.
    struct RoutedModel: Equatable, Sendable {
        /// The model's name.
        var name: String
        /// What the router says of it; nil when it says nothing.
        var status: String?
    }

    /// The state of wisp's own llama.cpp server, for the `llama.cpp server` finding under `llamacpp.server wisp`.
    struct RouterState: Equatable, Sendable {
        /// The approved binary's check.
        var binary: Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal>
        /// The LaunchAgent's state.
        var agent: LlamaCppAgent.State
        /// How this wisp registers it.
        var means: LlamaCppAgent.Means
        /// Whether the key file holds a key.
        var keyExists: Bool
        /// The server's log.
        var log: URL
    }

    /// The `llama.cpp server` finding for `llamacpp.server` (ADR 0082), or nil under `off`, which starts nothing and
    /// is checked, as before, by the configured model's finding.
    ///
    /// - `wisp` gives the approved `llama-server`'s state, the LaunchAgent's, whether the server answers with wisp's
    ///   key and the models it lists with their status, its settings, and its log; it passes when the binary is
    ///   approved, the agent registered (by this install or another, such as `Wisp.app`'s Login Item seen from a
    ///   Homebrew `wisp`, or none is, by choice), and the server answers, and otherwise says why and
    ///   what to do (`LlamaCppRouter.diagnosis`).
    /// - `llama-app` says whether Llama.app is installed and whether its server answers, and warns that the server
    ///   has no key and answers any origin; it fails only when Llama.app is not installed and nothing answers.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings.
    ///   - installed: Where Llama.app is installed, or nil.
    ///   - answer: What the server at `settings.baseURL` answered; nil when it was not asked.
    ///   - router: Under `wisp`, the state of wisp's own server; nil when not read.
    /// - Returns: The finding, or nil.
    static func llamaCppServer(
        _ settings: OpenAICompatibleSettings, installed: URL?, answer: ServerAnswer?, router: RouterState? = nil
    ) -> Finding? {
        let name = "llama.cpp server"
        switch settings.server {
        case .off:
            return nil
        case .wisp:
            return wispServer(settings, answer: answer, router: router)
        case .llamaApp:
            let app =
                installed.map { "Llama.app at \($0.path)" }
                ?? "Llama.app not installed (looked in \(settings.llamaApp.looked))"
            let url = settings.baseURL.absoluteString
            let server =
                switch answer {
                case .listed(let count): "its server at \(url) answers, listing \(count) model\(count == 1 ? "" : "s")"
                case .routed(let models):
                    "its server at \(url) answers, listing \(models.count) model\(models.count == 1 ? "" : "s")"
                case .failed(let reason): "nothing answers at \(url) (\(reason)); \(settings.llamaApp.startHint)"
                case nil: "its server at \(url) was not asked"
                }
            let answered = if case .listed = answer { true } else { false }
            return Finding(
                name: name, ok: installed != nil || answered,
                detail: "llamacpp.server llama-app: \(app); \(server); warning: Llama.app's server has no API key and "
                    + "answers any origin, so any process on this Mac and any web page you open can use its models")
        }
    }

    /// The finding under `llamacpp.server wisp`.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings.
    ///   - answer: What wisp's server answered; nil when it was not asked.
    ///   - router: Its state; nil when not read.
    /// - Returns: The finding.
    static func wispServer(_ settings: OpenAICompatibleSettings, answer: ServerAnswer?, router: RouterState?) -> Finding
    {
        let name = "llama.cpp server"
        let url = settings.baseURL.absoluteString
        guard let router else {
            return Finding(name: name, ok: false, detail: "llamacpp.server wisp: its state was not read")
        }
        let binary =
            switch router.binary {
            case .success(let approved):
                "llama-server \(approved.approval.path) approved and unchanged (\(approved.executable.path), sha256 "
                    + "\(LlamaCppServerBinary.short(approved.sha256)))"
            case .failure(let refusal): "llama-server: \(refusal)"
            }
        let agent = "LaunchAgent: \(router.agent.text)"
        let served: String
        var answered = false
        switch answer {
        case .routed(let models):
            answered = true
            let list = models.map { "\($0.name) (\($0.status ?? "status not said"))" }.joined(separator: ", ")
            served =
                "it answers at \(url) with wisp's key, serving "
                + (models.isEmpty ? "no models (wisp models add PATH adds one)" : list)
        case .listed(let count):
            answered = true
            served = "it answers at \(url) with wisp's key, listing \(count) model\(count == 1 ? "" : "s")"
        case .failed(let reason):
            served = LlamaCppRouter.diagnosis(
                binary: router.binary, agent: router.agent, keyExists: router.keyExists, settings: settings.router,
                log: router.log, detail: reason)
        case nil:
            served = "it was not asked"
        }
        let registered: Bool =
            switch router.agent {
            case .registered, .registeredElsewhere, .manual: true
            default: false
            }
        let binaryOK = if case .success = router.binary { true } else { false }
        return Finding(
            name: name, ok: binaryOK && registered && answered,
            detail: "llamacpp.server wisp: \(binary); \(agent); \(served); settings: \(settings.router.summary); "
                + "log: \(router.log.path)")
    }

    /// Asks wisp's own server for its models with wisp's key, and reads its state, for the `llama.cpp server` finding;
    /// nil for each under another server. Asks the LaunchAgent's control, which for a home other than the person's
    /// registers nothing and asks launchd nothing.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings, with wisp's key (`Session.loadConfig(home:)`).
    ///   - home: wisp's home.
    ///   - agent: The LaunchAgent's control.
    /// - Returns: What it answered, and its state.
    static func askWispServer(
        _ settings: OpenAICompatibleSettings, home: Home, agent: any LlamaCppAgentControl
    ) async -> (answer: ServerAnswer?, router: RouterState?) {
        guard settings.server == .wisp else { return (nil, nil) }
        let router = RouterState(
            binary: serverBinary(settings, home: home) ?? .failure(.notSet), agent: agent.state(), means: agent.means,
            keyExists: LlamaCppRouter.KeyFile(home: home).read() != nil, log: LlamaCppRouter.log(home: home))
        do {
            let served = try await OpenAICompatibleModel.served(by: .llamaCpp, at: settings)
            return (.routed(served.map { RoutedModel(name: $0.name, status: $0.status) }), router)
        } catch let failure as OpenAICompatibleModel.Failure {
            switch failure {
            case .unreachable(_, _, let detail, _): return (.failed(detail), router)
            case .unusable: return (.failed("no key yet"), router)
            default: return (.failed(failure.description), router)
            }
        } catch {
            return (.failed("\(error)"), router)
        }
    }

    /// Asks the server at `settings` for its models (`/v1/models`, within the five seconds every listing waits), for the `llama.cpp server` finding; nil
    /// when `llamacpp.server` is not `llama-app`, so nothing is asked.
    ///
    /// - Parameter settings: The `llamacpp` settings.
    /// - Returns: What it answered, or nil.
    static func askLlamaCppServer(_ settings: OpenAICompatibleSettings) async -> ServerAnswer? {
        guard settings.server == .llamaApp else { return nil }
        do {
            return .listed(try await OpenAICompatibleModel.served(by: .llamaCpp, at: settings).count)
        } catch let failure as OpenAICompatibleModel.Failure {
            if case .unreachable(_, _, let detail, _) = failure { return .failed(detail) }
            return .failed(failure.description)
        } catch {
            return .failed("\(error)")
        }
    }

    /// The state of the `llama-server` wisp's own server would run, for the `llama.cpp server` finding: checked only
    /// under `llamacpp.server wisp`, and nothing recorded.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings.
    ///   - home: Where the approval is recorded.
    /// - Returns: The check's result, or nil under another server.
    static func serverBinary(
        _ settings: OpenAICompatibleSettings, home: Home
    ) -> Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal>? {
        guard settings.server == .wisp else { return nil }
        do {
            return .success(try LlamaCppServerBinary(home: home).check(settings.serverPath))
        } catch let refusal as LlamaCppServerBinary.Refusal {
            return .failure(refusal)
        } catch {
            return .failure(.notApproved(path: settings.serverPath ?? "", reason: "\(error)"))
        }
    }
}

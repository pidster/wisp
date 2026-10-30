import Foundation

extension Doctor {
    /// What a llama.cpp server answered when asked for its models: how many it lists, or why it did not answer.
    enum ServerAnswer: Equatable, Sendable {
        /// It listed this many models.
        case listed(Int)
        /// It did not answer, or not with a listing, for this reason.
        case failed(String)
    }

    /// The `llama.cpp server` finding for `llamacpp.server` (ADR 0082), or nil under `off`, which starts nothing and
    /// is checked, as before, by the configured model's finding.
    ///
    /// - `wisp` fails, saying wisp's own server is not built yet, and gives the state of the `llama-server` it would
    ///   run: approved and unchanged, or why it would not be started, with the command that approves it.
    /// - `llama-app` says whether Llama.app is installed and whether its server answers, and warns that the server
    ///   has no key and answers any origin; it fails only when Llama.app is not installed and nothing answers.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings.
    ///   - installed: Where Llama.app is installed, or nil.
    ///   - answer: What the server at `settings.baseURL` answered; nil when it was not asked.
    ///   - binary: Under `wisp`, the check of `llamacpp.serverPath` against its approval; nil when not checked.
    /// - Returns: The finding, or nil.
    static func llamaCppServer(
        _ settings: OpenAICompatibleSettings, installed: URL?, answer: ServerAnswer?,
        binary: Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal>? = nil
    ) -> Finding? {
        let name = "llama.cpp server"
        switch settings.server {
        case .off:
            return nil
        case .wisp:
            let state =
                switch binary {
                case .success(let approved):
                    "; llama-server: \(approved.approval.path) approved and unchanged (\(approved.executable.path), "
                        + "sha256 \(LlamaCppServerBinary.short(approved.sha256)))"
                case .failure(let refusal): "; llama-server: \(refusal)"
                case nil: ""
                }
            return Finding(name: name, ok: false, detail: LlamaCppServer.notBuilt + state)
        case .llamaApp:
            let app =
                installed.map { "Llama.app at \($0.path)" }
                ?? "Llama.app not installed (looked in \(settings.llamaApp.looked))"
            let url = settings.baseURL.absoluteString
            let server =
                switch answer {
                case .listed(let count): "its server at \(url) answers, listing \(count) model\(count == 1 ? "" : "s")"
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

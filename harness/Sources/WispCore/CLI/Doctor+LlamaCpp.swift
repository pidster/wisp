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
    /// - `wisp` fails, saying wisp's own server is not built yet.
    /// - `llama-app` says whether Llama.app is installed and whether its server answers, and warns that the server
    ///   has no key and answers any origin; it fails only when Llama.app is not installed and nothing answers.
    ///
    /// - Parameters:
    ///   - settings: The `llamacpp` settings.
    ///   - installed: Where Llama.app is installed, or nil.
    ///   - answer: What the server at `settings.baseURL` answered; nil when it was not asked.
    /// - Returns: The finding, or nil.
    static func llamaCppServer(
        _ settings: OpenAICompatibleSettings, installed: URL?, answer: ServerAnswer?
    ) -> Finding? {
        let name = "llama.cpp server"
        switch settings.server {
        case .off:
            return nil
        case .wisp:
            return Finding(name: name, ok: false, detail: LlamaCppServer.notBuilt)
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
}

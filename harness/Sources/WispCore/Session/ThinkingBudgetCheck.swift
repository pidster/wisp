import Foundation
import Synchronization

/// Whether llama.cpp holds a level's thinking to its budget (ADR 0053, amended 2026-10-17). The budget is sent as
/// `thinking_budget_tokens`, which llama.cpp 0.7.0 takes per request though its README documents only the server's
/// `--reasoning-budget`; a later build that dropped the field would let every level think without a limit and say
/// nothing. So a reply that thinks past its budget is logged, once per model and server in a process, and
/// `wisp doctor` asks the server to keep to a small budget and says whether it did.
enum ThinkingBudgetCheck {
    /// Whether `thinking` tokens ran past `budget`: by more than the end of the block the server writes when the
    /// budget is spent, allowed as 16 tokens or a twentieth of the budget, whichever is more (a budget of 256 thought
    /// 261, and one of 64 exactly 64, on 2026-10-17).
    ///
    /// - Parameters:
    ///   - thinking: Tokens of thinking the reply used.
    ///   - budget: The budget sent; 0 or less is no limit, which nothing runs past.
    /// - Returns: Whether it ran past.
    static func overran(thinking: Int, budget: Int) -> Bool {
        budget > 0 && thinking > budget + max(16, budget / 20)
    }

    /// The models and servers whose overrun has been logged in this process, so a turn after turn of it says so
    /// once.
    static let logged = Logged()

    /// The set of what has been logged.
    final class Logged: Sendable {
        /// `<base URL> <model>` keys.
        let keys = Mutex<Set<String>>([])

        /// Whether `key` is new, recording it.
        ///
        /// - Parameter key: The model and server.
        /// - Returns: True the first time.
        func first(_ key: String) -> Bool { keys.withLock { $0.insert(key).inserted } }
    }

    /// Logs a reply that thought past its level's budget, the first time for this model and server.
    ///
    /// - Parameters:
    ///   - model: The model.
    ///   - level: The level asked.
    ///   - budget: Its budget.
    ///   - thinking: Tokens of thinking used.
    static func note(_ model: OpenAICompatibleModel, level: String, budget: Int, thinking: Int) {
        guard overran(thinking: thinking, budget: budget),
            logged.first("\(model.settings.baseURL.absoluteString) \(model.name)")
        else { return }
        Diagnostics.agent.error(
            "\(model.dialect.runtime) thought \(thinking) tokens at think \(level), past its budget of \(budget): "
                + "this server may not take thinking_budget_tokens, so levels think without a limit; "
                + "wisp doctor checks it (docs/backends.md, \"llama.cpp\")")
    }

    /// The budget `probe` asks for: small, so a server that ignores it is plain at once.
    static let probeBudget = 32

    /// Asks llama.cpp at `settings` to think within `probeBudget` tokens and says whether it did: nil when no
    /// server answers, or its model's template does not think, since there is then nothing to check. The question
    /// is a risk verdict that thinks for some 3,000 tokens unbounded on a Qwen3.5 model; the reply is cut at 400.
    ///
    /// - Parameter settings: The `llamacpp` settings.
    /// - Returns: The finding, or nil.
    static func probe(_ settings: OpenAICompatibleSettings) async -> Doctor.Finding? {
        let quick = OpenAICompatibleSettings(
            baseURL: settings.baseURL, timeout: .seconds(2), apiKey: settings.apiKey,
            apiKeySource: settings.apiKeySource)
        guard let propsData = try? await OpenAICompatibleModel.get("props", dialect: .llamaCpp, settings: quick),
            let props = try? JSONDecoder().decode(JSONValue.self, from: propsData),
            OpenAICompatibleModel.Props(props).thinks
        else { return nil }
        let build = props.objectValue?["build_info"]?.stringValue.map { " (build \($0))" } ?? ""
        let name = "llama.cpp thinking budget"
        var request = OpenAICompatibleModel.request("v1/chat/completions", settings: settings, timeout: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "messages": [
                [
                    "role": "system",
                    "content": "Rate the shell command's risk in one word: safe, moderate, or dangerous.",
                ],
                ["role": "user", "content": "git push --force origin main"],
            ],
            "temperature": 0, "max_tokens": 400, "chat_template_kwargs": ["enable_thinking": true],
            "thinking_budget_tokens": .int(probeBudget),
        ]
        request.httpBody = try? JSONEncoder().encode(body)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let reply = try? JSONDecoder().decode(JSONValue.self, from: data),
            let used = thinking(in: reply)
        else {
            return Doctor.Finding(
                name: name, ok: false, detail: "llama.cpp\(build) did not answer a request asking for a budget")
        }
        guard overran(thinking: used, budget: probeBudget) else {
            return Doctor.Finding(
                name: name, ok: true,
                detail: "llama.cpp\(build) keeps to a thinking budget: \(probeBudget) tokens asked, \(used) used")
        }
        return Doctor.Finding(
            name: name, ok: false,
            detail:
                "llama.cpp\(build) thought \(used) tokens past a budget of \(probeBudget), so think levels have no "
                + "limit on it: start llama-server with --reasoning-budget, or use true or false")
    }

    /// The tokens a reply thought: the server's `reasoning_tokens`, else its whole output, which is the thinking
    /// and a one-word reply; nil when it reports no usage.
    ///
    /// - Parameter reply: The reply's body.
    /// - Returns: The tokens, or nil.
    static func thinking(in reply: JSONValue) -> Int? {
        let usage = reply.objectValue?["usage"]?.objectValue
        return usage?["completion_tokens_details"]?.objectValue?["reasoning_tokens"]?.intValue
            ?? usage?["completion_tokens"]?.intValue
    }
}

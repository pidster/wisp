import Foundation

/// `/think`: whether the conversation's model thinks, chosen by the person at the prompt
/// ([ADR 0053](../../../../docs/decisions/0053-the-models-thinking-shown.md), amended 2026-10-15). The choice is saved
/// as the model's default, `<runtime>.models.<name>.think`, as `/config set` saves it, and applied to the conversation
/// at once, as an MCP caller's `think` is, since the saved default is read only as a session starts.
extension ChatLoop {
    /// Handles `/think`, with what followed it: `on`, `off`, or a level; nil shows the model's thinking and, in a face
    /// with a chooser of its own, offers the choices.
    ///
    /// - Parameter argument: What followed the command, trimmed; nil when nothing did.
    mutating func think(_ argument: String?) async {
        let model = agent.model
        guard let path = Self.thinkSetting(for: model) else {
            io.note("\(model.selection) has no thinking to turn on or off")
            return
        }
        guard let argument else {
            let shown = Self.thinkingShown(model, chosen: agent.thinking) ?? "default"
            io.print("thinking: \(shown) (\(path))")
            guard let choose = io.choose else { return }
            let options = (["on", "off"] + model.thinkLevels).map { ChatChoice.Option(value: $0) }
            let answer = await choose(
                ChatChoice(title: "Thinking for \(model.selection)?", options: options, current: shown))
            guard let answer, answer != shown else {
                io.note(style.muted("thinking unchanged"))
                return
            }
            await think(answer)
            return
        }
        if let refusal = agentsThreadRefusal("thinking") {
            io.note(refusal)
            return
        }
        guard let chosen = Self.thinkChoice(argument) else {
            io.note("usage: /think on|off|LEVEL (levels: \(model.thinkLevels.joined(separator: ", ")))")
            return
        }
        do {
            try model.checkThink(chosen)
        } catch {
            io.note(style.ember("error: \(error)"))
            return
        }
        let saved = change(path, effect: "and used in this conversation from now on") {
            try ConfigEdit.set(path, to: chosen.text, in: $0)
        }
        guard saved else { return }
        thinkChoices[model.selection.description] = chosen
        agent.thinking = chosen
    }

    /// The setting that holds `model`'s thinking, `<runtime>.models.<name>.think`; nil for a model that cannot think,
    /// or whose runtime has no such setting (Apple's models, LM Studio's, which set it in the app).
    ///
    /// - Parameter model: The model in use.
    /// - Returns: The setting's path, or nil.
    static func thinkSetting(for model: ResolvedModel) -> String? {
        guard model.thinkSent(.on) != nil, case .local(let backend, let name) = model.selection else { return nil }
        let path = "\(backend).models.\(name).think"
        return ConfigSettings.setting(path) == nil ? nil : path
    }

    /// The choice a `/think` argument names: `on` or `true`, `off` or `false`, or a level; nil for anything else.
    ///
    /// - Parameter text: The argument as typed.
    /// - Returns: The choice, or nil.
    static func thinkChoice(_ text: String) -> OllamaThink? {
        switch text.lowercased() {
        case "on": .on
        case "off": .off
        default: OllamaThink(text)
        }
    }

    /// The status line's word for `model`'s thinking: `on`, `off`, or the level its requests send, with `chosen` asked
    /// of them, or `default` when they send nothing and the runtime decides; nil for a model with no thinking to set.
    ///
    /// - Parameters:
    ///   - model: The model in use.
    ///   - chosen: The conversation's choice (`Agent.thinking`); nil asks nothing.
    /// - Returns: The word, or nil.
    static func thinkingShown(_ model: ResolvedModel, chosen: OllamaThink?) -> String? {
        guard thinkSetting(for: model) != nil else { return nil }
        switch model.thinkSent(chosen) {
        case .on: return "on"
        case .off: return "off"
        case .level(let level): return level
        case nil: return "default"
        }
    }
}

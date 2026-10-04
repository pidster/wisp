import Foundation

extension ChatLoop {
    /// `/models` ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md)): the listing as a
    /// table; in a face with choices, as a picker whose rows the person turns on and off and saves together; or,
    /// with `enable` or `disable`, those models turned on or off.
    ///
    /// - Parameter request: What followed `/models`.
    func models(_ request: ModelsRequest) async {
        switch request {
        case .enable(let names): setModels(enable: names, disable: [])
        case .disable(let names): setModels(enable: [], disable: names)
        case .unknown(let word):
            io.note("unknown /models argument '\(word)'; /models, or /models enable|disable NAME…")
        case .list:
            guard let models = context.models else {
                io.note("models are not listed here")
                return
            }
            let listing = await models(agent.tools)
            let current = agent.model.selection
            guard let choose = io.choose, context.setModels != nil, !listing.shown(all: false).isEmpty else {
                let lines =
                    context.width().map { ModelTable.terminal(listing, current: current, all: false, width: $0) }
                    ?? ModelTable.text(listing, current: current)
                for line in lines { io.print(line) }
                return
            }
            let choice = ModelTable.choice(listing, current: current)
            guard let values = ChatChoice.values(answer: await choose(choice)) else {
                io.note(style.muted("models unchanged"))
                return
            }
            let on = Set(values)
            let enable = choice.options.filter { on.contains($0.value) && $0.on == false }.map(\.value)
            let disable = choice.options.filter { !on.contains($0.value) && $0.on == true }.map(\.value)
            guard !enable.isEmpty || !disable.isEmpty else {
                io.note(style.muted("models unchanged"))
                return
            }
            setModels(enable: enable, disable: disable)
        }
    }

    /// Turns models on and off through the context, noting what happened or why nothing did.
    ///
    /// - Parameters:
    ///   - enable: The models to turn on.
    ///   - disable: The models to turn off.
    private func setModels(enable: [String], disable: [String]) {
        guard let setModels = context.setModels else {
            io.note("models cannot be enabled or disabled here")
            return
        }
        do {
            for line in try setModels(enable, disable) { io.note(line) }
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }
}

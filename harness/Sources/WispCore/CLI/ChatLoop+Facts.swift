extension ChatLoop {
    /// Records the directory chat started in and its git branch as facts, without a model (decision D2 of the
    /// layered-context proposal: the working directory and the branch are versioned dynamic facts).
    func observeWorkplace() {
        agent.observe(
            directory: context.directory, branch: context.git(context.directory).branch, observer: "chat")
    }

    /// Carries out `/fact`: states a fact as the person, moves one to a scope, or deletes one,
    /// and says what happened.
    ///
    /// - Parameter request: What was asked.
    func fact(_ request: FactRequest) {
        do {
            switch request {
            case .usage, .delete(nil):
                io.note(FactRequest.usageText)
            case .state(let subject, let name, let value):
                let fact = try agent.stateFact(subject: subject, name: name, value: value)
                io.note(
                    "stated \(fact.id): \(fact.identity.subject)\(fact.identity.name.isEmpty ? "" : " \(fact.identity.name)")"
                        + " = \(fact.value)"
                        + (fact.identity.scope == .permanent ? " (kept in ~/.wisp/facts.json)" : ""))
            case .delete(let id?):
                let fact = try agent.deleteFact(id)
                io.note("deleted \(fact.id): \(fact.identity.subject) \(fact.identity.name)")
            case .move(let id, let target):
                let fact = try agent.setFactScope(id, to: target)
                io.note(
                    "moved \(id) to \(target.rawValue)" + (fact.id == id ? "" : " as \(fact.id)")
                        + (target == .permanent ? " (kept in ~/.wisp/facts.json for every conversation)" : ""))
            }
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }
}

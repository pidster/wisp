import Foundation

extension Agent {
    /// Applies a change the person or an MCP caller made to the conversation's plan, between turns
    /// ([ADR 0079](../../../../docs/decisions/0079-the-conversation-as-a-spine-with-task-trees.md), decision 22): to the
    /// live plan the `plan` tool shares when the conversation has it, else to the record's, and into the record either
    /// way, so the thread saves it; audited with who made it. The next turn tells the model of it.
    ///
    /// - Parameters:
    ///   - edit: The change.
    ///   - by: Who made it.
    ///   - queued: The id of the queued change this is, when it waited in the `PlanQueue`, for the audit.
    ///   - now: The time.
    /// - Returns: What it gave.
    /// - Throws: `Plan.Failure`, with the plan unchanged.
    public func editPlan(
        _ edit: PlanEdit, by: PlanEdit.Changer = .person, queued: String? = nil, now: Date = Date()
    ) throws -> PlanEdit.Applied {
        let lastPrompt = store.lastPromptEntry
        var applied: PlanEdit.Applied
        if let plan {
            applied = try plan.apply(edit, by: by, lastPrompt: lastPrompt, now: now)
        } else {
            applied = try edit.apply(to: store.plan, by: by, lastPrompt: lastPrompt, now: now)
        }
        store.plan = applied.plan
        if let queued { applied.details["queued"] = .string(queued) }
        audit?.record(applied.kind, details: applied.details)
        return applied
    }

    /// Applies the person's changes queued for thread `thread` from a terminal while this process held it (decision
    /// 23), in the order filed, as the person's. A change refused now (its task gone, a check failing) is told to the
    /// model and the audit as refused, so the person who is not there sees why in the thread.
    ///
    /// - Parameters:
    ///   - queue: The queue.
    ///   - thread: The thread this agent runs.
    ///   - now: The time.
    /// - Returns: How many were applied.
    @discardableResult
    public func applyQueuedPlanChanges(from queue: PlanQueue, thread: String, now: Date = Date()) -> Int {
        var applied = 0
        for item in queue.take(thread: thread) {
            do {
                _ = try editPlan(item.edit, by: .person, queued: item.id, now: now)
                applied += 1
            } catch {
                let line = "the person: \(item.edit.words) could not be made: \(error)"
                if let plan { plan.tell(line) } else { store.plan.tellModel(line) }
                store.plan = plan?.plan ?? store.plan
                audit?.record(
                    .planQueued,
                    details: [
                        "thread": .string(thread), "change": .string(item.edit.words), "queued": .string(item.id),
                        "outcome": .string("refused"), "reason": .string("\(error)"),
                    ])
            }
        }
        return applied
    }
}

extension ThreadRecord {
    /// The store id of the conversation's last prompt, at which a tree the person starts is rooted; nil before the
    /// first turn.
    var lastPromptEntry: Int? { entries.last { $0.kind == .prompt && $0.origin == .turn }?.id }
}

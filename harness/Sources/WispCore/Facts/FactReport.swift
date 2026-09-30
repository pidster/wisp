import Foundation

/// Facts as the person reads them (decision D3 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): chat's
/// `/inspect facts` and `/task`, and the MCP facts resources, render them here.
public enum FactReport {
    /// The facts as a Markdown table: the current ones, or with `all` every version, superseded and deleted
    /// ones included. Each row gives the id, what it is about, the value, the source and how it was made,
    /// the class, and a note: which fact wins a conflict and which disagree, and how to keep a proposal.
    ///
    /// Proposals from the process's other conversations follow, under their own heading, by the reference
    /// `/fact` takes (`git/c3`).
    ///
    /// - Parameters:
    ///   - facts: Every fact the conversation sees, in any state (`Agent.allFacts`).
    ///   - all: Whether to include superseded and deleted versions.
    ///   - elsewhere: Proposed permanent facts of other conversations awaiting the person
    ///     (`Agent.proposalsElsewhere`).
    /// - Returns: The text.
    public static func markdown(_ facts: [Fact], all: Bool, elsewhere: [FactProposal] = []) -> String {
        let view = FactView(facts)
        let shown = facts.filter { all || $0.state == .current }.sorted { lhs, rhs in
            lhs.identity.key != rhs.identity.key ? lhs.identity.key < rhs.identity.key : lhs.recorded < rhs.recorded
        }
        let title = all ? "# Facts, with their history" : "# Facts"
        guard !shown.isEmpty else {
            return title + "\n\nNo facts yet. `/fact SUBJECT [NAME] = VALUE` states one; `/task TEXT` sets the task.\n"
                + proposals(elsewhere)
        }
        var rows = [
            title, "",
            "| ID | Subject | Name | Value | Source | Class |" + (all ? " State |" : "") + " Note |",
            "| --- | --- | --- | --- | --- | --- |" + (all ? " --- |" : "") + " --- |",
        ]
        for fact in shown {
            let cells = [
                fact.id, fact.identity.subject, fact.identity.name.isEmpty ? "-" : fact.identity.name, fact.value,
                source(fact), fact.proposed ? "permanent (proposed)" : fact.temporalClass.rawValue,
            ]
            var row = "| " + cells.map(cell).joined(separator: " | ") + " |"
            if all { row += " \(fact.state.rawValue)\(fact.supersededBy.map { " by \($0)" } ?? "") |" }
            row += " \(cell(note(fact, view: view))) |"
            rows.append(row)
        }
        let conflicts = view.groups.filter(\.inConflict).count
        rows.append("")
        rows.append(
            "\(view.groups.count) subject\(view.groups.count == 1 ? "" : "s") in force"
                + (conflicts > 0 ? ", \(conflicts) in conflict" : "")
                + ". `/fact delete ID` deletes one; `/fact ID permanent|thread|session` moves one.")
        return rows.joined(separator: "\n") + "\n" + proposals(elsewhere)
    }

    /// The section listing other conversations' proposals, or nothing when there are none.
    ///
    /// - Parameter elsewhere: The proposals.
    /// - Returns: The section, starting with a blank line.
    static func proposals(_ elsewhere: [FactProposal]) -> String {
        guard !elsewhere.isEmpty else { return "" }
        var rows = [
            "", "## Proposed in other conversations", "",
            "| ID | Subject | Name | Value | Source | Conversation | Note |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        for proposal in elsewhere {
            let fact = proposal.fact
            let cells = [
                proposal.reference, fact.identity.subject, fact.identity.name.isEmpty ? "-" : fact.identity.name,
                fact.value, source(fact), proposal.conversation, "",
            ]
            rows.append("| " + cells.map(cell).joined(separator: " | ") + " |")
        }
        rows.append("")
        rows.append(
            "`/fact ID permanent` keeps one for every conversation; `/fact ID session` shares it with this session.")
        return rows.joined(separator: "\n") + "\n"
    }

    /// The task and its versions, as `/task` shows them.
    ///
    /// - Parameter history: The task's versions, oldest first (`Agent.taskHistory`).
    /// - Returns: The text.
    public static func task(_ history: [Fact]) -> String {
        guard let current = history.last(where: { $0.state == .current }) else {
            return history.isEmpty
                ? "no task yet; /task TEXT sets one"
                : "no task now (the last was deleted); /task TEXT sets one"
        }
        var lines = [
            "task: \(current.value)", "  \(source(current)), \(current.recorded.ISO8601Format()), \(current.id)",
        ]
        let earlier = history.filter { $0.id != current.id }
        if !earlier.isEmpty {
            lines.append("earlier:")
            lines += earlier.reversed().map {
                "  \($0.id) \($0.state.rawValue): \($0.value) (\(source($0)), \($0.recorded.ISO8601Format()))"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Who a fact came from, and how: `person`, `tool run_command`, `model, distilled: the person said…`.
    static func source(_ fact: Fact) -> String {
        FactComposition.provenance(fact)
    }

    /// The note on a fact: its place in a conflict, or how to keep it.
    static func note(_ fact: Fact, view: FactView) -> String {
        guard fact.state == .current else { return "" }
        var notes: [String] = []
        if let group = view.group(fact.identity.key), group.inConflict {
            if group.winner.id == fact.id {
                notes.append("wins; disagreeing: " + group.disagreeing.map(\.id).joined(separator: ", "))
            } else if group.disagreeing.contains(where: { $0.id == fact.id }) {
                notes.append("disagrees with \(group.winner.id), which wins")
            }
        }
        if fact.proposed { notes.append("/fact \(fact.id) permanent to keep it") }
        return notes.joined(separator: "; ")
    }

    /// `text` safe in a table cell: one line, pipes escaped.
    private static func cell(_ text: String) -> String {
        OutputReference.shortened(text.split(whereSeparator: \.isNewline).joined(separator: " "), to: 160)
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// The note chat prints after a turn that recorded or changed facts, in one line: how many, the first few
    /// with their ids, values, and sources, a count of the rest, and how to move one; nil when there are none.
    ///
    /// - Parameters:
    ///   - facts: The facts (`Agent.Reply.facts`).
    ///   - limit: How many to name.
    /// - Returns: The line, such as `2 new facts: c7 release codename = BLUE HERON (model), c8 branch = main
    ///   (tool) - /fact <id> permanent|thread|session`.
    public static func newFacts(_ facts: [Fact], limit: Int = 3) -> String? {
        guard !facts.isEmpty else { return nil }
        let shown = facts.prefix(limit).map { fact -> String in
            let label = fact.identity.name.isEmpty ? fact.identity.subject : fact.identity.name
            let value = OutputReference.shortened(
                fact.value.split(whereSeparator: \.isNewline).joined(separator: " "), to: 60)
            return "\(fact.id) \(label) = \(value) (\(fact.source.rawValue))"
        }
        let more = facts.count > limit ? ", and \(facts.count - limit) more" : ""
        return "\(facts.count) new fact\(facts.count == 1 ? "" : "s"): \(shown.joined(separator: ", "))\(more)"
            + " \u{2014} /fact <id> permanent|thread|session"
    }

    /// The facts a turn recorded or changed, as JSON: `id`, `scope` (`permanent`, `thread`, `session`),
    /// `subject`, `name`, `value`, `source`, and `proposed`, whether the fact awaits the person for permanent.
    ///
    /// - Parameter facts: The facts (`Agent.Reply.facts`).
    /// - Returns: An array of objects.
    public static func newFactsJSON(_ facts: [Fact]) -> JSONValue {
        .array(
            facts.map { fact in
                .object([
                    "id": .string(fact.id), "scope": .string(FactTarget(holding: fact).rawValue),
                    "subject": .string(fact.identity.subject), "name": .string(fact.identity.name),
                    "value": .string(fact.value), "source": .string(fact.source.rawValue),
                    "proposed": .bool(fact.proposed),
                ])
            })
    }

    /// One fact as JSON, for the MCP facts resources.
    ///
    /// - Parameters:
    ///   - fact: The fact.
    ///   - view: The facts in force, for its conflicts.
    /// - Returns: The object.
    public static func json(_ fact: Fact, view: FactView) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(fact.id), "scope": .string(FactTarget(holding: fact).rawValue),
            "subject": .string(fact.identity.subject), "name": .string(fact.identity.name),
            "value": .string(fact.value), "source": .string(fact.source.rawValue), "version": .int(fact.version),
            "class": .string(fact.temporalClass.rawValue), "method": .string(fact.method.rawValue),
            "state": .string(fact.state.rawValue), "recorded": .string(fact.recorded.ISO8601Format()),
            "entries": .array(fact.entries.map { .int($0) }), "sources": .array(fact.audit.map { .string($0.event) }),
            "proposed": .bool(fact.proposed),
        ]
        if let detail = fact.detail { object["detail"] = .string(detail) }
        if let turn = fact.turn { object["turn"] = .int(turn) }
        if let by = fact.supersededBy { object["supersededBy"] = .string(by) }
        if let approved = fact.approved { object["approved"] = .string(approved.ISO8601Format()) }
        if fact.state == .current, let group = view.group(fact.identity.key), group.inConflict {
            object["conflict"] = .object([
                "winner": .string(group.winner.id), "disagreeing": .array(group.disagreeing.map { .string($0.id) }),
            ])
        }
        return .object(object)
    }
}

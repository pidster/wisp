import Foundation

/// Restoring stored material for the current turn, `memory`'s `recall` (phase 4c of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), "Recall", decisions D2,
/// D8, and D12): what the words after `recall` name, the material they name rendered as lines, and a page of
/// them. Pure: the audit log is reached through a function, so tests need no files and no model.
///
/// Content comes from the audit log, the one verbatim record (D8), through each entry's references
/// (`ThreadRecord.Entry.sources`). The thread record's own copy of an entry, which phase 2 kept in memory so that
/// composing never reads the audit files, is the fallback for an entry the audit does not hold: one with no
/// references (text the model wrote before a tool call, an agent without a tool trail) or whose event is gone
/// (audit disabled, or rotated out of the files kept). The result says which it used.
enum Recall {
    /// What the words after `recall` name.
    enum Target: Equatable, Sendable {
        /// A stored entry, by its store id: the number references and markers name.
        case entry(Int)
        /// Every stored entry of a turn, by the turn's number, as facts' sources name it.
        case turn(Int)
        /// The task: its versions, and the prompt the conversation began with.
        case task
        /// The running summary's versions.
        case summary
        /// A fact's versions and sources, by its id or by words from its subject, name, or value; empty lists
        /// what is known.
        case fact(String)
        /// A stored output, by the id a held-back marker names: the whole output in the conversation's output
        /// store (ADR 0050), reachable before its turn ends and its entry exists.
        case output(String)

        /// The name the audit records (`context.memory`'s `target`).
        var name: String {
            switch self {
            case .entry: "entry"
            case .turn: "turn"
            case .task: "task"
            case .summary: "summary"
            case .fact: "fact"
            case .output: "output"
            }
        }
    }

    /// A filter over the lines of what was recalled, applied before paging (ADR 0050): the lines that match a
    /// pattern, a range of lines, the first lines, or the last. Each filtered line carries its number in the
    /// whole, so the model can page to it.
    enum Filter: Equatable, Sendable {
        /// Every line.
        case none
        /// The lines matching a regular expression, or containing the text when it is not one.
        case matching(String)
        /// Lines `first` to `last`, inclusive, from 1.
        case lines(Int, Int)
        /// The first `count` lines.
        case head(Int)
        /// The last `count` lines.
        case tail(Int)

        /// The words that ask for it, for the next page's hint; empty for none.
        var phrase: String {
            switch self {
            case .none: ""
            case .matching(let pattern): " matching \(pattern)"
            case .lines(let first, let last): " lines \(first)-\(last)"
            case .head(let count): " head \(count)"
            case .tail(let count): " tail \(count)"
            }
        }

        /// The filter's name for the audit; nil for none.
        var name: String? {
            switch self {
            case .none: nil
            case .matching: "matching"
            case .lines: "lines"
            case .head: "head"
            case .tail: "tail"
            }
        }

        /// `lines` filtered, each prefixed with its number (`44: text`), and a line saying what was kept of how
        /// many; `lines` unchanged for `.none`.
        ///
        /// - Parameter lines: The whole, in order.
        /// - Returns: The lines to page, and the note for the header; nil note for `.none`.
        func apply(to lines: [String]) -> (lines: [String], note: String?) {
            let numbered = { (range: Range<Int>) in range.map { "\($0 + 1): \(lines[$0])" } }
            switch self {
            case .none:
                return (lines, nil)
            case .matching(let pattern):
                let regex = try? Regex(pattern).ignoresCase()
                let matched = lines.indices.filter { index in
                    if let regex { return lines[index].contains(regex) }
                    return lines[index].localizedCaseInsensitiveContains(pattern)
                }
                let kept = matched.map { "\($0 + 1): \(lines[$0])" }
                let how = regex == nil ? "containing" : "matching"
                return (kept, "\(matched.count) of \(lines.count) lines \(how) \(pattern)")
            case .lines(let first, let last):
                let low = max(1, first)
                let high = min(lines.count, max(low, last))
                guard low <= lines.count else { return ([], "no lines \(first)-\(last): it has \(lines.count) lines") }
                return (numbered((low - 1)..<high), "lines \(low)-\(high) of \(lines.count)")
            case .head(let count):
                let kept = min(lines.count, max(0, count))
                return (numbered(0..<kept), "the first \(kept) of \(lines.count) lines")
            case .tail(let count):
                let kept = min(lines.count, max(0, count))
                return (numbered((lines.count - kept)..<lines.count), "the last \(kept) of \(lines.count) lines")
            }
        }
    }

    /// Where an entry's content was read from.
    enum Origin: String, Sendable {
        /// The audit event its reference names.
        case audit
        /// The thread record's in-memory copy.
        case store

        /// In words, for the result's header.
        var words: String { self == .audit ? "from the audit log" : "from the conversation's store" }
    }

    /// What was found: the lines to page, and what they came from, for the audit.
    struct Material: Equatable, Sendable {
        /// The first line of every page: what this is.
        var header: String
        /// The lines to page.
        var lines: [String]
        /// Whether anything was found.
        var found: Bool
        /// The store ids of the entries whose content is in `lines`.
        var entries: [Int] = []
        /// The ids of the facts in `lines`.
        var facts: [String] = []
        /// The running summary's versions in `lines`.
        var summaries: [Int] = []
        /// The ids of the audit events read.
        var events: [String] = []
        /// Where the entries' content came from.
        var origins: Set<Origin> = []

        /// `audit`, `store`, or `audit+store`; nil when no entry content is in it.
        var from: String? {
            switch (origins.contains(.audit), origins.contains(.store)) {
            case (true, true): "audit+store"
            case (true, false): "audit"
            case (false, true): "store"
            case (false, false): nil
            }
        }
    }

    /// What every target answers before anything is stored: a model that recalls in the first turn must not
    /// read "none" as "the person gave no task" (the first on-device eval run did, and said so).
    static let nothingEarlier =
        "memory: nothing earlier is stored yet; this is the conversation's first turn, and all of it is in your "
        + "context as the person wrote it"

    /// The most bytes of lines a page carries without a budget, besides its header and its last line: the
    /// tool-output budget's floor, `read_file`'s page before ADR 0050.
    static let pageBytes = ToolBudget.floor
    /// At most this many subjects answer one fact query.
    static let factGroups = 4

    /// What `what` names, the line to start from (`… from line 60`, as a page's end spells it; 1 without), `what`
    /// without those parts, for the next page's hint, and the filter it asks for (`matching PATTERN`, `lines A-B`,
    /// `head N`, `tail N`; ADR 0050).
    ///
    /// - Parameter what: The argument, as the model wrote it.
    /// - Returns: The target, the first line, what was named, and the filter.
    static func request(_ what: String) -> (target: Target, offset: Int, named: String, filter: Filter) {
        var named = what.trimmingCharacters(in: .whitespacesAndNewlines)
        var offset = 1
        if let match = named.firstMatch(of: #/(?i),?\s*(?:from|at|starting at)\s+(?:line|offset)\s+(\d+)\s*$/#) {
            offset = max(1, Int(match.1) ?? 1)
            named = String(named[..<match.range.lowerBound])
        }
        var filter = Filter.none
        if let match = named.firstMatch(of: #/(?i),?\s+(?:matching|grep|containing)\s+(.+?)\s*$/#) {
            filter = .matching(String(match.1))
            named = String(named[..<match.range.lowerBound])
        } else if let match = named.firstMatch(of: #/(?i),?\s+lines?\s+(\d+)\s*(?:-|–|to)\s*(\d+)\s*$/#) {
            filter = .lines(Int(match.1) ?? 1, Int(match.2) ?? 1)
            named = String(named[..<match.range.lowerBound])
        } else if let match = named.firstMatch(of: #/(?i),?\s+(head|tail|first|last)\s+(\d+)(?:\s+lines)?\s*$/#) {
            let count = Int(match.2) ?? 0
            filter = ["head", "first"].contains(match.1.lowercased()) ? .head(count) : .tail(count)
            named = String(named[..<match.range.lowerBound])
        }
        return (target(named), offset, named, filter)
    }

    /// What `what` names. Lenient, for a small model: `output` with an eight-character hex id is a stored output;
    /// a fact id (`c12`, `fact c12`) is a fact; anything with `summary` is the summary; anything else starting with
    /// `fact` is a fact query; `task` without a number is the task; `turn` with a number is a turn; any other text
    /// with a number is an entry (`entry 7`, `7`, `output 7`); and the rest is a fact query (`codename`, `CI`).
    ///
    /// - Parameter what: The argument, as the model wrote it.
    /// - Returns: The target.
    static func target(_ what: String) -> Target {
        let text = what.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let match = text.firstMatch(of: #/output\s+([0-9a-f]{8})\b/#) { return .output(String(match.1)) }
        if let match = text.wholeMatch(of: #/(?:facts?\s+)?([cps]\d+)/#) { return .fact(String(match.1)) }
        if text.contains("summary") { return .summary }
        if let rest = text.firstMatch(of: #/^facts?\b\s*(.*)$/#) {
            return .fact(String(rest.1).trimmingCharacters(in: .whitespaces))
        }
        let number = text.firstMatch(of: #/\d+/#).flatMap { Int($0.output) }
        if text.contains("task"), number == nil { return .task }
        if let number {
            return text.contains("turn") ? .turn(number) : .entry(number)
        }
        return .fact(text)
    }

    /// The material `target` names in `material`.
    ///
    /// - Parameters:
    ///   - target: What to restore.
    ///   - material: The conversation's record and facts.
    ///   - read: Reads an audit event back by reference; nil when it is not there.
    ///   - outputs: The conversation's output store, which holds whole outputs the model saw only in part; nil
    ///     when it has none.
    ///   - timeZone: The zone times are written in.
    /// - Returns: What was found, or a note saying why nothing was.
    static func material(
        _ target: Target, in material: MemorySource.Material, read: (AuditReference) -> AuditEvent?,
        outputs: OutputStore? = nil, timeZone: TimeZone = .current
    ) -> Material {
        // A stored output exists from its call, before its turn ends and its entry is stored.
        if case .output(let id) = target { return output(id, in: outputs) }
        guard
            material.store.entries.contains(where: { $0.origin != .carried }) || !material.facts.isEmpty
                || !material.store.summaries.isEmpty
        else {
            return Material(header: nothingEarlier, lines: [], found: false)
        }
        return switch target {
        case .entry(let id): entry(id, in: material.store, read: read, outputs: outputs, timeZone: timeZone)
        case .turn(let number): turn(number, in: material.store, read: read)
        case .task: task(material, read: read, timeZone: timeZone)
        case .summary: summaries(material.store.summaries)
        case .fact(let query): facts(query, in: material.facts, timeZone: timeZone)
        case .output(let id): output(id, in: outputs)
        }
    }

    /// `material` with `filter` applied to its lines and the filter's note added to its header; `material` as it
    /// is for `.none`.
    ///
    /// - Parameters:
    ///   - material: What was found.
    ///   - filter: The filter.
    /// - Returns: The filtered material.
    static func filtered(_ material: Material, by filter: Filter) -> Material {
        guard material.found, filter != .none else { return material }
        var result = material
        let applied = filter.apply(to: material.lines)
        result.lines = applied.lines
        if let note = applied.note { result.header += "; " + note }
        return result
    }

    /// The whole of stored output `id`, from the output store.
    private static func output(_ id: String, in outputs: OutputStore?) -> Material {
        guard let outputs else {
            return Material(
                header: "memory: this conversation has no output store, so output \(id) was not kept", lines: [],
                found: false)
        }
        guard let kept = outputs.kept(id), let lines = outputs.lines(id) else {
            return Material(
                header: "memory: no output \(id) in this conversation's store; the id is the one a held-back note "
                    + "names (output 3f9a2c1b)", lines: [], found: false)
        }
        var header = "output \(id): \(kept.tool), \(kept.lines.formatted()) lines, \(ToolOutput.size(kept.bytes))"
        header += ", from the output store"
        if kept.cut { header += " (cut at \(ToolOutput.size(kept.bytes)); the rest was not kept)" }
        return Material(header: header, lines: lines, found: true)
    }

    /// A page of `material`: its header, then its lines from 1-based `offset` within `pageBytes`, then either the
    /// hint for the next page or the end marker. A line longer than a page is cut.
    ///
    /// - Parameters:
    ///   - material: What was found.
    ///   - what: What was recalled, repeated in the hint after `recall`.
    ///   - offset: The first line to show.
    ///   - maxBytes: The most the page's lines may take.
    /// - Returns: The tool's result.
    static func page(_ material: Material, what: String, offset: Int, maxBytes: Int = pageBytes) -> String {
        guard material.found else { return material.header }
        let start = max(1, offset)
        guard start <= material.lines.count else {
            return material.header + "\n[no line \(start): it has \(material.lines.count) lines]"
        }
        var shown: [String] = []
        var used = 0
        var next = start
        for line in material.lines[(start - 1)...] {
            let cost = line.utf8.count + 1
            if used + cost > maxBytes, !shown.isEmpty { break }
            shown.append(cost > maxBytes ? ToolOutput.bounded(line, maxBytes: maxBytes - 64) : line)
            used += cost
            next += 1
        }
        let quoted = what.replacingOccurrences(of: "\"", with: "'")
        let last =
            next <= material.lines.count
            ? "[more: memory \"recall \(quoted) from line \(next)\"]" : "[end of what recall found]"
        return ([material.header] + shown + [last]).joined(separator: "\n")
    }

    // MARK: - Entries

    /// Entry `id`'s content, under a header naming what it is, its turn, when, and where the content came from. A
    /// tool output the model saw only in part is read whole from the output store when it is there (ADR 0050):
    /// the `tool.result` event's call id is the output's id.
    private static func entry(
        _ id: Int, in store: ThreadRecord, read: (AuditReference) -> AuditEvent?, outputs: OutputStore?,
        timeZone: TimeZone
    ) -> Material {
        guard id >= 1, id <= store.entries.count else {
            let range = store.entries.isEmpty ? "none is stored yet" : "entries run from 1 to \(store.entries.count)"
            return Material(
                header:
                    "memory: no entry \(id) in this conversation; \(range), and this turn's own are already in view",
                lines: [], found: false)
        }
        let entry = store.entries[id - 1]
        var header = "entry \(id): \(label(entry))"
        if let turn = entry.turn { header += ", turn \(turn)" }
        if let time = entry.time { header += " at " + OutputReference.clock(time, in: timeZone) }
        var lines: [String] = []
        var arguments: String?
        if case .toolOutput(let output) = entry.value, let call = store.calls[output.id] {
            arguments =
                "arguments: " + OutputReference.shortened(call.arguments, to: OutputReference.argumentCharacters)
        }
        if entry.kind == .toolOutput, let outputs, let reference = entry.sources.first, let event = read(reference),
            let call = event.call, let kept = outputs.kept(call), let whole = outputs.lines(call)
        {
            // The whole output's lines are numbered as the stored file's, which the held-back markers name, so the
            // arguments go in the header rather than taking line 1.
            header += ", the whole output from the output store (\(kept.lines.formatted()) lines"
            header += kept.cut ? ", cut at \(ToolOutput.size(kept.bytes)))" : ")"
            if let arguments { header += "; " + arguments }
            return Material(header: header, lines: whole, found: true, entries: [id], events: [event.id ?? ""])
        }
        if let arguments { lines.append(arguments) }
        let content = content(of: entry, store: store, read: read)
        if let origin = content.origin { header += ", " + origin.words }
        lines += content.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = Material(header: header, lines: lines, found: true, entries: [id], events: content.events)
        if let origin = content.origin { found.origins = [origin] }
        return found
    }

    /// What an entry is, in words.
    private static func label(_ entry: ThreadRecord.Entry) -> String {
        if let command = entry.command {
            return
                "the person's command `\(OutputReference.shortened(command.line, to: 100))` in \(command.directory), "
                + "exit status \(command.exitStatus)"
        }
        return switch entry.value {
        case .toolOutput(let output): "\(output.toolName) output"
        case .prompt: "prompt"
        case .response: "reply"
        case .toolCalls: "tool calls"
        case .instructions: "the instructions"
        case .reasoning: "the model's thinking"
        default: entry.kind.rawValue
        }
    }

    /// An entry's text, read from the audit event its reference names when the audit holds it and it is of the
    /// kind the entry expects, else from the store's copy. The instructions have no text here: every request
    /// carries them; nor has the model's thinking, which no request carries (ADR 0053).
    ///
    /// - Returns: The text, where it came from (nil for the instructions), and the audit events read.
    private static func content(
        of entry: ThreadRecord.Entry, store: ThreadRecord, read: (AuditReference) -> AuditEvent?
    ) -> (text: String, origin: Origin?, events: [String]) {
        func event(_ reference: AuditReference?, _ kind: AuditEvent.Kind) -> AuditEvent? {
            guard let reference, let found = read(reference), found.kind == kind else { return nil }
            return found
        }
        if entry.kind == .command, let found = event(entry.sources.first, .commandTyped),
            let text = found.details["output"]?.stringValue
        {
            return (text, .audit, [found.id ?? ""])
        }
        switch entry.value {
        case .instructions:
            return ("(the instructions, which every request carries in full)", nil, [])
        case .reasoning:
            // The thinking is the person's to read, never the model's context (ADR 0053), recalled or not.
            return ("(the model's thinking, kept for the person and not recalled)", nil, [])
        case .toolOutput:
            if let found = event(entry.sources.first, .toolResult), let text = found.details["output"]?.stringValue {
                return (text, .audit, [found.id ?? ""])
            }
        case .prompt:
            if let found = event(entry.sources.first, .prompt), let text = found.details["text"]?.stringValue {
                return (text, .audit, [found.id ?? ""])
            }
        case .response:
            if let found = event(entry.sources.first, .response), let text = found.details["text"]?.stringValue {
                return (text, .audit, [found.id ?? ""])
            }
        case .toolCalls(let calls):
            let found = entry.sources.compactMap { event($0, .toolCall) }
            if !found.isEmpty, found.count == calls.count {
                let lines = found.map {
                    "\($0.details["tool"]?.stringValue ?? "?") \($0.details["arguments"]?.stringValue ?? "")"
                }
                return (lines.joined(separator: "\n"), .audit, found.compactMap(\.id))
            }
            return (calls.map { "\($0.toolName) \($0.arguments.jsonString)" }.joined(separator: "\n"), .store, [])
        default:
            break
        }
        return (ThreadRecord.text(of: entry.value), .store, [])
    }

    // MARK: - Turns

    /// Every stored entry of turn `number`, each under a line naming it: this session's turn of that number, or,
    /// when it has none, a resumed store's.
    private static func turn(
        _ number: Int, in store: ThreadRecord, read: (AuditReference) -> AuditEvent?
    ) -> Material {
        let recorded = store.entries.filter { $0.turn == number && $0.origin != .carried }
        let own = recorded.filter { $0.origin == .turn }
        let entries = own.isEmpty ? recorded : own
        guard let first = entries.first, let last = entries.last else {
            let turns = store.entries.compactMap(\.turn)
            let range =
                turns.isEmpty ? "none is stored yet" : "turns run from \(turns.min() ?? 0) to \(turns.max() ?? 0)"
            return Material(
                header: "memory: no turn \(number) in this conversation's store; \(range), and this turn is already "
                    + "in view", lines: [], found: false)
        }
        var found = Material(header: "", lines: [], found: true)
        for entry in entries {
            let content = content(of: entry, store: store, read: read)
            found.lines.append("[entry \(entry.id), \(label(entry))]")
            found.lines += content.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            found.entries.append(entry.id)
            found.events += content.events
            if let origin = content.origin { found.origins.insert(origin) }
        }
        let span = first.id == last.id ? "entry \(first.id)" : "entries \(first.id)-\(last.id)"
        found.header = "turn \(number): \(span)" + (found.from.map { ", " + words($0) } ?? "")
        return found
    }

    /// `audit`, `store`, or `audit+store` in words.
    private static func words(_ from: String) -> String {
        switch from {
        case "audit": Origin.audit.words
        case "store": Origin.store.words
        default: "from the audit log and the conversation's store"
        }
    }

    // MARK: - The task

    /// The task's versions, oldest first, with who stated or inferred each and the entries it came from, then the
    /// prompt the conversation began with, in full: the task's original statement when the person gave it there.
    private static func task(
        _ material: MemorySource.Material, read: (AuditReference) -> AuditEvent?, timeZone: TimeZone
    ) -> Material {
        let versions = material.facts.filter { $0.identity.subject == "task" }.sorted { $0.recorded < $1.recorded }
        var found = Material(header: "", lines: [], found: true)
        if versions.isEmpty {
            found.lines.append("No task has been set or inferred.")
        } else {
            found.lines.append("\(versions.count) version\(versions.count == 1 ? "" : "s"), oldest first:")
            found.lines += versions.map { line($0, timeZone: timeZone) }
            found.facts = versions.map(\.id)
        }
        let store = material.store
        if let first = store.entries.first(where: { $0.kind == .prompt && $0.origin != .carried })
            ?? store.entries.first(where: { $0.kind == .prompt })
        {
            let content = content(of: first, store: store, read: read)
            found.lines.append(
                "The conversation began with entry \(first.id)" + (first.turn.map { ", turn \($0)" } ?? "") + ":")
            found.lines += content.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            found.entries = [first.id]
            found.events = content.events
            if let origin = content.origin { found.origins = [origin] }
        }
        guard !versions.isEmpty || !found.entries.isEmpty else {
            return Material(header: Self.nothingEarlier, lines: [], found: false)
        }
        found.header = "task" + (found.from.map { ", the first prompt " + words($0) } ?? "")
        return found
    }

    // MARK: - The summary

    /// The running summary's versions, newest first, each with the turns it covers and when it was written.
    private static func summaries(_ versions: [RunningSummary]) -> Material {
        guard !versions.isEmpty else {
            return Material(
                header: "memory: no summary has been written; turns are summarised once condensing drops them",
                lines: [], found: false)
        }
        var lines: [String] = []
        for summary in versions.reversed() {
            let turns = summary.turns.isEmpty ? "" : ", added turns \(span(summary.turns))"
            let written = summary.turn.map { $0 > 0 ? ", written at turn \($0)" : ", written before this session" }
            lines.append(
                "- v\(summary.version) of \(summary.covered) turns\(turns)\(written ?? "") by \(summary.model):")
            lines.append(summary.text)
        }
        return Material(
            header: "summary: \(versions.count) version\(versions.count == 1 ? "" : "s"), newest first", lines: lines,
            found: true, summaries: versions.reversed().map(\.version))
    }

    /// `[3, 4, 5]` as `3-5`, `[3]` as `3`.
    private static func span(_ numbers: [Int]) -> String {
        guard let low = numbers.min(), let high = numbers.max() else { return "" }
        return low == high ? "\(low)" : "\(low)-\(high)"
    }

    // MARK: - Facts

    /// The versions of the facts `query` names (D2's history), oldest first under each subject and name, each with
    /// its source, when, its state, and the entries it came from; or, for an empty query or no match, what the
    /// conversation knows about, so the model can ask again.
    private static func facts(_ query: String, in facts: [Fact], timeZone: TimeZone) -> Material {
        let keys = matching(query, in: facts)
        guard !keys.isEmpty else {
            let known = Array(Set(facts.map(\.identity.key))).sorted().map { key in
                key.name.isEmpty ? key.subject : "\(key.subject) \(FactComposition.shortenedName(key.name))"
            }
            let listed = known.isEmpty ? "none are kept" : "known: " + known.prefix(24).joined(separator: "; ")
            let asked = query.isEmpty ? "" : " matches \"\(query)\""
            return Material(header: "memory: no fact\(asked); \(listed)", lines: [], found: false)
        }
        var found = Material(header: "", lines: [], found: true)
        for key in keys {
            let versions = facts.filter { $0.identity.key == key }.sorted { $0.recorded < $1.recorded }
            let name = key.name.isEmpty ? key.subject : "\(key.subject) \(key.name)"
            found.lines.append("\(name): \(versions.count) version\(versions.count == 1 ? "" : "s"), oldest first:")
            found.lines += versions.map { line($0, timeZone: timeZone) }
            found.facts += versions.map(\.id)
        }
        let entries = Set(found.facts.compactMap { id in facts.first { $0.id == id } }.flatMap(\.entries))
        if !entries.isEmpty { found.lines.append("memory \"recall entry N\" shows what a fact came from.") }
        found.header = "fact \"\(query)\": \(keys.count) subject\(keys.count == 1 ? "" : "s")"
        return found
    }

    /// One fact version as a line: `- c3 [tool run_command, turn 2] at 11:02:10: failed; superseded by c9; from
    /// entry 9`.
    private static func line(_ fact: Fact, timeZone: TimeZone) -> String {
        var line = "- \(fact.id) [\(FactComposition.provenance(fact))]"
        if fact.source != .tool, let turn = fact.turn { line += ", turn \(turn)" }
        line += " at \(OutputReference.clock(fact.recorded, in: timeZone)): "
        line += OutputReference.shortened(fact.value.split(whereSeparator: \.isNewline).joined(separator: " "), to: 240)
        switch fact.state {
        case .current: line += "; current"
        case .superseded: line += "; superseded" + (fact.supersededBy.map { " by \($0)" } ?? "")
        case .deleted: line += "; deleted by the person"
        }
        if !fact.entries.isEmpty, fact.source != .tool || fact.entries.count > 1 {
            line +=
                "; from entr\(fact.entries.count == 1 ? "y" : "ies") "
                + fact.entries.prefix(8).map(String.init).joined(separator: ", ")
        }
        return line
    }

    /// The subjects and names `query` names, best first, at most `factGroups`: a fact id names its own; else an
    /// exact subject or name; else a subject or name that contains the query or is contained in it; else a
    /// value that contains it; else a shared word of three letters or more.
    ///
    /// - Parameters:
    ///   - query: What the model asked for, without the leading `fact`.
    ///   - facts: Every fact, in any state.
    /// - Returns: The keys.
    static func matching(_ query: String, in facts: [Fact]) -> [FactIdentity.Key] {
        let wanted = FactView.folded(query)
        guard !wanted.isEmpty else { return [] }
        if let fact = facts.first(where: { $0.id == wanted }) { return [fact.identity.key] }
        let words = Set(wanted.split(separator: " ").filter { $0.count >= 3 }.map(String.init))
        var scored: [FactIdentity.Key: Int] = [:]
        for fact in facts {
            let key = fact.identity.key
            let subject = FactView.folded(key.subject)
            let name = FactView.folded(key.name)
            let value = FactView.folded(fact.value)
            let score: Int
            if wanted == subject || wanted == name || wanted == "\(subject) \(name)" {
                score = 4
            } else if (!name.isEmpty && (name.contains(wanted) || wanted.contains(name))) || subject.contains(wanted) {
                score = 3
            } else if value.contains(wanted) {
                score = 2
            } else if !words.isDisjoint(
                with: Set((subject + " " + name + " " + value).split(separator: " ").map(String.init)))
            {
                score = 1
            } else {
                continue
            }
            scored[key] = max(scored[key] ?? 0, score)
        }
        guard let best = scored.values.max() else { return [] }
        return scored.filter { $0.value == best }.keys.sorted().prefix(factGroups).map { $0 }
    }
}

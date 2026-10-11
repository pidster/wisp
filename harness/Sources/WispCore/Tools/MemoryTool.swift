import Foundation
import FoundationModels
import Synchronization

/// The conversation's memory, for the model (phase 4c of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), widened on 2026-09-30):
/// one text argument that starts with a verb, as the person's chat commands do.
///
/// - `recall …` restores, for the current turn, earlier material the context holds only as a reference, a marker,
///   a summary, or a fact: a stored entry, a turn, the task, the running summary's versions, or a fact's history
///   and sources (`Recall`). It reads only the conversation's own record, published by its agent
///   (`MemorySource`), and the audit log it refers to. A request without a verb is a recall. Since
///   [ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md) it also reads the
///   conversation's output store: a tool output the model saw only in part is recalled whole, by its entry or by
///   the output id a held-back marker names (`recall output 3f9a2c1b`), and a recall can be filtered (`matching
///   PATTERN`, `lines A-B`, `head N`, `tail N`) before it is paged.
/// - `summarise …` gives the notable lines, or with `overview` an overview, of a stored entry or output, by exact
///   readers and no model (`OutputSummary`).
/// - `condense …: QUESTION` answers a question from the whole of a stored entry or output, in a chunked pass by
///   the model (`OutputCondenser`), each chunk within the budget; the one verb that costs model calls.
/// - `note SUBJECT NAME = VALUE` records a fact as the model, method `noted`, when the turn ends: below the
///   person's and a tool's (D2), of a subject kind the distiller may use, and a proposal only when the kind is
///   permanent, since only the person admits a permanent fact. At most `Memory.notesPerTurn` a turn.
/// - `task TEXT; objective: DONE` proposes the task and its objective as the model's (phase 4d, D6), recorded when
///   the turn ends, and refused when the person or a caller set the task. `task` alone recalls the task.
///
/// One string, because the references and markers the model reads already spell a recall (`memory "recall entry
/// 7"`), and a small model copies a phrase more reliably than it picks among optional fields; every tool's schema
/// is in every request (decision D4 measured them). A later page is named the same way (`recall entry 7 from line
/// 60`). What it returns is an ordinary tool output: whole in its own turn, a reference after it (D12). Each call
/// is audited as `context.memory`, and each note kept as `fact.recorded` when its turn ends. It changes no file
/// and needs no approval. It is off by default (ADR 0057): a conversation given every tool gets it only with
/// `context.memory` on, and a tool list gets it by naming it.
public struct MemoryTool: WispTool {
    /// The tool's name, as registries and the prompt name it.
    public static let toolName = "memory"
    /// The identifier the model uses to request this tool.
    public let name = MemoryTool.toolName
    /// What the model is told this tool does. It names `system_info` because the name is shared with that tool's
    /// `memory` topic, which is the Mac's RAM.
    public let description =
        "This conversation's memory, not the Mac's RAM (that is system_info): recall earlier material in full, "
        + "summarise or question a long output, or note a fact to keep."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// A verb and its object, as `Memory.command(_:)` reads it.
        @Guide(
            description:
                "\"recall entry 7\", \"recall turn 3\", \"recall task\", \"recall fact codename\", \"recall output "
                + "3f9a2c1b matching error\", \"summarise entry 7\", \"condense entry 7: why did it fail\", or \"note "
                + "entity release codename = BLUE HERON\".")
        public var request: String
    }

    /// The most chunks one `condense` reads, so one question is bounded in model calls.
    static let condenseChunks = 48

    /// The conversation's record, as its agent last published it, and where notes wait for it.
    private let source: MemorySource
    /// Where content is read back from and each call is audited; nil reads only the store's copies.
    private let audit: AuditLog?
    /// The zone times are written in.
    private let timeZone: TimeZone
    /// The page: the conversation's tool-output budget.
    private let budget: ToolBudget
    /// The conversation's output store, which holds whole outputs; nil when it has none.
    private let store: OutputStore?
    /// What answers a `condense` question over a stored output; nil leaves the verb unavailable.
    private let condenser: OutputCondenser?

    /// Page size and the bound on notes.
    public var limits: String {
        "Recall pages of up to \(budget.bytes) bytes (the tool-output budget); the end of a page names the next "
            + "(\"recall entry 7 from line 60\"); a recall can be filtered first: matching PATTERN, lines A-B, head N, "
            + "tail N. summarise reads a stored output exactly, no model; condense asks the model a question over all "
            + "of it, at most \(Self.condenseChunks) chunks. Reads only this conversation's record, the audit log, and "
            + "the output store; the result is in view for this turn, then a reference. At most "
            + "\(Memory.notesPerTurn) notes a turn, kept as the model's facts when the turn ends. Off by default: a "
            + "conversation gets it with context.memory on, or by naming it."
    }
    /// How to ask for it.
    public let examplePrompt =
        "Use memory with request \"recall entry 7\" to see the output that entry 7's reference stands for."

    /// Creates the tool over a conversation's record.
    ///
    /// - Parameters:
    ///   - source: What the conversation's agent publishes, and where notes wait for it.
    ///   - audit: Where content is read back from and calls are audited.
    ///   - timeZone: The zone times are written in.
    ///   - budget: The conversation's tool-output budget, which sets the page.
    ///   - store: The conversation's output store.
    ///   - condenser: What answers `condense`.
    public init(
        source: MemorySource, audit: AuditLog? = nil, timeZone: TimeZone = .current, budget: ToolBudget = ToolBudget(),
        store: OutputStore? = nil, condenser: OutputCondenser? = nil
    ) {
        self.source = source
        self.audit = audit
        self.timeZone = timeZone
        self.budget = budget
        self.store = store
        self.condenser = condenser
    }

    /// Carries out the request: a page of what a recall names, a summary, a condensed answer, or a note kept for
    /// the end of the turn.
    ///
    /// - Parameter arguments: The request.
    /// - Returns: The page, the note as kept, or a line saying why nothing was; never throws.
    public func call(arguments: Arguments) async -> String {
        guard let material = source.material else {
            return "error: nothing in memory: this conversation keeps no record"
        }
        switch Memory.command(arguments.request) {
        case .recall(let what): return recall(what, request: arguments.request, in: material)
        case .note(let text): return note(text, request: arguments.request, in: material)
        case .task(let text): return task(text, request: arguments.request, in: material)
        case .summarise(let what): return summarise(what, request: arguments.request, in: material)
        case .condense(let what): return await condense(what, request: arguments.request, in: material)
        }
    }

    /// A page of what `what` names, filtered as it asks, audited.
    private func recall(_ what: String, request: String, in material: MemorySource.Material) -> String {
        let (target, offset, named, filter) = Recall.request(what)
        let found = Recall.filtered(
            Recall.material(target, in: material, read: { audit?.event($0) }, outputs: store, timeZone: timeZone),
            by: filter)
        let page = Recall.page(found, what: named + filter.phrase, offset: offset, maxBytes: budget.bytes)
        var details = AuditEvent.Details.memoryRecall(
            request: request, target: target.name, found: found.found, entries: found.entries, facts: found.facts,
            summaries: found.summaries, events: found.events, from: found.from, offset: offset, bytes: page.utf8.count)
        if case .output(let id) = target { details["output"] = .string(id) }
        if let name = filter.name { details["filter"] = .string(name) }
        audit?.record(.memory, details: details)
        return page
    }

    /// A stored entry or output found whole, or why it was not.
    private enum Stored {
        /// The lines, the tool that made them, and what was named.
        case success((lines: [String], tool: String?, target: Recall.Target))
        /// The result to give instead.
        case failure(String)
    }

    /// The lines of the stored entry or output `what` names, whole, with the tool that made them; or the reason
    /// there are none.
    private func stored(_ what: String, in material: MemorySource.Material) -> Stored {
        let (target, _, _, _) = Recall.request(what)
        switch target {
        case .entry, .output: break
        default: return .failure("error: name a stored entry (entry 7) or output (output 3f9a2c1b)")
        }
        let found = Recall.material(
            target, in: material, read: { audit?.event($0) }, outputs: store, timeZone: timeZone)
        guard found.found else { return .failure(found.header) }
        var lines = found.lines
        if lines.first?.hasPrefix("arguments: ") == true { lines.removeFirst() }
        var tool: String?
        if case .entry(let id) = target, id >= 1, id <= material.store.entries.count,
            case .toolOutput(let output) = material.store.entries[id - 1].value
        {
            tool = output.toolName
        } else if case .output(let id) = target {
            tool = store?.kept(id)?.tool
        }
        return .success((lines, tool, target))
    }

    /// The notable lines, or with `overview` an overview, of a stored entry or output, by exact readers; audited.
    private func summarise(_ what: String, request: String, in material: MemorySource.Material) -> String {
        var named = what.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = OutputSummary.Kind.notable
        if let match = named.firstMatch(of: #/(?i)\s*\b(overview|notable)\b\s*$/#) {
            kind = match.1.lowercased() == "overview" ? .overview : .notable
            named = String(named[..<match.range.lowerBound])
        }
        let result: String
        var target: Recall.Target?
        var found = false
        switch stored(named, in: material) {
        case .failure(let reason):
            result = reason
        case .success(let output):
            target = output.target
            found = true
            let summary = OutputSummary.summarise(output.lines, kind: kind, tool: output.tool)
            result = ToolOutput.bounded(summary.joined(separator: "\n"), maxBytes: budget.bytes)
        }
        var details: [String: JSONValue] = [
            "request": .string(request), "action": .string("summarise"), "found": .bool(found),
            "bytes": .int(result.utf8.count), "summary": .string(kind.rawValue),
        ]
        if let target {
            details["target"] = .string(target.name)
            if case .entry(let id) = target { details["entries"] = .array([.int(id)]) }
            if case .output(let id) = target { details["output"] = .string(id) }
        }
        audit?.record(.memory, details: details)
        return result
    }

    /// The answer to the question after the colon, from the whole of a stored entry or output, by a chunked pass
    /// of the model: each chunk within the budget is asked the question, and the answers are combined into one
    /// that fits (by the model again when they do not); audited with the chunk count.
    private func condense(_ what: String, request: String, in material: MemorySource.Material) async -> String {
        let parts = what.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let named = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        let question = parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var details: [String: JSONValue] = [
            "request": .string(request), "action": .string("condense"), "found": .bool(false),
        ]
        func done(_ result: String, failure: String? = nil) -> String {
            details["bytes"] = .int(result.utf8.count)
            if let failure { details["failure"] = .string(failure) }
            audit?.record(.memory, details: details)
            return result
        }
        guard !question.isEmpty else {
            return done("error: write condense entry N: QUESTION, with the question after the colon", failure: "shape")
        }
        let output: (lines: [String], tool: String?, target: Recall.Target)
        switch stored(named, in: material) {
        case .failure(let reason): return done(reason, failure: "target")
        case .success(let found): output = found
        }
        details["found"] = true
        details["target"] = .string(output.target.name)
        if case .entry(let id) = output.target { details["entries"] = .array([.int(id)]) }
        if case .output(let id) = output.target { details["output"] = .string(id) }
        guard let ask = condenser?.ask else {
            return done(
                "error: condense needs the conversation's model and none is attached; \"summarise\" reads the output "
                    + "exactly, and \"recall … matching PATTERN\" filters it", failure: "off")
        }
        let chunkBytes = max(512, budget.bytes - 512)
        var chunks = Triage.chunks(output.lines.joined(separator: "\n"), maxBytes: chunkBytes)
        let more = chunks.count > Self.condenseChunks
        if more { chunks = Array(chunks.prefix(Self.condenseChunks)) }
        details["chunks"] = .int(chunks.count)
        var answers: [String] = []
        var failures = 0
        for (index, chunk) in chunks.enumerated() {
            let prompt = Self.chunkPrompt(question: question, chunk: chunk, index: index + 1, count: chunks.count)
            do {
                let answer = try await ask(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
                if !answer.isEmpty, !Self.saysNothing(answer) { answers.append("part \(index + 1): " + answer) }
            } catch {
                failures += 1
            }
        }
        if failures > 0 { details["failure"] = .string("\(failures) chunk\(failures == 1 ? "" : "s") failed") }
        var head =
            "condensed answer to \"\(question)\" from \(output.lines.count.formatted()) lines in \(chunks.count) chunks, by the model"
        if more { head += " (the first \(Self.condenseChunks) chunks only)" }
        if failures > 0 { head += " (\(failures) chunk\(failures == 1 ? "" : "s") failed)" }
        guard !answers.isEmpty else { return done(head + ":\nnothing in the output answers it") }
        var body = answers.joined(separator: "\n")
        let room = budget.bytes - head.utf8.count - 64
        if body.utf8.count > room {
            let combined = try? await ask(Self.combinePrompt(question: question, answers: body)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            if let combined, !combined.isEmpty { body = combined }
        }
        return done(head + ":\n" + ToolOutput.bounded(body, maxBytes: room))
    }

    /// The prompt for one chunk.
    static func chunkPrompt(question: String, chunk: String, index: Int, count: Int) -> String {
        """
        Below is part \(index) of \(count) of a tool's output. Answer this question from this part alone, in a \
        few lines, quoting the lines you drew on: \(question)
        If nothing in this part bears on the question, answer exactly: nothing here.

        OUTPUT:
        \(chunk)
        """
    }

    /// The prompt that combines the parts' answers.
    static func combinePrompt(question: String, answers: String) -> String {
        """
        Below are answers to the question "\(question)" from the parts of one output, in order. Combine them into \
        one answer of a few lines, keeping the lines they quote, and drop what repeats.

        ANSWERS:
        \(answers)
        """
    }

    /// Whether a chunk's answer says the chunk had nothing.
    static func saysNothing(_ answer: String) -> Bool {
        answer.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).hasPrefix("nothing here")
    }

    /// Keeps the task `text` proposes for the agent to record when the turn ends, or says why not; audited.
    private func task(_ text: String, request: String, in material: MemorySource.Material) -> String {
        var kept: FactBook.Assertion?
        var refusal: Memory.Refusal?
        switch Memory.task(text, in: material) {
        case .success(let assertion):
            if source.add(assertion) { kept = assertion } else { refusal = .full }
        case .failure(let reason):
            refusal = reason
        }
        audit?.record(
            .memory,
            details: AuditEvent.Details.memoryTask(request: request, value: kept?.value, failure: refusal?.reason))
        guard let kept else { return (refusal ?? .shape).description }
        return "noted the task: \(kept.value)"
    }

    /// Keeps the note `text` makes for the agent to record when the turn ends, or says why not; audited.
    private func note(_ text: String, request: String, in material: MemorySource.Material) -> String {
        var kept: FactBook.Assertion?
        var refusal: Memory.Refusal?
        switch material.kinds.map({ Memory.assertion(text, kinds: $0, turn: material.turn) }) ?? .failure(.off) {
        case .success(let assertion):
            if source.add(assertion) { kept = assertion } else { refusal = .full }
        case .failure(let reason):
            refusal = reason
        }
        audit?.record(
            .memory,
            details: AuditEvent.Details.memoryNote(
                request: request, subject: kept?.identity.subject, name: kept?.identity.name, value: kept?.value,
                temporalClass: kept?.temporalClass, failure: refusal?.reason))
        guard let kept else { return (refusal ?? .shape).description }
        let identity = kept.identity
        return "noted: \(identity.subject)\(identity.name.isEmpty ? "" : " \(identity.name)") = \(kept.value)"
            + (kept.temporalClass == .permanent ? " (a proposal until the person keeps it)" : "")
    }
}

/// What answers `memory`'s `condense` question: one model call per chunk, on the conversation's own model, in a
/// session of its own that the conversation never carries (as `triage` judges a chunk, ADR 0023). The thread
/// attaches the model when its agent opens; until then the verb says it is unavailable. A `final class` with a
/// `Mutex`: the attachment is a short critical section, and the calls run on the caller's task.
public final class OutputCondenser: Sendable {
    /// One question to the model: the prompt in, the answer out.
    public typealias Ask = @Sendable (String) async throws -> String

    /// The attached model, as a function; nil until attached.
    private let state = Mutex<Ask?>(nil)

    /// Creates a condenser with no model attached.
    public init() {}

    /// Attaches `ask`, replacing any earlier one; nil detaches.
    ///
    /// - Parameter ask: Asks the model one question.
    public func attach(_ ask: Ask?) {
        state.withLock { $0 = ask }
    }

    /// The attached model, or nil.
    var ask: Ask? { state.withLock { $0 } }
}

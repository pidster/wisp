import Foundation
import FoundationModels

/// The conversation's memory, for the model (phase 4c of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), widened on 2026-09-30):
/// one text argument that starts with a verb, as the person's chat commands do.
///
/// - `recall …` restores, for the current turn, earlier material the context holds only as a reference, a marker,
///   a summary, or a fact: a stored entry, a turn, the task, the running summary's versions, or a fact's history
///   and sources (`Recall`). It reads only the conversation's own record, published by its agent
///   (`MemorySource`), and the audit log it refers to. A request without a verb is a recall.
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
/// and needs no approval.
public struct MemoryTool: WispTool {
    /// The tool's name, as registries and the prompt name it.
    public static let toolName = "memory"
    /// The identifier the model uses to request this tool.
    public let name = MemoryTool.toolName
    /// What the model is told this tool does. It names `system_info` because the name is shared with that tool's
    /// `memory` topic, which is the Mac's RAM.
    public let description =
        "This conversation's memory, not the Mac's RAM (that is system_info): recall earlier material in full, or "
        + "note a fact to keep."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// A verb and its object, as `Memory.command(_:)` reads it.
        @Guide(
            description:
                "\"recall entry 7\", \"recall turn 3\", \"recall task\", \"recall fact codename\", or \"note entity "
                + "release codename = BLUE HERON\".")
        public var request: String
    }

    /// The conversation's record, as its agent last published it, and where notes wait for it.
    private let source: MemorySource
    /// Where content is read back from and each call is audited; nil reads only the store's copies.
    private let audit: AuditLog?
    /// The zone times are written in.
    private let timeZone: TimeZone

    /// Page size and the bound on notes.
    public var limits: String {
        "Recall pages of up to \(Recall.pageBytes) bytes; the end of a page names the next (\"recall entry 7 from "
            + "line 60\"). Reads only this conversation's record and the audit log; the result is in view for this "
            + "turn, then a reference. At most \(Memory.notesPerTurn) notes a turn, kept as the model's facts when "
            + "the turn ends."
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
    public init(source: MemorySource, audit: AuditLog? = nil, timeZone: TimeZone = .current) {
        self.source = source
        self.audit = audit
        self.timeZone = timeZone
    }

    /// Carries out the request: a page of what a recall names, or a note kept for the end of the turn.
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
        }
    }

    /// A page of what `what` names, audited.
    private func recall(_ what: String, request: String, in material: MemorySource.Material) -> String {
        let (target, offset, named) = Recall.request(what)
        let found = Recall.material(target, in: material, read: { audit?.event($0) }, timeZone: timeZone)
        let page = Recall.page(found, what: named, offset: offset)
        audit?.record(
            .memory,
            details: AuditEvent.Details.memoryRecall(
                request: request, target: target.name, found: found.found, entries: found.entries,
                facts: found.facts, summaries: found.summaries, events: found.events, from: found.from,
                offset: offset, bytes: page.utf8.count))
        return page
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

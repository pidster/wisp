import Foundation
import Synchronization

/// What the `memory` tool reads and writes: a copy of one conversation's record and facts, which its agent
/// publishes before every request (`Agent.memory`), and the notes the model made during the current turn, which
/// the agent records as facts when the turn ends. The tool, which the framework calls from its own task, never
/// touches the agent. A turn's own entries are not in the copy: they are stored when the turn ends, and the model
/// has them whole until then.
public final class MemorySource: Sendable {
    /// One published copy.
    struct Material: Sendable {
        /// The thread's record, every entry active or dropped.
        var store: ThreadRecord
        /// Every fact the conversation sees, in any state, from every scope (`Agent.allFacts`).
        var facts: [Fact]
        /// The subject kinds a note may name; nil when the conversation keeps no facts, so nothing can be noted.
        var kinds: SubjectKinds?
        /// The turn the copy was published for, which a note records.
        var turn: Int?

        /// Creates a copy.
        init(store: ThreadRecord, facts: [Fact], kinds: SubjectKinds? = nil, turn: Int? = nil) {
            self.store = store
            self.facts = facts
            self.kinds = kinds
            self.turn = turn
        }
    }

    /// The latest copy and the notes not yet taken.
    private struct State {
        /// The latest copy; nil until an agent publishes one.
        var material: Material?
        /// Notes made since the agent last took them: this turn's.
        var notes: [FactBook.Assertion] = []
    }

    /// The state, behind a lock.
    private let state = Mutex(State())

    /// A source with nothing published: `memory` answers that there is no record until an agent publishes.
    public init() {}

    /// Replaces the copy the tool reads; the notes waiting stay.
    ///
    /// - Parameters:
    ///   - store: The thread's record.
    ///   - facts: Every fact the conversation sees, in any state.
    ///   - kinds: The subject kinds, or nil when the conversation keeps no facts.
    ///   - turn: The current turn.
    func publish(store: ThreadRecord, facts: [Fact], kinds: SubjectKinds? = nil, turn: Int? = nil) {
        state.withLock { $0.material = Material(store: store, facts: facts, kinds: kinds, turn: turn) }
    }

    /// The latest copy, or nil.
    var material: Material? { state.withLock { $0.material } }

    /// Adds a note for the agent to record when the turn ends, unless the turn already has `Memory.notesPerTurn`.
    ///
    /// - Parameter note: The assertion.
    /// - Returns: Whether it was kept.
    func add(_ note: FactBook.Assertion) -> Bool {
        state.withLock { state in
            guard state.notes.count < Memory.notesPerTurn else { return false }
            state.notes.append(note)
            return true
        }
    }

    /// The notes made since the last call, oldest first, removed from the source.
    func takeNotes() -> [FactBook.Assertion] {
        state.withLock { state in
            defer { state.notes = [] }
            return state.notes
        }
    }
}

/// What the `memory` tool's one argument asks for (phase 4c of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md), as widened on 2026-09-30):
/// a verb, then its object, as the person's chat commands are written. `recall …` restores stored material
/// (`Recall`); `note SUBJECT NAME = VALUE` records a fact as the model, below the person's and a tool's (D2). A
/// request with no verb is a recall, so a model that writes only `entry 7` still gets it. Pure.
enum Memory {
    /// What a request asks for.
    enum Command: Equatable, Sendable {
        /// Restore what the rest names (`Recall.request`).
        case recall(String)
        /// Record a fact from the rest (`Memory.note`).
        case note(String)
        /// Propose the rest as the task, with its objective (`Memory.task`; phase 4d).
        case task(String)

        /// The verb, as the audit records it (`context.memory`'s `action`).
        var action: String {
            switch self {
            case .recall: "recall"
            case .note: "note"
            case .task: "task"
            }
        }
    }

    /// One note, as the model wrote it: the subject kind's name, the name under it, and the value.
    struct Note: Equatable, Sendable {
        /// The subject kind, lowercased.
        var subject: String
        /// The name under it, as written.
        var name: String
        /// The value.
        var value: String
    }

    /// At most this many notes a turn, as one distillation keeps at most `FactDistiller.maximumFacts`.
    static let notesPerTurn = FactDistiller.maximumFacts
    /// A noted value is cut to this many characters, as a distilled one is.
    static let valueCharacters = 200
    /// The example every refusal of a note repeats, so the model's next call has the shape to copy.
    static let noteExample = "note entity release codename = BLUE HERON"

    /// What `request` asks for: its first word as the verb (`recall`; `note` and its synonym `remember`; `task`), and
    /// the rest as the object; anything else is a recall of the whole text. `task` alone, with nothing after it, is a
    /// recall of the task, as it was before the verb existed. Quotes around the request are dropped.
    ///
    /// - Parameter request: The argument, as the model wrote it.
    /// - Returns: The command.
    static func command(_ request: String) -> Command {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard let match = text.firstMatch(of: #/^(?i)(recall|note|remember|task)\b[\s:=]*/#) else {
            return .recall(text)
        }
        let rest = String(text[match.range.upperBound...])
        switch match.1.lowercased() {
        case "recall": return .recall(rest)
        case "task": return rest.trimmingCharacters(in: .whitespaces).isEmpty ? .recall("task") : .task(rest)
        default: return .note(rest)
        }
    }

    /// The note in `text`: `SUBJECT NAME = VALUE`, or `SUBJECT: NAME = VALUE`, or without `=`, `SUBJECT NAME:
    /// VALUE`; the first word is the subject and the rest before the separator the name. Nil when there is no
    /// separator, no subject, or no value.
    ///
    /// - Parameter text: What follows `note`.
    /// - Returns: The note, or nil.
    static func note(_ text: String) -> Note? {
        guard let separator = text.firstIndex(of: "=") ?? text.firstIndex(of: ":") else { return nil }
        let value = text[text.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        let words = text[..<separator].split(whereSeparator: \.isWhitespace)
        guard let first = words.first, !value.isEmpty else { return nil }
        let subject = first.trimmingCharacters(in: .punctuationCharacters).lowercased()
        let name = words.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":\"'`")))
        guard !subject.isEmpty else { return nil }
        return Note(subject: subject, name: name, value: value)
    }

    /// Why a note was not kept, in words the model can act on: each says what to write instead.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        /// No `=` or `:` between what the fact is about and its value, or nothing on one side.
        case shape
        /// A subject kind the model may not note.
        case subject(String, allowed: [String])
        /// A kind that names its facts, given no name.
        case name(String)
        /// The conversation keeps no facts.
        case off
        /// The turn already has `notesPerTurn`.
        case full
        /// The person or a caller set the task, which the model never replaces (D6).
        case pinned(String)
        /// A `task` request with no task before its objective.
        case taskShape

        /// The tool's result.
        var description: String {
            switch self {
            case .shape: "error: write note SUBJECT NAME = VALUE, such as \(Memory.noteExample)"
            case .subject(let subject, let allowed):
                "error: no subject \(subject) to note; use one of \(allowed.joined(separator: ", ")), such as "
                    + Memory.noteExample
            case .name(let subject):
                "error: say which \(subject) it is before the =, such as \(Memory.noteExample)"
            case .off: "error: this conversation keeps no facts, so nothing can be noted"
            case .full: "error: at most \(Memory.notesPerTurn) notes a turn; the rest were not kept"
            case .pinned(let task): "error: the person set the task, and it stays: \(task)"
            case .taskShape: "error: write task THE TASK; objective: WHAT DONE LOOKS LIKE"
            }
        }

        /// A short name for the audit's `failure`.
        var reason: String {
            switch self {
            case .shape: "shape"
            case .subject: "subject"
            case .name: "name"
            case .off: "off"
            case .full: "full"
            case .pinned: "pinned"
            case .taskShape: "shape"
            }
        }
    }

    /// The task the model proposes with `task TEXT` (phase 4d): the text, with an objective after `objective:` (or
    /// `; objective:`) kept as the assessment writes it (`Assessor.taskValue`), as a model fact of the `task` kind,
    /// method `noted`. Refused when the person or a caller set the current task: their word is never replaced (D6).
    ///
    /// - Parameters:
    ///   - text: What follows `task`.
    ///   - material: The conversation's record and facts, as published.
    ///   - time: When.
    /// - Returns: The assertion, or the refusal.
    static func task(
        _ text: String, in material: MemorySource.Material, time: Date = Date()
    ) -> Result<FactBook.Assertion, Refusal> {
        guard let kinds = material.kinds else { return .failure(.off) }
        let current = FactView(material.facts).group(FactIdentity.Key(subject: "task", name: ""))?.winner
        if let current, current.rank >= FactSource.person.rank { return .failure(.pinned(current.value)) }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'`")))
        var task = flat
        var objective = ""
        if let match = flat.firstMatch(of: #/(?i)[;,.]?\s*objective\s*[:=-]\s*/#) {
            task = String(flat[..<match.range.lowerBound])
            objective = String(flat[match.range.upperBound...])
        }
        let value = Assessor.taskValue(task, objective: objective)
        guard !value.isEmpty, let (identity, temporalClass) = kinds.identity(subject: "task", name: "") else {
            return .failure(.taskShape)
        }
        return .success(
            FactBook.Assertion(
                identity: identity, source: .model,
                value: OutputReference.shortened(value, to: Assessor.taskCharacters),
                temporalClass: temporalClass, method: .noted, time: time, turn: material.turn))
    }

    /// The subject kinds a note may name: those the distiller may use, since the kinds tools fill (`file`,
    /// `service`, `machine`) are the tools' to record.
    ///
    /// - Parameter kinds: The kinds in force.
    /// - Returns: Their names, in order.
    static func notable(_ kinds: SubjectKinds) -> [String] { kinds.kinds.filter(\.distils).map(\.name) }

    /// The assertion `text` makes as the model, or why it makes none: the subject must be a kind the model may
    /// note, a kind that names its facts needs a name, and the value is cut to `valueCharacters`. Its temporal
    /// class is the kind's; a permanent one stays with the conversation as a proposal until the person keeps it
    /// (`Agent.record`, D2).
    ///
    /// - Parameters:
    ///   - text: What follows `note`.
    ///   - kinds: The subject kinds in force.
    ///   - turn: The turn it is noted in.
    ///   - time: When.
    /// - Returns: The assertion, or the refusal.
    static func assertion(
        _ text: String, kinds: SubjectKinds, turn: Int?, time: Date = Date()
    ) -> Result<FactBook.Assertion, Refusal> {
        guard let note = note(text) else { return .failure(.shape) }
        let allowed = notable(kinds)
        guard allowed.contains(note.subject), let kind = kinds.kind(note.subject),
            let (identity, temporalClass) = kinds.identity(subject: note.subject, name: note.name)
        else { return .failure(.subject(note.subject, allowed: allowed)) }
        guard kind.normaliser == "single" || !identity.name.isEmpty else { return .failure(.name(note.subject)) }
        return .success(
            FactBook.Assertion(
                identity: identity, source: .model,
                value: OutputReference.shortened(
                    note.value.split(whereSeparator: \.isNewline).joined(separator: " "), to: valueCharacters),
                temporalClass: temporalClass, method: .noted, time: time, turn: turn))
    }
}

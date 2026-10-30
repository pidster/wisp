import Foundation
import Synchronization

/// A simple command awaiting a human decision.
///
/// ``ApprovalGate`` builds one when a verdict is at or above its threshold and nothing held covers it, and hands it
/// to the face's ``Approver``: the terminal dialog, the MCP client's elicitation, or a file in the
/// ``PendingApprovals`` channel for another face to answer. Every face renders the same fields, each through
/// ``visible(_:)``.
public struct ApprovalRequest: Equatable, Sendable {
    /// What is being approved.
    public enum Kind: Equatable, Sendable {
        /// A command, a file read, or an edit: every scope may be chosen.
        case command
        /// A change to the models wisp can run that the model asked for through its `models` tool
        /// ([ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)): `models pull <repo>`, approved
        /// once and never remembered; `models enable|disable|check <name>`, remembered for the session at most.
        case modelAction(pull: Bool)
        /// A whole command line the model asked to run outside the sandbox (`run_command`'s `outsideSandbox`,
        /// [ADR 0064](../../../../docs/decisions/0064-an-approved-run-outside-the-sandbox.md)): asked whatever its
        /// level, approved for that one run alone, and never remembered.
        case outsideSandbox

        /// The scopes an answer may give; a wider one is narrowed to the widest of these.
        public var scopes: [ApprovalScope] {
            switch self {
            case .command: ApprovalScope.allCases
            case .modelAction(let pull): pull ? [.once] : [.once, .session]
            case .outsideSandbox: [.once]
            }
        }
    }

    /// The reason every request to run outside the sandbox carries first, so every face that shows a request's
    /// reasons (the terminal, the client's dialog, the pending file, `wisp approvals pending`, `wisp-tui`) says so.
    public static let outsideSandboxReason =
        "runs OUTSIDE the sandbox: it may write anywhere you can, ~/.wisp included; this one run only"

    /// Whether this request is to run a command outside the sandbox.
    public var outsideSandbox: Bool { kind == .outsideSandbox }

    /// The simple command being approved.
    public var command: String
    /// The whole line it is part of, for context; equal to `command` when the line is simple.
    public var line: String
    /// The key an approval is remembered under, such as `head *`.
    public var pattern: String
    /// Where it would run.
    public var workingDirectory: String
    /// Why it needs approval.
    public var assessment: RiskAssessment
    /// The conversation asking (its audit session: the MCP `thread_id`), when the gate knows it.
    public var thread: String?
    /// What is being approved, which sets the scopes an answer may give.
    public var kind: Kind

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - command: The simple command being approved.
    ///   - line: The whole line; nil when it is the command alone.
    ///   - pattern: The key an approval is remembered under.
    ///   - workingDirectory: Where it would run.
    ///   - assessment: The verdict and its reasons.
    ///   - thread: The asking conversation's id, when known.
    ///   - kind: What is being approved.
    public init(
        command: String, line: String? = nil, pattern: String, workingDirectory: String, assessment: RiskAssessment,
        thread: String? = nil, kind: Kind = .command
    ) {
        self.command = command
        self.line = line ?? command
        self.pattern = pattern
        self.workingDirectory = workingDirectory
        self.assessment = assessment
        self.thread = thread
        self.kind = kind
    }

    /// `text` as it is safe to show a person: every C0 and C1 control character and DEL (ESC, CR,
    /// backspace, a newline among them) and every bidirectional override written as an escape (`\e`, `\r`,
    /// `\n`, `\t`, or `\u{9B}`), so what a terminal or a notification shows is exactly the text the
    /// command holds.
    ///
    /// The model writes the command, so without this a command could carry escape sequences that move the cursor,
    /// clear the line, or reorder the text, and show the person something other than what would run.
    ///
    /// - Parameter text: Text from the request.
    /// - Returns: The text with every such character escaped.
    public static func visible(_ text: String) -> String {
        var shown = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1B: shown += "\\e"
            case 0x0D: shown += "\\r"
            case 0x0A: shown += "\\n"
            case 0x09: shown += "\\t"
            // The bidirectional overrides and isolates reorder what is shown as surely.
            case 0x00..<0x20, 0x7F..<0xA0, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                shown += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }
}

/// What the approver decided.
public enum ApprovalDecision: Equatable, Sendable {
    /// Run it, and remember the approval for `scope`.
    case approved(ApprovalScope)
    /// Do not run it; the reason is returned to the model.
    case denied(String)
    /// Nobody answered within the wait (`approval.timeoutSeconds`); treated as a denial, because no answer is not an
    /// answer ([ADR 0011](../../../../docs/decisions/0011-risk-classifier-and-approval.md), amended 2026-09-19).
    case unanswered(Duration)
}

/// A channel to a human (or a policy standing in for one).
///
/// Each face supplies its own through its `SessionHost`: ``TerminalApprover`` for the plain chat, ``AutoApprover``
/// under `--yes`, ``DenyingApprover`` for a non-interactive `respond`, and, under `wisp mcp`, ``OutOfBandApprover``
/// beside the client's elicitation dialog. ``ApprovalGate`` decides when to ask; the approver only answers.
/// See `docs/approval.md` and [ADR 0011](../../../../docs/decisions/0011-risk-classifier-and-approval.md).
public protocol Approver: Sendable {
    /// Whether this channel puts a request to a person. False for a policy standing in for one (`AutoApprover`,
    /// `DenyingApprover`), which the gate never lets answer a request that must be a person's: a run outside the
    /// sandbox (ADR 0064).
    var asksAPerson: Bool { get }

    /// Decides. Must not throw: a channel that fails should deny with a reason.
    ///
    /// - Parameter request: What to decide.
    /// - Returns: Approved for a scope, denied with a reason, or unanswered.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision

    /// Decides, recording what the channel itself does (a request filed, a notification posted) on the
    /// asking conversation's `audit`. The gate calls this one; the default ignores `audit`.
    ///
    /// - Parameters:
    ///   - request: What to decide.
    ///   - audit: The asking conversation's log; nil records nothing.
    /// - Returns: Approved for a scope, denied with a reason, or unanswered.
    func decide(_ request: ApprovalRequest, audit: AuditLog?) async -> ApprovalDecision
}

extension Approver {
    /// A channel asks a person unless it says otherwise.
    public var asksAPerson: Bool { true }

    /// Decides without auditing anything of its own.
    ///
    /// - Parameters:
    ///   - request: What to decide.
    ///   - audit: Ignored.
    /// - Returns: What ``decide(_:)`` returns.
    public func decide(_ request: ApprovalRequest, audit: AuditLog?) async -> ApprovalDecision {
        await decide(request)
    }
}

/// Approves everything (`--yes`).
public struct AutoApprover: Approver {
    /// Creates the approver.
    public init() {}
    /// It answers for the person, ahead of time.
    public var asksAPerson: Bool { false }
    /// Always approves, once.
    ///
    /// - Parameter request: Not read.
    /// - Returns: `.approved(.once)`.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.once) }
}

/// Denies everything with a fixed explanation, for non-interactive entry points.
public struct DenyingApprover: Approver {
    /// The reason given to the model.
    public let reason: String

    /// Creates the approver.
    ///
    /// - Parameter reason: The reason every request is denied with.
    public init(reason: String) {
        self.reason = reason
    }

    /// It stands in for a person who cannot be asked.
    public var asksAPerson: Bool { false }

    /// Always denies.
    ///
    /// - Parameter request: Not read.
    /// - Returns: `.denied` with ``reason``.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .denied(reason) }
}

/// Asks on the terminal: prints the command and reasons to stderr, reads one line from stdin.
///
/// It writes to stderr, leaving stdout for the reply, and blocks on `readLine()`, so it is for a face whose stdin is
/// the person's terminal.
public struct TerminalApprover: Approver {
    /// Styling for the dialog.
    public let style: Style

    /// Creates the approver.
    ///
    /// - Parameter style: Colours for the dialog; plain by default.
    public init(style: Style = .plain) { self.style = style }

    /// The dialog for `request`: the level and command, the whole line when it differs, each reason
    /// shortened to a line, the pattern it is remembered under, and the one-line key.
    /// Every text from the request is shown with its control characters escaped (`ApprovalRequest.visible`),
    /// so a command cannot move the cursor, clear the line, or recolour the dialog to hide what it is.
    /// Only the scopes the request's kind allows are offered.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - style: Colours for the dialog.
    /// - Returns: The dialog, ending with the prompt and no newline.
    public static func render(_ request: ApprovalRequest, style: Style) -> String {
        let visible = ApprovalRequest.visible
        var lines = [
            "",
            style.amber(request.outsideSandbox ? "⚠ approve OUTSIDE the sandbox" : "⚠ approve") + " ["
                + style.level(request.assessment.level) + "] " + style.bold(visible(request.command)),
        ]
        if request.line != request.command { lines.append(style.muted("  part of: \(visible(request.line))")) }
        lines.append(style.muted("  in \(visible(ChatStatus.abbreviated(request.workingDirectory)))"))
        for reason in request.assessment.reasons.map(visible) {
            lines.append(style.muted("  - " + (reason.count > 110 ? String(reason.prefix(110)) + "…" : reason)))
        }
        let scopes = request.kind.scopes
        lines.append(
            style.muted(scopes == [.once] ? "  never remembered" : "  remembered as: \(visible(request.pattern))"))
        let keys: [(ApprovalScope, String)] = [
            (.once, "[y]once"), (.session, "[s]ession"), (.project, "[p]roject 30d"), (.always, "[a]lways 30d"),
        ]
        let offered = keys.filter { scopes.contains($0.0) }.map(\.1) + ["[n]o"]
        lines.append("  " + offered.joined(separator: "  ") + " " + style.prompt("›") + " ")
        return lines.joined(separator: "\n")
    }

    /// Prompts and parses the answer; end of input denies.
    ///
    /// - Parameter request: What to ask about.
    /// - Returns: The parsed answer; a denial at end of input.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        FileHandle.standardError.write(Data(Self.render(request, style: style).utf8))
        guard let line = readLine() else { return .denied("no answer (end of input)") }
        return Self.parse(line)
    }

    /// Maps an answer to a decision; anything unrecognised denies, and so does an empty line, so a stray Return
    /// never approves.
    ///
    /// A scope the request's kind does not allow is narrowed by the gate, not here.
    ///
    /// - Parameter answer: The line read.
    /// - Returns: The decision.
    public static func parse(_ answer: String) -> ApprovalDecision {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y", "yes", "once": .approved(.once)
        case "s", "session": .approved(.session)
        case "p", "project": .approved(.project)
        case "a", "always": .approved(.always)
        case "n", "no", "": .denied("declined by the user")
        default: .denied("unrecognised answer '\(answer)'")
        }
    }
}

/// Session-scoped approvals shared by every gate in a process, so an answer of "this session" given
/// on one MCP thread covers the others.
///
/// `Session.begin` makes one and every thread's gate shares it. A `final class` with a `Mutex`, not an actor,
/// because each operation is a short synchronous critical section (`docs/design.md`, "Concurrency"). Nothing here
/// is persisted: the set ends with the process.
public final class SessionApprovals: Sendable {
    /// Each approved key with the highest level approved under it.
    private let keys = Mutex<[String: RiskLevel]>([:])

    /// Creates an empty set.
    public init() {}

    /// The highest level approved under `key` for the session, or nil.
    ///
    /// - Parameter key: A gate's key: the directory and a pattern, or the directory and an exact text.
    /// - Returns: The level, or nil.
    func level(for key: String) -> RiskLevel? { keys.withLock { $0[key] } }

    /// Records `key` as approved for the session at `level`, keeping a higher level approved before.
    ///
    /// - Parameters:
    ///   - key: A gate's key.
    ///   - level: The level the approval was given at.
    func insert(_ key: String, level: RiskLevel) {
        keys.withLock { $0[key] = max($0[key] ?? level, level) }
    }

    /// How many patterns are approved for the session.
    public var count: Int { keys.withLock { $0.count } }
}

/// One refusal within a turn, reported to callers so a refusal is detectable without parsing prose.
///
/// The gate collects them per turn; ``ApprovalGate/takeRefusals()`` hands them over, for `respond`'s structured
/// result.
public struct Refusal: Equatable, Sendable {
    /// The simple command that was refused.
    public var command: String
    /// Why.
    public var reason: String
}

/// Classifies a command and asks for approval when it is risky enough.
///
/// One gate per conversation. Once-approvals and refusals belong to the turn they happened in, as
/// told by the conversation's `TurnClock`; session approvals are shared through `SessionApprovals`;
/// project and always approvals live in the `ApprovalStore`. Every verdict and decision is audited
/// (`classifier.verdict`, `approval.requested`, `approval.decided`).
///
/// ``CommandRunner`` clears the model's commands here after the policy; `read_file`, `edit_file`, and the `models`
/// tool clear their own actions here too, each judged as the command it amounts to. Each simple command is judged
/// and approved on its own, so a dangerous part cannot hide behind a safe one
/// ([ADR 0015](../../../../docs/decisions/0015-per-command-approval.md)). A held approval covers a command only at
/// its own level or below, and a dangerous verdict only by an approval of the exact text, never a pattern, and is
/// never persisted beyond the session ([ADR 0014](../../../../docs/decisions/0014-persisted-approvals.md)). The order
/// of checks is in `docs/approval.md`, "The order of checks".
///
/// An actor because a decision suspends (on the classifier and the person) and the turn's state must not interleave
/// between those steps (`docs/design.md`, "Concurrency").
public actor ApprovalGate {
    /// Why a command may not run.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The approver (or a standing policy) said no; the reason is for the model.
        case refused(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .refused(let reason): "not approved: \(reason)"
            }
        }
    }

    /// From which level a human is asked.
    public let threshold: ApprovalThreshold
    /// Judges each simple command: the rules and the configured model or Core ML classifier.
    private let classifier: any RiskClassifier
    /// The face's channel to the person.
    private let approver: any Approver
    /// The conversation's log, where every verdict and decision is recorded.
    private let audit: AuditLog?
    /// Project and always approvals, kept in `~/.wisp/approvals.json`; nil keeps none.
    private let store: ApprovalStore?
    /// The face recorded on a persisted grant.
    private let source: EntryPoint?
    /// Session approvals, shared by every gate of the process.
    private let sessionApprovals: SessionApprovals
    /// The conversation's turn counter, which ends once-approvals and refusals.
    private let turns: TurnClock
    /// Per-turn state: once-approvals, each key with the highest level approved under it, and refusals,
    /// dropped when the clock moves on.
    private var turnState: (turn: Int, approved: [String: RiskLevel], refusals: [Refusal]) = (0, [:], [])

    /// The state for the current turn, discarding an earlier turn's.
    ///
    /// - Returns: The current turn's number.
    private func currentTurn() -> Int {
        let turn = turns.current
        if turnState.turn != turn { turnState = (turn, [:], []) }
        return turn
    }

    /// The persisted approval covering `segment` at `level`: under its pattern, or under the pre-verb
    /// pattern (`git *`) an older approvals file may hold, granted at `level` or above.
    ///
    /// - Parameters:
    ///   - segment: The simple command.
    ///   - directory: Where it runs, for a `project` approval.
    ///   - level: Its verdict's level.
    /// - Returns: The entry, or nil.
    private func standingApproval(
        for segment: SimpleCommand, in directory: String, level: RiskLevel
    ) async -> ApprovalStore.Entry? {
        if let entry = await store?.find(pattern: segment.pattern, directory: directory, level: level) {
            return entry
        }
        guard let legacy = segment.legacyPattern else { return nil }
        return await store?.find(pattern: legacy, directory: directory, level: level)
    }

    /// Session and turn approvals are keyed on the pattern (`head *`) in the exact directory.
    ///
    /// - Parameters:
    ///   - pattern: The approval pattern.
    ///   - workingDirectory: The directory.
    /// - Returns: The key, the two joined by a NUL, which neither can contain.
    private static func key(_ pattern: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\(pattern)"
    }

    /// The key of an approval of exactly `text` in the directory: what a dangerous verdict is remembered
    /// under, never a pattern. Marked so it can never equal a pattern's key.
    ///
    /// - Parameters:
    ///   - text: The command's exact text.
    ///   - workingDirectory: The directory.
    /// - Returns: The key.
    private static func exactKey(_ text: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\u{1}\(text)"
    }

    /// Whether an approval held in `approved` (a key to the highest level approved under it) covers
    /// `segment` judged at `level`: one of its exact text at that level or above, or, below dangerous,
    /// one of its pattern at that level or above. A moderate approval of `rm *` never covers a dangerous
    /// `rm -rf ~`; a dangerous command is covered only by an approval of the very same text.
    ///
    /// - Parameters:
    ///   - approved: Looks up the level held under a key.
    ///   - segment: The simple command.
    ///   - level: Its verdict's level.
    ///   - directory: Where it runs.
    /// - Returns: True when a held approval covers it.
    private static func covers(
        _ approved: (String) -> RiskLevel?, _ segment: SimpleCommand, at level: RiskLevel, in directory: String
    ) -> Bool {
        if let exact = approved(exactKey(segment.text, directory)), exact >= level { return true }
        guard level < .dangerous, let held = approved(key(segment.pattern, directory)) else { return false }
        return held >= level
    }

    /// The text `read_file` and the condensing tools' reads are judged as: `cat` with the path shell-quoted,
    /// and, when following links leads to a file the rules rate higher (`notes.txt` linked to `~/.ssh/id_rsa`),
    /// `# resolves to` the real path, so the credential rules see the file actually read as well as the name it
    /// was asked by. A link that changes nothing the rules see (`/var` to `/private/var`) is left out.
    ///
    /// - Parameters:
    ///   - path: The path as given.
    ///   - workingDirectory: What a relative path is relative to.
    /// - Returns: The command text.
    static func readingLine(_ path: String, workingDirectory: String) async -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: workingDirectory).appending(path: expanded).path
        let standard = URL(fileURLWithPath: absolute).standardized.path
        let real = CommandPolicy.canonical(standard)
        let line = "cat " + CommandSplitter.quoted(path)
        guard real != standard else { return line }
        let resolved = line + " # resolves to " + CommandSplitter.quoted(real)
        let rules = RuleRiskClassifier.standard
        let asGiven = await rules.classify(command: line, workingDirectory: workingDirectory).level
        let asResolved = await rules.classify(command: "cat " + CommandSplitter.quoted(real), workingDirectory: "/")
        return asResolved.level > asGiven ? resolved : line
    }

    /// Creates a gate.
    ///
    /// - Parameters:
    ///   - classifier: Produces the assessment.
    ///   - approver: Decides when the level is at or above `threshold`.
    ///   - threshold: From which level to ask; `.never` still audits verdicts.
    ///   - audit: Where verdicts and decisions are recorded.
    ///   - store: Standing approvals that outlive the process; nil keeps only session approvals.
    ///   - source: The face recorded on grants; nil (a gate outside a session) records `unknown`.
    ///   - sessionApprovals: Session-scoped approvals; share one instance across gates of one process.
    ///   - turns: The conversation's clock; defaults to the audit log's, or a clock that never
    ///     advances, under which "this turn" means the life of the gate.
    public init(
        classifier: any RiskClassifier, approver: any Approver, threshold: ApprovalThreshold, audit: AuditLog? = nil,
        store: ApprovalStore? = nil, source: EntryPoint? = nil,
        sessionApprovals: SessionApprovals = SessionApprovals(),
        turns: TurnClock? = nil
    ) {
        self.classifier = classifier
        self.approver = approver
        self.threshold = threshold
        self.audit = audit
        self.store = store
        self.source = source
        self.sessionApprovals = sessionApprovals
        self.turns = turns ?? audit?.turns ?? TurnClock()
    }

    /// Returns and clears the refusals recorded in the current turn since the last call.
    ///
    /// - Returns: The refusals, oldest first.
    public func takeRefusals() -> [Refusal] {
        _ = currentTurn()
        defer { turnState.refusals.removeAll() }
        return turnState.refusals
    }

    /// Returns normally if reading `path` is acceptable.
    ///
    /// Reads are cheap and frequent, so only the rule classifier runs, over the equivalent
    /// `cat '<path>'` with the real path beside it when a link leads to a riskier file (`readingLine`): credential
    /// paths, by either name and in any case, are rated dangerous and ask (or are refused) exactly as
    /// the command would be; ordinary files pass without a model call.
    ///
    /// - Parameters:
    ///   - path: The file as the model or caller named it.
    ///   - workingDirectory: What a relative path is relative to, and where project approvals apply.
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(readingFile path: String, workingDirectory: String) async throws {
        let line = await Self.readingLine(path, workingDirectory: workingDirectory)
        try await clear(
            parts: [SimpleCommand(text: line, executable: "cat")], line: line, workingDirectory: workingDirectory,
            classifier: RuleRiskClassifier.standard)
    }

    /// Returns normally if the model may edit the file, judged as the command `edit_file <mode> <path>`
    /// by the full classifier (rules and, when configured, the model): every edit is at least moderate
    /// and credential paths are dangerous, so the same threshold and scopes apply as to a command.
    ///
    /// - Parameters:
    ///   - path: The file.
    ///   - mode: `write`, `append`, or `replace`.
    ///   - workingDirectory: Where the conversation runs, for project-scoped approvals.
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(editingFile path: String, mode: String, workingDirectory: String) async throws {
        let line = "edit_file \(mode) \(path)"
        try await clear(
            parts: [SimpleCommand(text: line, executable: "edit_file")], line: line, workingDirectory: workingDirectory)
    }

    /// Returns normally if the command line may run, splitting it into simple commands first.
    ///
    /// - Parameters:
    ///   - line: The whole command line.
    ///   - workingDirectory: Where it would run.
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(command line: String, workingDirectory: String) async throws {
        try await clear(parts: CommandSplitter.split(line), line: line, workingDirectory: workingDirectory)
    }

    /// Returns normally if every simple command of `line` may run. `CommandRunner` splits once for
    /// the policy check and passes the parts here.
    ///
    /// - Parameters:
    ///   - parts: The line's simple commands, from `CommandSplitter.split`; empty falls back to the line.
    ///   - line: The whole line, for context in prompts and the audit log.
    ///   - workingDirectory: Where it would run.
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(parts: [SimpleCommand], line: String, workingDirectory: String) async throws {
        try await clear(parts: parts, line: line, workingDirectory: workingDirectory, classifier: classifier)
    }

    /// Returns normally if the person approves running `line` outside the sandbox, this once
    /// ([ADR 0064](../../../../docs/decisions/0064-an-approved-run-outside-the-sandbox.md)).
    ///
    /// Every simple command is judged and its verdict audited as for any line, but the person is asked whatever the
    /// verdicts and the threshold say (`never` and a command on the read-only list included), about the whole line,
    /// at `moderate` at least, with `ApprovalRequest.outsideSandboxReason` first among the reasons. Nothing held
    /// covers it: no once, session, project, or always approval, and the answer is kept for no later call, not even
    /// later in the turn; an answer wider than once is narrowed to once, and `approval.decided` records what was
    /// asked as `downgradedFrom`. A channel that asks no person (`--yes`'s `AutoApprover`, non-interactive `respond`'s
    /// `DenyingApprover`) cannot answer it, so the line is refused, saying why.
    ///
    /// - Parameters:
    ///   - parts: The line's simple commands, from `CommandSplitter.split`; empty falls back to the line.
    ///   - line: The whole line, which is what the person approves.
    ///   - workingDirectory: Where it would run.
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(outsideSandbox parts: [SimpleCommand], line: String, workingDirectory: String) async throws {
        let segments = parts.isEmpty ? [SimpleCommand(text: line, executable: line)] : parts
        var level = RiskLevel.moderate
        var reasons = [ApprovalRequest.outsideSandboxReason]
        for segment in segments {
            let assessment = await judge(
                segment, line: line, workingDirectory: workingDirectory, classifier: classifier)
            level = max(level, assessment.level)
            reasons += assessment.reasons.filter { !reasons.contains($0) }
        }
        let whole = await RuleRiskClassifier.standard.classify(command: line, workingDirectory: workingDirectory)
        level = max(level, whole.level)
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let segment = SimpleCommand(text: text, executable: text)
        func decided(_ decision: String, scope: ApprovalScope? = nil, reason: String? = nil, from: ApprovalScope? = nil)
        {
            audit?.record(
                .approvalDecided,
                details: AuditEvent.Details.approvalDecided(
                    command: text, pattern: text, line: line, decision: decision, scope: scope, reason: reason,
                    approvalID: nil, expiresAt: nil, downgradedFrom: from, persistError: nil, outsideSandbox: true))
        }
        func refuse(_ reason: String) throws -> Never {
            turnState.refusals.append(Refusal(command: text, reason: reason))
            throw Failure.refused(reason)
        }
        _ = currentTurn()
        audit?.record(
            .approvalRequested,
            details: AuditEvent.Details.approvalRequested(
                command: text, pattern: segment.pattern, line: line, level: level, outsideSandbox: true))
        guard approver.asksAPerson else {
            let reason =
                "running outside the sandbox is asked of a person every time, and no one can be asked here"
                + (approver is AutoApprover ? " (--yes does not answer it)" : "")
                + "; run it without outsideSandbox, or ask the person to run it themselves"
            decided("denied", reason: reason)
            try refuse(reason)
        }
        let decision = await approver.decide(
            ApprovalRequest(
                command: text, line: line, pattern: text, workingDirectory: workingDirectory,
                assessment: RiskAssessment(level: level, reasons: reasons, sources: ["outside-sandbox"]),
                thread: audit?.session, kind: .outsideSandbox),
            audit: audit)
        switch decision {
        case .approved(let requested):
            decided("approved", scope: .once, from: requested == .once ? nil : requested)
        case .denied(let reason):
            decided("denied", reason: reason)
            try refuse(reason)
        case .unanswered(let waited):
            let reason = "no answer within \(waited); an unanswered approval counts as declined"
            decided("timed-out", reason: reason)
            try refuse(reason)
        }
    }

    /// Clears every simple command of `line` with `classifier`: each is judged, then the whole line is rated by the
    /// rules once more, and either the line is decided as one command or each part is decided in turn.
    ///
    /// - Parameters:
    ///   - parts: The line's simple commands; empty falls back to the line.
    ///   - line: The whole line.
    ///   - workingDirectory: Where it would run.
    ///   - classifier: The classifier to judge the parts with; reads use the rules alone.
    /// - Throws: `Failure.refused`, naming the part when the line has several.
    private func clear(
        parts: [SimpleCommand], line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async throws {
        // Every simple command in the line is judged and approved on its own, so a dangerous part cannot hide
        // behind a safe first command, and approvals are remembered per pattern.
        let segments = parts.isEmpty ? [SimpleCommand(text: line, executable: line)] : parts
        var judged: [(segment: SimpleCommand, assessment: RiskAssessment)] = []
        for segment in segments {
            judged.append(
                (segment, await judge(segment, line: line, workingDirectory: workingDirectory, classifier: classifier)))
        }
        // Some signals belong to the line, not to any one part: `curl … | python3`, `env | grep TOKEN`. The rules
        // judge the whole line once more, and when they rate it above every part it is asked about as a whole,
        // remembered by its exact text, and only it: the person approving it saw every part, so its parts are
        // covered for this line rather than asked again.
        let whole = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let highest = judged.map(\.assessment.level).max() ?? .safe
        if segments.count > 1 || segments.first?.text != whole {
            let lineVerdict = await RuleRiskClassifier.standard.classify(
                command: line, workingDirectory: workingDirectory)
            if lineVerdict.level > highest, threshold.requiresApproval(at: lineVerdict.level) {
                let wholeLine = SimpleCommand(text: whole, executable: whole)
                audit?.record(
                    .classifierVerdict,
                    details: AuditEvent.Details.classifierVerdict(
                        command: whole, pattern: wholeLine.pattern, line: line, assessment: lineVerdict, seconds: 0))
                try await decide(wholeLine, assessment: lineVerdict, line: line, workingDirectory: workingDirectory)
                for (segment, assessment) in judged where threshold.requiresApproval(at: assessment.level) {
                    audit?.record(
                        .approvalDecided,
                        details: AuditEvent.Details.approvalDecided(
                            command: segment.text, pattern: segment.pattern, line: line, decision: "covered-line",
                            scope: nil, reason: nil, approvalID: nil, expiresAt: nil, downgradedFrom: nil,
                            persistError: nil))
                }
                return
            }
        }
        for (segment, assessment) in judged {
            do {
                try await decide(segment, assessment: assessment, line: line, workingDirectory: workingDirectory)
            } catch Failure.refused(let reason) where segments.count > 1 {
                throw Failure.refused("\(segment.text): \(reason)")
            }
        }
    }

    /// Classifies one simple command and records the verdict.
    ///
    /// Records a `classifier.verdict` with how long the classifier took.
    ///
    /// - Parameters:
    ///   - segment: The simple command.
    ///   - line: The whole line, for the audit.
    ///   - workingDirectory: Where it would run.
    ///   - classifier: The classifier to use.
    /// - Returns: The assessment.
    private func judge(
        _ segment: SimpleCommand, line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async -> RiskAssessment {
        let started = Date()
        let assessment = await classifier.classify(command: segment.text, workingDirectory: workingDirectory)
        audit?.record(
            .classifierVerdict,
            details: AuditEvent.Details.classifierVerdict(
                command: segment.text, pattern: segment.pattern, line: line, assessment: assessment,
                seconds: Date().timeIntervalSince(started)))
        return assessment
    }

    /// At the threshold or above, clears one judged simple command by a held approval or by asking.
    ///
    /// Checks the session's approvals, then the turn's, then (below dangerous) the store's, and asks only when none
    /// covers it. An approval is remembered at the scope answered, except that a dangerous one is held for the session
    /// at most and keyed by its exact text. A persisted grant that cannot be written still approves this run, and the
    /// error is recorded as `persistError`. Records `approval.requested` and `approval.decided`; a refusal is added to
    /// the turn's refusals.
    ///
    /// - Parameters:
    ///   - segment: The simple command.
    ///   - assessment: Its verdict.
    ///   - line: The whole line, shown for context.
    ///   - workingDirectory: Where it would run.
    /// - Throws: `Failure.refused` when it may not run.
    private func decide(
        _ segment: SimpleCommand, assessment: RiskAssessment, line: String, workingDirectory: String
    ) async throws {
        func decided(
            _ decision: String, scope: ApprovalScope? = nil, reason: String? = nil, approvalID: String? = nil,
            expiresAt: Date? = nil, downgradedFrom: ApprovalScope? = nil, persistError: String? = nil
        ) {
            audit?.record(
                .approvalDecided,
                details: AuditEvent.Details.approvalDecided(
                    command: segment.text, pattern: segment.pattern, line: line, decision: decision, scope: scope,
                    reason: reason, approvalID: approvalID, expiresAt: expiresAt, downgradedFrom: downgradedFrom,
                    persistError: persistError))
        }
        let level = assessment.level
        guard threshold.requiresApproval(at: level) else { return }
        if Self.covers(sessionApprovals.level(for:), segment, at: level, in: workingDirectory) {
            decided("cached")
            return
        }
        _ = currentTurn()
        let turnApproved = turnState.approved
        if Self.covers({ turnApproved[$0] }, segment, at: level, in: workingDirectory) {
            decided("cached-turn")
            return
        }
        if level < .dangerous, let standing = await standingApproval(for: segment, in: workingDirectory, level: level) {
            decided("cached-\(standing.scope.rawValue)", approvalID: standing.id)
            return
        }
        // A dangerous command is remembered by its exact text, anything else by its pattern at its level.
        let remembered = level == .dangerous ? segment.text : segment.pattern
        let key =
            level == .dangerous
            ? Self.exactKey(segment.text, workingDirectory) : Self.key(segment.pattern, workingDirectory)
        audit?.record(
            .approvalRequested,
            details: AuditEvent.Details.approvalRequested(
                command: segment.text, pattern: segment.pattern, line: line, level: level))
        let decision = await approver.decide(
            ApprovalRequest(
                command: segment.text, line: line, pattern: remembered, workingDirectory: workingDirectory,
                assessment: assessment, thread: audit?.session),
            audit: audit)
        switch decision {
        case .approved(let requested):
            // A dangerous command is never remembered beyond the session, whatever was chosen.
            let scope = (requested.isPersistent && level == .dangerous) ? .session : requested
            if scope == .once {
                turnState.approved[key] = max(turnState.approved[key] ?? level, level)
            } else {
                sessionApprovals.insert(key, level: level)
            }
            var approvalID: String?
            var expiresAt: Date?
            var persistError: String?
            if scope.isPersistent, let store {
                do {
                    let entry = try await store.grant(
                        pattern: segment.pattern, directory: workingDirectory, scope: scope, level: assessment.level,
                        source: source?.rawValue ?? "unknown")
                    approvalID = entry.id
                    expiresAt = entry.expiresAt
                } catch {
                    persistError = "\(error)"
                    Diagnostics.policy.error("could not persist approval: \(error)")
                }
            }
            decided(
                "approved", scope: scope, approvalID: approvalID, expiresAt: expiresAt,
                downgradedFrom: scope != requested ? requested : nil, persistError: persistError)
            return
        case .denied(let reason):
            decided("denied", reason: reason)
            turnState.refusals.append(Refusal(command: segment.text, reason: reason))
            throw Failure.refused(reason)
        case .unanswered(let waited):
            let reason = "no answer within \(waited); an unanswered approval counts as declined"
            decided("timed-out", reason: reason)
            turnState.refusals.append(Refusal(command: segment.text, reason: reason))
            throw Failure.refused(reason)
        }
    }

    /// Returns normally, with the request's id, if the model may change the models wisp can run
    /// ([ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)): judged as the command
    /// `models <verb> <subject>` by the full classifier, as `edit_file`'s edits are, and asked whatever the threshold,
    /// with `reasons` (the publisher, the licence, the download) beside the classifier's. A pull is never covered by a
    /// held approval and never remembered, so every pull is asked, and `--yes` (`AutoApprover`) refuses it rather
    /// than answering; `enable`, `disable`, and `check` are covered by an
    /// approval of their pattern for this turn or this session, and an answer wider than the session is narrowed to
    /// it. The id is recorded as `approval.decided`'s `approvalID`, and the caller records it on what the change
    /// writes, so the audit ties the two.
    ///
    /// - Parameters:
    ///   - verb: `pull`, `enable`, `disable`, or `check`.
    ///   - subject: The repository or the model.
    ///   - reasons: What the person should know, shown after the classifier's reasons.
    ///   - workingDirectory: Where the conversation runs, which keys a remembered approval.
    /// - Returns: The request's id.
    /// - Throws: `Failure.refused` with the reason when it was declined, timed out, or unanswered.
    public func clear(
        modelAction verb: String, subject: String, reasons: [String], workingDirectory: String
    ) async throws -> String {
        let line = "models \(verb) \(subject)"
        let segment = SimpleCommand(text: line, executable: "models", subcommand: verb)
        let kind = ApprovalRequest.Kind.modelAction(pull: verb == "pull")
        let id = ShortID.make()
        let started = Date()
        var assessment = await classifier.classify(command: line, workingDirectory: workingDirectory)
        assessment.reasons += reasons
        let level = max(assessment.level, .moderate)
        assessment.level = level
        func decided(_ decision: String, scope: ApprovalScope? = nil, reason: String? = nil, from: ApprovalScope? = nil)
        {
            audit?.record(
                .approvalDecided,
                details: AuditEvent.Details.approvalDecided(
                    command: line, pattern: segment.pattern, line: line, decision: decision, scope: scope,
                    reason: reason, approvalID: id, expiresAt: nil, downgradedFrom: from, persistError: nil))
        }
        audit?.record(
            .classifierVerdict,
            details: AuditEvent.Details.classifierVerdict(
                command: line, pattern: segment.pattern, line: line, assessment: assessment,
                seconds: Date().timeIntervalSince(started)))
        let key = Self.key(segment.pattern, workingDirectory)
        _ = currentTurn()
        if kind.scopes.contains(.session) {
            if Self.covers(sessionApprovals.level(for:), segment, at: level, in: workingDirectory) {
                decided("cached")
                return id
            }
            let turnApproved = turnState.approved
            if Self.covers({ turnApproved[$0] }, segment, at: level, in: workingDirectory) {
                decided("cached-turn")
                return id
            }
        }
        audit?.record(
            .approvalRequested,
            details: AuditEvent.Details.approvalRequested(
                command: line, pattern: segment.pattern, line: line, level: level))
        // `--yes` approves what was asked ahead of time; a pull is the person's to approve, each time, as it comes.
        if kind == .modelAction(pull: true), approver is AutoApprover {
            let reason = "a pull is asked of the person every time, and --yes does not answer it"
            decided("denied", reason: reason)
            turnState.refusals.append(Refusal(command: line, reason: reason))
            throw Failure.refused(reason)
        }
        let decision = await approver.decide(
            ApprovalRequest(
                command: line, line: line, pattern: segment.pattern, workingDirectory: workingDirectory,
                assessment: assessment, thread: audit?.session, kind: kind),
            audit: audit)
        switch decision {
        case .approved(let requested):
            let scope = kind.scopes.contains(requested) ? requested : kind.scopes.last ?? .once
            if kind.scopes.contains(.session) {
                if scope == .once {
                    turnState.approved[key] = max(turnState.approved[key] ?? level, level)
                } else {
                    sessionApprovals.insert(key, level: level)
                }
            }
            decided("approved", scope: scope, from: scope != requested ? requested : nil)
            return id
        case .denied(let reason):
            decided("denied", reason: reason)
            turnState.refusals.append(Refusal(command: line, reason: reason))
            throw Failure.refused(reason)
        case .unanswered(let waited):
            let reason = "no answer within \(waited); an unanswered approval counts as declined"
            decided("timed-out", reason: reason)
            turnState.refusals.append(Refusal(command: line, reason: reason))
            throw Failure.refused(reason)
        }
    }
}

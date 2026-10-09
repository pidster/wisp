import Foundation
import Synchronization

/// A simple command awaiting a human decision.
public struct ApprovalRequest: Equatable, Sendable {
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

    /// Creates a request.
    public init(
        command: String, line: String? = nil, pattern: String, workingDirectory: String, assessment: RiskAssessment,
        thread: String? = nil
    ) {
        self.command = command
        self.line = line ?? command
        self.pattern = pattern
        self.workingDirectory = workingDirectory
        self.assessment = assessment
        self.thread = thread
    }

    /// `text` as it is safe to show a person: every C0 and C1 control character and DEL (ESC, CR,
    /// backspace, a newline among them) and every bidirectional override written as an escape (`\e`, `\r`,
    /// `\n`, `\t`, or `\u{9B}`), so what a terminal or a notification shows is exactly the text the
    /// command holds.
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
    /// Nobody answered within the wait; treated as a denial, because no answer is not an answer.
    case unanswered(Duration)
}

/// A channel to a human (or a policy standing in for one).
public protocol Approver: Sendable {
    /// Decides. Must not throw: a channel that fails should deny with a reason.
    func decide(_ request: ApprovalRequest) async -> ApprovalDecision

    /// Decides, recording what the channel itself does (a request filed, a notification posted) on the
    /// asking conversation's `audit`. The gate calls this one; the default ignores `audit`.
    func decide(_ request: ApprovalRequest, audit: AuditLog?) async -> ApprovalDecision
}

extension Approver {
    /// Decides without auditing anything of its own.
    public func decide(_ request: ApprovalRequest, audit: AuditLog?) async -> ApprovalDecision {
        await decide(request)
    }
}

/// Approves everything (`--yes`).
public struct AutoApprover: Approver {
    /// Creates the approver.
    public init() {}
    /// Always approves, once.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .approved(.once) }
}

/// Denies everything with a fixed explanation, for non-interactive entry points.
public struct DenyingApprover: Approver {
    /// The reason given to the model.
    public let reason: String

    /// Creates the approver.
    public init(reason: String) {
        self.reason = reason
    }

    /// Always denies.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision { .denied(reason) }
}

/// Asks on the terminal: prints the command and reasons to stderr, reads one line from stdin.
public struct TerminalApprover: Approver {
    /// Styling for the dialog.
    public let style: Style

    /// Creates the approver.
    public init(style: Style = .plain) { self.style = style }

    /// The dialog for `request`: the level and command, the whole line when it differs, each reason
    /// shortened to a line, the pattern it is remembered under, and the one-line key.
    /// Every text from the request is shown with its control characters escaped (`ApprovalRequest.visible`),
    /// so a command cannot move the cursor, clear the line, or recolour the dialog to hide what it is.
    public static func render(_ request: ApprovalRequest, style: Style) -> String {
        let visible = ApprovalRequest.visible
        var lines = [
            "",
            style.amber("⚠ approve") + " [" + style.level(request.assessment.level) + "] "
                + style.bold(visible(request.command)),
        ]
        if request.line != request.command { lines.append(style.muted("  part of: \(visible(request.line))")) }
        lines.append(style.muted("  in \(visible(ChatStatus.abbreviated(request.workingDirectory)))"))
        for reason in request.assessment.reasons.map(visible) {
            lines.append(style.muted("  - " + (reason.count > 110 ? String(reason.prefix(110)) + "…" : reason)))
        }
        lines.append(style.muted("  remembered as: \(visible(request.pattern))"))
        lines.append("  [y]once  [s]ession  [p]roject 30d  [a]lways 30d  [n]o " + style.prompt("›") + " ")
        return lines.joined(separator: "\n")
    }

    /// Prompts and parses the answer; end of input denies.
    public func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
        FileHandle.standardError.write(Data(Self.render(request, style: style).utf8))
        guard let line = readLine() else { return .denied("no answer (end of input)") }
        return Self.parse(line)
    }

    /// Maps an answer to a decision; anything unrecognised denies.
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
public final class SessionApprovals: Sendable {
    /// Each approved key with the highest level approved under it.
    private let keys = Mutex<[String: RiskLevel]>([:])

    /// Creates an empty set.
    public init() {}

    /// The highest level approved under `key` for the session, or nil.
    func level(for key: String) -> RiskLevel? { keys.withLock { $0[key] } }

    /// Records `key` as approved for the session at `level`, keeping a higher level approved before.
    func insert(_ key: String, level: RiskLevel) {
        keys.withLock { $0[key] = max($0[key] ?? level, level) }
    }

    /// How many patterns are approved for the session.
    public var count: Int { keys.withLock { $0.count } }
}

/// One refusal within a turn, reported to callers so a refusal is detectable without parsing prose.
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
/// project and always approvals live in the `ApprovalStore`. Every verdict and decision is audited.
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
    private let classifier: any RiskClassifier
    private let approver: any Approver
    private let audit: AuditLog?
    private let store: ApprovalStore?
    private let source: EntryPoint?
    private let sessionApprovals: SessionApprovals
    private let turns: TurnClock
    /// Per-turn state: once-approvals, each key with the highest level approved under it, and refusals,
    /// dropped when the clock moves on.
    private var turnState: (turn: Int, approved: [String: RiskLevel], refusals: [Refusal]) = (0, [:], [])

    /// The state for the current turn, discarding an earlier turn's.
    private func currentTurn() -> Int {
        let turn = turns.current
        if turnState.turn != turn { turnState = (turn, [:], []) }
        return turn
    }

    /// The persisted approval covering `segment` at `level`: under its pattern, or under the pre-verb
    /// pattern (`git *`) an older approvals file may hold, granted at `level` or above.
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
    private static func key(_ pattern: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\(pattern)"
    }

    /// The key of an approval of exactly `text` in the directory: what a dangerous verdict is remembered
    /// under, never a pattern. Marked so it can never equal a pattern's key.
    private static func exactKey(_ text: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\u{1}\(text)"
    }

    /// Whether an approval held in `approved` (a key to the highest level approved under it) covers
    /// `segment` judged at `level`: one of its exact text at that level or above, or, below dangerous,
    /// one of its pattern at that level or above. A moderate approval of `rm *` never covers a dangerous
    /// `rm -rf ~`; a dangerous command is covered only by an approval of the very same text.
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

    private func clear(
        parts: [SimpleCommand], line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async throws {
        // Every simple command in the line is checked and approved on its own, so a dangerous part
        // cannot hide behind a safe first command, and approvals are remembered per pattern.
        let segments = parts.isEmpty ? [SimpleCommand(text: line, executable: line)] : parts
        var highest = RiskLevel.safe
        for segment in segments {
            do {
                let level = try await clearSegment(
                    segment, line: line, workingDirectory: workingDirectory, classifier: classifier)
                highest = max(highest, level)
            } catch Failure.refused(let reason) where segments.count > 1 {
                throw Failure.refused("\(segment.text): \(reason)")
            }
        }
        // Some signals belong to the line, not to any one part: `curl … | sh`, `env | grep TOKEN`. The rules
        // judge the whole line once more, and when they rate it above every part it is asked about as a whole,
        // remembered by its exact text.
        let whole = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard segments.count > 1 || segments.first?.text != whole else { return }
        let lineVerdict = await RuleRiskClassifier.standard.classify(command: line, workingDirectory: workingDirectory)
        guard lineVerdict.level > highest else { return }
        try await clearSegment(
            SimpleCommand(text: whole, executable: whole), line: line, workingDirectory: workingDirectory,
            classifier: RuleRiskClassifier.standard)
    }

    /// Classifies one simple command and, at the threshold or above, clears it by a held approval or by
    /// asking.
    ///
    /// - Returns: The level it was judged at.
    /// - Throws: `Failure.refused` when it may not run.
    @discardableResult
    private func clearSegment(
        _ segment: SimpleCommand, line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async throws -> RiskLevel {
        let started = Date()
        let assessment = await classifier.classify(command: segment.text, workingDirectory: workingDirectory)
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
        audit?.record(
            .classifierVerdict,
            details: AuditEvent.Details.classifierVerdict(
                command: segment.text, pattern: segment.pattern, line: line, assessment: assessment,
                seconds: Date().timeIntervalSince(started)))
        let level = assessment.level
        guard threshold.requiresApproval(at: level) else { return level }
        if Self.covers(sessionApprovals.level(for:), segment, at: level, in: workingDirectory) {
            decided("cached")
            return level
        }
        _ = currentTurn()
        let turnApproved = turnState.approved
        if Self.covers({ turnApproved[$0] }, segment, at: level, in: workingDirectory) {
            decided("cached-turn")
            return level
        }
        if level < .dangerous, let standing = await standingApproval(for: segment, in: workingDirectory, level: level) {
            decided("cached-\(standing.scope.rawValue)", approvalID: standing.id)
            return level
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
            return level
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
}

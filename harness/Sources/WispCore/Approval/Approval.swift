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
    public static func render(_ request: ApprovalRequest, style: Style) -> String {
        var lines = [
            "",
            style.amber("⚠ approve") + " [" + style.level(request.assessment.level) + "] "
                + style.bold(request.command),
        ]
        if request.line != request.command { lines.append(style.muted("  part of: \(request.line)")) }
        lines.append(style.muted("  in \(ChatStatus.abbreviated(request.workingDirectory))"))
        for reason in request.assessment.reasons {
            lines.append(style.muted("  - " + (reason.count > 110 ? String(reason.prefix(110)) + "…" : reason)))
        }
        lines.append(style.muted("  remembered as: \(request.pattern)"))
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
    private let keys = Mutex<Set<String>>([])

    /// Creates an empty set.
    public init() {}

    /// Whether `key` was approved for the session.
    func contains(_ key: String) -> Bool { keys.withLock { $0.contains(key) } }

    /// Records `key` as approved for the session.
    func insert(_ key: String) { keys.withLock { _ = $0.insert(key) } }

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
    /// Per-turn state: once-approvals and refusals, dropped when the clock moves on.
    private var turnState: (turn: Int, approved: Set<String>, refusals: [Refusal]) = (0, [], [])

    /// The state for the current turn, discarding an earlier turn's.
    private func currentTurn() -> Int {
        let turn = turns.current
        if turnState.turn != turn { turnState = (turn, [], []) }
        return turn
    }

    /// The persisted approval covering `segment`: under its pattern, or under the pre-verb pattern
    /// (`git *`) an older approvals file may hold.
    private func standingApproval(for segment: SimpleCommand, in directory: String) async -> ApprovalStore.Entry? {
        if let entry = await store?.find(pattern: segment.pattern, directory: directory) { return entry }
        guard let legacy = segment.legacyPattern else { return nil }
        return await store?.find(pattern: legacy, directory: directory)
    }

    /// Session approvals are keyed on the pattern (`head *`) in the exact directory.
    private static func key(_ pattern: String, _ workingDirectory: String) -> String {
        "\(workingDirectory)\u{0}\(pattern)"
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
    /// `cat <path>`: credential paths are rated dangerous and ask (or are refused) exactly as the
    /// command would be; ordinary files pass without a model call.
    ///
    /// - Throws: `Failure.refused` with the reason otherwise.
    public func clear(readingFile path: String, workingDirectory: String) async throws {
        let line = "cat \(path)"
        try await clear(
            parts: CommandSplitter.split(line), line: line, workingDirectory: workingDirectory,
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
        for segment in segments {
            do {
                try await clearSegment(segment, line: line, workingDirectory: workingDirectory, classifier: classifier)
            } catch Failure.refused(let reason) where segments.count > 1 {
                throw Failure.refused("\(segment.text): \(reason)")
            }
        }
    }

    private func clearSegment(
        _ segment: SimpleCommand, line: String, workingDirectory: String, classifier: any RiskClassifier
    ) async throws {
        let started = Date()
        let assessment = await classifier.classify(command: segment.text, workingDirectory: workingDirectory)
        let key = Self.key(segment.pattern, workingDirectory)
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
        guard threshold.requiresApproval(at: assessment.level) else { return }
        if sessionApprovals.contains(key) {
            decided("cached")
            return
        }
        _ = currentTurn()
        if turnState.approved.contains(key) {
            decided("cached-turn")
            return
        }
        if assessment.level < .dangerous, let standing = await standingApproval(for: segment, in: workingDirectory) {
            decided("cached-\(standing.scope.rawValue)", approvalID: standing.id)
            return
        }
        audit?.record(
            .approvalRequested,
            details: AuditEvent.Details.approvalRequested(
                command: segment.text, pattern: segment.pattern, line: line, level: assessment.level))
        let decision = await approver.decide(
            ApprovalRequest(
                command: segment.text, line: line, pattern: segment.pattern, workingDirectory: workingDirectory,
                assessment: assessment, thread: audit?.session),
            audit: audit)
        switch decision {
        case .approved(let requested):
            // A dangerous command is never remembered beyond the session, whatever was chosen.
            let scope = (requested.isPersistent && assessment.level == .dangerous) ? .session : requested
            if scope == .once {
                turnState.approved.insert(key)
            } else {
                sessionApprovals.insert(key)
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

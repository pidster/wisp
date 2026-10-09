import Foundation

/// What became of a command the person typed in chat after `!` (ADR 0049).
public struct TypedCommand: Sendable, Equatable {
    /// How it ended.
    public enum Result: Sendable, Equatable {
        /// It ran: its outcome, the store entry that tells the model of it, and whether the sandbox appears to
        /// have refused it (`SandboxRefusal`, ADR 0054).
        case ran(CommandRunner.Outcome, entry: Int, sandboxRefused: Bool)
        /// It did not run: the policy denied it, the directory was missing, or the shell could not start.
        case refused(CommandRunner.Failure)
        /// Commands cannot be typed here: the agent has no runner.
        case unavailable
    }

    /// The command line, as typed after `!`.
    public var line: String
    /// Where it ran, or would have.
    public var directory: String
    /// How it ended.
    public var result: Result
    /// The facts its output gave (`FactExtraction`, source `person`) that are in force.
    public var facts: [Fact] = []
}

extension Agent {
    /// What a command printed, as the person is shown it: stdout, then stderr, each as captured.
    ///
    /// - Parameter outcome: The command's outcome.
    /// - Returns: The text; empty when it printed nothing.
    static func printed(_ outcome: CommandRunner.Outcome) -> String {
        let parts = [outcome.stdout, outcome.stderr].filter { !$0.isEmpty }
        return parts.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
    }

    /// Runs a command the person typed in chat after `!` (ADR 0049) and tells the conversation of it. No model
    /// turn starts. The command runs through `commandRunner` as the person's (`CommandRunner.Origin.person`): the
    /// policy's deny and allow lists, the sandbox, the bounds, and the audit apply, the classifier and the
    /// approval do not. The outcome is audited as `command.typed`; a command that ran is stored as the person's
    /// command (`ThreadRecord.Kind.command`), which the next request carries as a notice with its reference, and
    /// its output gives facts as `run_command`'s does, with source `person`. A refused command is audited and not
    /// stored: it did nothing the model needs to know.
    ///
    /// - Parameters:
    ///   - line: The command line, without the `!`.
    ///   - directory: Where to run it: the conversation's working directory.
    /// - Returns: What became of it.
    nonisolated(nonsending) public func runTyped(_ line: String, in directory: String) async -> TypedCommand {
        guard let runner = commandRunner else {
            return TypedCommand(line: line, directory: directory, result: .unavailable)
        }
        let started = Date()
        let outcome: CommandRunner.Outcome
        do {
            outcome = try await runner.run(line, in: directory, origin: .person)
        } catch {
            let failure = (error as? CommandRunner.Failure) ?? .launchFailed("\(error)")
            var verdict = AuditEvent.Details.PolicyVerdict.allowed
            var reason: String?
            var why: String? = failure.description
            if case .denied(let denial) = failure {
                verdict = .denied
                reason = denial
                why = nil
            }
            audit?.record(
                .commandTyped,
                details: AuditEvent.Details.commandTyped(
                    command: line, workingDirectory: directory, verdict: verdict, reason: reason, failure: why,
                    seconds: Date().timeIntervalSince(started)))
            return TypedCommand(line: line, directory: directory, result: .refused(failure))
        }
        let shown = Self.printed(outcome)
        let refused = outcome.sandboxRefusal?.mayBeTheSandbox ?? false
        let event = audit?.record(
            .commandTyped,
            details: AuditEvent.Details.commandTyped(
                command: line, workingDirectory: directory, verdict: .allowed, outcome: outcome, output: shown,
                sandboxRefused: refused, seconds: Date().timeIntervalSince(started)))
        let now = Date()
        // The entry belongs to the turn whose first request carries it: the next one.
        let entry = store.record(
            command: ThreadRecord.PersonCommand(
                line: line, directory: directory, exitStatus: outcome.exitStatus, timedOut: outcome.timedOut,
                truncated: outcome.truncated),
            output: shown, turn: turns.current + 1, sources: event.map { [$0] } ?? [], time: now)
        let facts = recordFacts(typed: line, in: directory, outcome: outcome, event: event, entry: entry, time: now)
        return TypedCommand(
            line: line, directory: directory, result: .ran(outcome, entry: entry, sandboxRefused: refused),
            facts: facts)
    }

    /// Extracts the facts a typed command's output gives, as `run_command`'s would (`FactExtraction`), as observations
    /// ranked with a tool's and marked as the person's command (`FactExtraction.personCommandDetail`), records them, and refreshes the facts the next request carries.
    ///
    /// - Parameters:
    ///   - line: The command line.
    ///   - directory: Where it ran.
    ///   - outcome: Its outcome.
    ///   - event: The `command.typed` event, when audited.
    ///   - entry: The store entry that holds it.
    ///   - time: When it finished.
    /// - Returns: The facts recorded or changed that are in force.
    private func recordFacts(
        typed line: String, in directory: String, outcome: CommandRunner.Outcome, event: AuditReference?, entry: Int,
        time: Date
    ) -> [Fact] {
        guard let facts else { return [] }
        let call = FactExtraction.Call(
            tool: RunCommandTool().name,
            arguments: ["command": .string(line), "workingDirectory": .string(directory)], output: outcome.rendered,
            result: event, time: time)
        // What a command printed is an observation, ranked with a tool's, so a later run (the person's or the
        // model's) supersedes it; `person` is kept for what the person states (ADR 0049, refined 2026-10-09).
        let assertions = FactExtraction.assertions(
            from: [call], kinds: facts.kinds, turn: turns.current + 1,
            entries: event.map { [$0.event: entry] } ?? [:], source: .tool
        ).map { assertion in
            var observed = assertion
            observed.detail = FactExtraction.personCommandDetail
            return observed
        }
        // The ids `record` adds are cleared when the next turn begins, so that turn's note does not repeat them.
        let before = turnFactIDs.count
        for assertion in assertions { record(assertion) }
        refreshFacts()
        var seen: Set<String> = []
        return turnFactIDs.dropFirst(before).compactMap { id in
            guard seen.insert(id).inserted, let fact = fact(id), fact.state == .current else { return nil }
            return fact
        }
    }
}

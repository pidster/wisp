import Foundation
import FoundationModels
import Synchronization

/// Wraps a tool so every call and result is recorded in the audit log.
///
/// The model sees the wrapped tool unchanged: name, description, and schema
/// are forwarded. Arguments are logged as the JSON the model produced and the
/// output verbatim; a thrown error is logged and rethrown. The base tool runs with the call's audit id as
/// `ToolCallContext.call`, so what it keeps in the output store goes under that id. A call that repeats an earlier
/// call of the turn exactly (the same tool, the same arguments) is answered with a line saying so above its
/// result, so a model that asks the same question six times in a turn (session `ce87576a`, 2026-10-04) is told
/// (ADR 0050). With the conversation's plan, a result also ends with the plan's reminder to mark the task it may have
/// finished, while one is open and none was marked this turn (ADR 0081, decision 12); the audit records the result as
/// the model sees it.
public struct AuditedTool<Base: WispTool>: WispTool {
    /// Arguments are the base tool's.
    public typealias Arguments = Base.Arguments
    /// Output is the base tool's.
    public typealias Output = String

    private let base: Base
    private let audit: AuditLog
    private let ledger: CallLedger?
    private let plan: PlanBook?

    /// Wraps `base` to record into `audit`.
    ///
    /// - Parameters:
    ///   - base: The tool.
    ///   - audit: Where its calls and results go.
    ///   - ledger: The conversation's record of the turn's calls, for the repeated-call line; nil never notes one.
    ///   - plan: The conversation's plan, whose reminder ends each result; nil, or the `plan` tool itself, adds none.
    public init(_ base: Base, audit: AuditLog, ledger: CallLedger? = nil, plan: PlanBook? = nil) {
        self.base = base
        self.audit = audit
        self.ledger = ledger
        self.plan = plan
    }

    /// Forwarded from the base tool.
    public var name: String { base.name }
    /// Forwarded from the base tool.
    public var description: String { base.description }
    /// Forwarded from the base tool.
    public var parameters: GenerationSchema { base.parameters }
    /// Forwarded from the base tool.
    public var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }
    /// Forwarded from the base tool.
    public var limits: String { base.limits }
    /// Forwarded from the base tool.
    public var examplePrompt: String { base.examplePrompt }

    /// Records the call, invokes the base tool, records the result or error.
    ///
    /// - Throws: Whatever the base tool throws.
    public func call(arguments: Arguments) async throws -> String {
        let call = ShortID.make()
        let started = Date()
        let argumentsJSON = arguments.generatedContent.jsonString
        audit.record(
            .toolCall, call: call, details: AuditEvent.Details.toolCall(tool: base.name, arguments: argumentsJSON))
        Diagnostics.tools.debug("call \(call) \(base.name) \(argumentsJSON)")
        let repeats = ledger?.note(tool: base.name, arguments: argumentsJSON, turn: audit.currentTurn) ?? 1
        do {
            var output = try await ToolCallContext.$call.withValue(call) { try await base.call(arguments: arguments) }
            if repeats > 1 { output = Self.repeatedLine(tool: base.name, repeats: repeats) + "\n" + output }
            if let line = plan?.reminder() { output += "\n" + line }
            var details = AuditEvent.Details.toolResult(
                tool: base.name, output: output, seconds: Date().timeIntervalSince(started))
            if repeats > 1 { details["repeat"] = .int(repeats) }
            audit.record(.toolResult, call: call, details: details)
            return output
        } catch {
            audit.error(error, call: call, context: "tool \(base.name)")
            Diagnostics.tools.error("call \(call) \(base.name) failed: \(error)")
            throw error
        }
    }

    /// The line above a repeated call's result: a fact for the model, not a refusal, since a command run again
    /// after a change is a new command (ADR 0050).
    ///
    /// - Parameters:
    ///   - tool: The tool.
    ///   - repeats: Which call of the same this is, from 2.
    /// - Returns: The line.
    static func repeatedLine(tool: String, repeats: Int) -> String {
        let earlier = repeats - 1
        return
            "[repeated call: this is the same \(tool) call, with the same arguments, as \(earlier) earlier "
            + "call\(earlier == 1 ? "" : "s") this turn; the earlier result is already in your context]"
    }
}

/// The tool calls of the current turn, by tool and arguments, so `AuditedTool` can tell the model when it repeats
/// one exactly. Forgets everything when the turn changes. A `final class` with a `Mutex`: one short critical
/// section per call.
public final class CallLedger: Sendable {
    /// The turn the counts belong to, and the count of calls per `tool\0arguments`.
    private let state = Mutex<(turn: Int, counts: [String: Int])>((0, [:]))

    /// Creates an empty ledger.
    public init() {}

    /// Counts a call and returns which call of the same it is this turn: 1 for the first.
    ///
    /// - Parameters:
    ///   - tool: The tool.
    ///   - arguments: Its arguments, as JSON.
    ///   - turn: The current turn.
    /// - Returns: The ordinal, from 1.
    public func note(tool: String, arguments: String, turn: Int) -> Int {
        state.withLock { state in
            if state.turn != turn {
                state.turn = turn
                state.counts = [:]
            }
            let key = tool + "\0" + arguments
            let count = (state.counts[key] ?? 0) + 1
            state.counts[key] = count
            return count
        }
    }
}

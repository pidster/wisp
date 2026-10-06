import Foundation
import FoundationModels

/// What an agent's assessment carries from one request to the next (phase 4d of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)).
struct AssessmentState: Sendable, Equatable {
    /// The tools the previous turn called: a follow-up keeps them.
    var previous: Set<String> = []
    /// The tools called since the task last changed: the task's expected tools.
    var taskTools: Set<String> = []
    /// The tools registered since the task last changed, for `AssessmentSettings.ToolSets.task`.
    var grown: Set<String> = []
    /// The task fact the two sets above belong to; a new task, or a new version of it, empties them.
    var taskID: String?
    /// The facts the current request repeats next to it, by id.
    var relevant: [String] = []
}

extension Agent {
    /// The task fact's key.
    static let taskKey = FactIdentity.Key(subject: "task", name: "")

    /// Assesses the request `prompt` before it is sent (decision D12): the rules first, else one model call outside
    /// the context; then records an inferred task, sets the tools the request's session registers and the facts the
    /// now block repeats, and audits it all as `context.assessment`. A failed call falls back to every allowed tool
    /// with the task unchanged, and never fails the turn.
    ///
    /// - Parameter prompt: The person's request.
    nonisolated(nonsending) func assess(_ prompt: String) async {
        guard let settings = assessment else { return }
        let started = Date()
        let allowed = tools.map(\.name)
        let view = factView
        let task = view.group(Self.taskKey)
        resetTaskTools(for: task?.winner.id)
        let context = AssessmentRules.Context(
            allowed: allowed, previous: assessed.previous, taskTools: assessed.taskTools, hasTask: task != nil,
            taskPinned: (task?.winner.rank ?? 0) >= FactSource.person.rank,
            infersTask: settings.infersTask && facts != nil, selectsTools: settings.selectsTools,
            taskChanges: settings.taskChanges, restates: AssessmentRules.restatesTask(prompt))
        let decision = AssessmentRules.decide(prompt, context: context)
        var result = Assessment(
            method: .rules, tools: decision.tools, ruleTools: decision.tools, intent: nil, task: nil, facts: [],
            failure: nil)
        var bytes = 0
        if !decision.settled {
            let text = Assessor.prompt(
                request: prompt, catalogue: ToolCatalogue.text(tools), task: task?.winner.value,
                infersTask: context.mayChangeTask,
                facts: view.groups.reversed().map { ($0.winner.id, $0.key) },
                previous: allowed.filter(assessed.previous.contains))
            bytes = text.utf8.count
            do {
                try model.checkGuidedGeneration()
                let session = model.session(tools: [], instructions: Assessor.instructions)
                let answer = try await session.respond(
                    to: text, generating: Assessor.Answer.self,
                    options: GenerationOptions(
                        samplingMode: .greedy, maximumResponseTokens: Assessor.maximumResponseTokens)
                ).content
                result = Self.applying(answer, to: result, allowed: allowed, view: view, context: context)
            } catch {
                result.method = .fallback
                result.tools = allowed
                result.failure = "\(error)"
                Diagnostics.agent.error("assessing the request failed: \(error)")
            }
        }
        result.facts = Array(
            (result.facts + AssessmentRules.overlapping(prompt, in: view, limit: Assessor.relevantLimit))
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .prefix(Assessor.relevantLimit))
        var recordedTask: String?
        if let value = result.task, let fact = recordTask(value, method: .inferred) {
            recordedTask = fact.id
            resetTaskTools(for: fact.id)
        }
        register(result.tools, settings: settings)
        assessed.relevant = result.facts
        audit?.record(
            .assessment,
            details: AuditEvent.Details.assessment(
                method: result.method.rawValue, tools: result.tools, ruleTools: result.ruleTools,
                registered: composer.registered, intent: result.intent, task: recordedTask, facts: result.facts,
                seconds: Date().timeIntervalSince(started), bytes: bytes,
                model: bytes > 0 ? model.selection : nil, failure: result.failure))
    }

    /// `result` with the model's answer applied: its tools added to the rules' (only allowed ones: an explicit list
    /// is never widened), its intent, its task when it may change the task and differs from the current one, and
    /// its facts when they are facts in force and not already in the now block.
    ///
    /// - Parameters:
    ///   - answer: The model's answer.
    ///   - result: The rules' assessment.
    ///   - allowed: The conversation's tools.
    ///   - view: The facts in force.
    ///   - context: What the rules knew.
    /// - Returns: The assessment.
    static func applying(
        _ answer: Assessor.Answer, to result: Assessment, allowed: [String], view: FactView,
        context: AssessmentRules.Context
    ) -> Assessment {
        var result = result
        result.method = .model
        let chosen = Set(answer.tools.map { $0.trimmingCharacters(in: .whitespaces) }).union(result.ruleTools)
        result.tools = allowed.filter(chosen.contains)
        let intent = answer.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        result.intent = intent.isEmpty ? nil : OutputReference.shortened(intent, to: 200)
        if context.mayChangeTask {
            let value = Assessor.taskValue(answer.task, objective: answer.objective)
            let current = view.group(taskKey)?.winner.value ?? ""
            if !value.isEmpty, !FactView.same(value, current) {
                result.task = OutputReference.shortened(value, to: Assessor.taskCharacters)
            }
        }
        let eligible = Set(
            view.groups.filter { $0.key.subject != "task" && $0.winner.identity.scope != .session }.map(\.winner.id))
        result.facts = answer.facts.map { $0.trimmingCharacters(in: .whitespaces) }.filter(eligible.contains)
        return result
    }

    /// Records `value` as the task, from the model (`inferred` by the assessment, `noted` through `memory`), unless
    /// the person or a caller set the task: their word is never replaced (D6).
    ///
    /// - Parameters:
    ///   - value: The task, with its objective.
    ///   - method: How the model came to it.
    /// - Returns: The fact recorded, or nil when nothing was.
    @discardableResult
    func recordTask(_ value: String, method: FactMethod) -> Fact? {
        guard let facts, let (identity, temporalClass) = facts.kinds.identity(subject: "task", name: "") else {
            return nil
        }
        if let current = factView.group(Self.taskKey)?.winner, current.rank >= FactSource.person.rank { return nil }
        return record(
            FactBook.Assertion(
                identity: identity, source: .model, value: value, temporalClass: temporalClass, method: method,
                turn: turns.current))
    }

    /// Empties the task's tool sets when the task fact is not the one they belong to.
    ///
    /// - Parameter task: The current task fact's id, or nil.
    func resetTaskTools(for task: String?) {
        guard task != assessed.taskID else { return }
        assessed.taskID = task
        assessed.taskTools = []
        assessed.grown = []
    }

    /// Sets the tools the request's session registers, by the settings: every tool, the selection, or the selection
    /// grown since the task last changed.
    ///
    /// - Parameters:
    ///   - chosen: The assessment's tools.
    ///   - settings: The assessment's settings.
    func register(_ chosen: [String], settings: AssessmentSettings) {
        switch settings.tools {
        case .all:
            composer.registered = nil
        case .request:
            composer.registered = chosen
        case .task:
            assessed.grown.formUnion(chosen)
            composer.registered = tools.map(\.name).filter(assessed.grown.contains)
        }
    }

    /// Remembers the tools a turn called, for the next request's rules: a follow-up keeps them, and the task expects
    /// them.
    ///
    /// - Parameter added: The entries the turn added.
    func noteCalls(in added: [Transcript.Entry]) {
        guard assessment != nil else { return }
        let called = Set(
            added.flatMap { entry -> [String] in
                if case .toolCalls(let calls) = entry { calls.map(\.toolName) } else { [] }
            })
        assessed.previous = called
        assessed.taskTools.formUnion(called)
    }

    /// `frame` with the request's own lines at the end of the now block (D7 and D4): the facts the assessment found
    /// relevant, repeated, and the tools registered for the request. Unchanged without an assessment.
    ///
    /// - Parameters:
    ///   - frame: The facts frame.
    ///   - view: The facts in force; nil when the conversation keeps none.
    /// - Returns: The frame.
    func requestNotes(_ frame: FactFrame, view: FactView?) -> FactFrame {
        guard let settings = assessment else { return frame }
        var lines: [String] = []
        if let view {
            let groups = assessed.relevant.compactMap { id in view.groups.first { $0.winner.id == id } }
            if !groups.isEmpty {
                lines.append("Relevant to this request:")
                lines += groups.map(FactComposition.line)
            }
        }
        if settings.selectsTools, let registered = composer.registered {
            lines.append(
                "Tools for this request: " + (registered.isEmpty ? "none" : registered.joined(separator: ", ")) + ".")
        }
        return frame.addingNow(lines)
    }

    /// Runs `operation`; when the model called a tool the request had not registered, which the framework refuses
    /// before any tool runs, registers every allowed tool and retries once on a fresh session, as the overflow
    /// recovery does. The retry is audited as a `context.assessment` with method `retry`, so the eval counts how
    /// often a selection missed (D4).
    nonisolated(nonsending) func withToolRecovery<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard let settings = assessment, let before = composer.registered, Self.unregisteredTool(in: error)
            else { throw error }
            let allowed = tools.map(\.name)
            composer.registered = nil
            if settings.tools == .task { assessed.grown = Set(allowed) }
            audit?.record(
                .assessment,
                details: AuditEvent.Details.assessment(
                    method: Assessment.Method.retry.rawValue, tools: allowed, ruleTools: before, registered: nil,
                    intent: nil, task: nil, facts: assessed.relevant, seconds: 0, bytes: 0, model: nil,
                    failure: "the model called a tool not registered for the request"))
            Diagnostics.agent.info("retrying with every tool: the model called one not registered")
            refreshFacts()
            materialise(fresh: true)
            return try await operation()
        }
    }

    /// Whether `error` is the framework's refusal of a tool call whose name the session does not register: on macOS
    /// 27 a parsing error reading "Model generated a tool call with an unrecognized name" (probed 2026-10-01 with a
    /// scripted model, for the framework's tool loop that every backend shares).
    static func unregisteredTool(in error: any Error) -> Bool {
        String(describing: error).contains("tool call with an unrecognized name")
    }
}

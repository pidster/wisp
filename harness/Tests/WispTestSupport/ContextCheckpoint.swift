import Foundation
import FoundationModels
import WispCore

/// One model switch: before turn `turn` (1-based, questions counted), the conversation moves to `model`.
public struct ModelSwitch: Sendable {
    /// The turn that is the first on the new model.
    public var turn: Int
    /// The model it moves to.
    public var model: ResolvedModel

    /// Creates a switch.
    public init(turn: Int, model: ResolvedModel) {
        self.turn = turn
        self.model = model
    }
}

/// A model switch mid-conversation (decision D10 of the layered-context proposal): the conversation opens on one
/// model through `base`, and before the turns `switches` names it continues on another, as chat's `/model` does: a new
/// agent over the same store (facts, the running summary, references, dropped turns), the same tools and `memory`
/// source, and the same settings, which composes from the store for its own window.
public struct SwitchingStrategy<Base: ContextStrategy>: ContextStrategy {
    /// The strategy the conversation opens with, and keeps across switches.
    public var base: Base
    /// The switches, in turn order.
    public var switches: [ModelSwitch]

    /// The base's name, then `-switched`.
    public var name: String { base.name + "-switched" }
    /// What it does.
    public var summary: String {
        base.summary + "; the model switched before turn"
            + (switches.count == 1 ? " " : "s ")
            + switches.map { "\($0.turn) (\($0.model.selection))" }
            .joined(separator: ", ")
    }
    /// The base's.
    public var linksToolEvents: Bool { base.linksToolEvents }
    /// The base's.
    public var hasMemory: Bool { base.hasMemory }

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - base: The strategy the conversation opens with.
    ///   - switches: Where the model changes, and to what.
    public init(base: Base, switches: [ModelSwitch]) {
        self.base = base
        self.switches = switches.sorted { $0.turn < $1.turn }
    }

    /// Opens the base's conversation and wraps it, so the switches happen as the turns arrive. A base that does not
    /// run on an `AgentThread` cannot switch, and is returned as it is.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let thread = base.open(model: model, tools: tools, instructions: instructions, audit: audit)
        guard let agentThread = thread as? AgentThread else { return thread }
        return SwitchingThread(agentThread.agent, switches: switches.map { ($0.turn, $0.model) })
    }
}

/// A conversation whose agent is replaced by one on another model before given turns (`SwitchingStrategy`).
public final class SwitchingThread: ContextThread, AgentHolding {
    /// The agent the next turn goes to.
    public private(set) var agent: Agent
    /// The switches still to come, in turn order.
    private var pending: [(turn: Int, model: ResolvedModel)]
    /// Turns sent so far.
    private var sent = 0
    /// Each switch made, in words: the turn, the models and windows, and what the store carried.
    public private(set) var log: [String] = []

    /// Wraps an agent.
    ///
    /// - Parameters:
    ///   - agent: The agent the conversation opens with.
    ///   - switches: Before which turn the conversation moves to which model.
    public init(_ agent: Agent, switches: [(turn: Int, model: ResolvedModel)]) {
        self.agent = agent
        pending = switches
    }

    /// Switches when this turn is the next switch's, then sends the turn to the agent.
    nonisolated(nonsending) public func send(_ prompt: String) async throws -> String {
        sent += 1
        while let next = pending.first, next.turn <= sent {
            pending.removeFirst()
            let old = agent
            agent = Self.continuing(old, on: next.model)
            log.append(
                "turn \(sent): \(old.model.selection) (window \(old.contextSize.map(String.init) ?? "unknown")) to "
                    + "\(next.model.selection) (window \(agent.contextSize.map(String.init) ?? "unknown")), carrying "
                    + "\(old.store.facts.current.count) facts"
                    + (old.store.summary.map { ", summary v\($0.version) of \($0.covered) turns" } ?? ", no summary"))
        }
        return try await agent.respond(to: prompt).text
    }

    /// `Agent.contextTokens()` of the current agent, nil when it cannot tell or counting fails.
    nonisolated(nonsending) public func occupiedTokens() async -> Int? {
        (try? await agent.contextTokens()) ?? nil
    }

    /// A new agent on `model` that continues `old`'s store with its tools, policy, audit, turn clock, and every
    /// setting a strategy gives an agent, as `WispThread.openAgent` does for chat's `/model` from the config.
    ///
    /// - Parameters:
    ///   - old: The agent being replaced.
    ///   - model: The model to continue on.
    /// - Returns: The new agent.
    public static func continuing(_ old: Agent, on model: ResolvedModel) -> Agent {
        let agent = Agent(
            store: old.store, tools: old.tools, model: model, contextPolicy: old.contextPolicy, audit: old.audit,
            turns: old.turns)
        agent.contextBudget = old.contextBudget
        agent.cutsPresentation = old.cutsPresentation
        agent.referencesOutput = old.referencesOutput
        agent.factsShare = old.factsShare
        agent.summarises = old.summarises
        agent.summaryShare = old.summaryShare
        agent.summaryBatchTurns = old.summaryBatchTurns
        agent.facts = old.facts
        agent.memory = old.memory
        agent.toolEvents = old.toolEvents
        agent.assessment = old.assessment
        return agent
    }
}

/// Context checkpoint 2 (docs/proposals/2026-10-06-context-checkpoint-2.md): which parts to run, the grid of targets
/// and headrooms, the window, how many runs of each cell, and the model switches, read from the environment so one
/// command runs it (`scripts/check eval checkpoint`). Pure, so the gate tests the parsing and the cells; the eval
/// package's `ContextCheckpointTests` runs them on real models.
public struct ContextCheckpoint: Sendable, Equatable {
    /// A part of the checkpoint: a question of the plan.
    public enum Part: String, Sendable, Equatable, CaseIterable {
        /// The target and headroom grid on the sustained scenario at the default budget (question 1).
        case grid
        /// The 50% variants again on the recalling scenario, under the guard (question 2).
        case half
        /// The model switch mid-conversation (question 3).
        case switches = "switch"
        /// The sustained scenario with `memory` and without (question 4).
        case memory
        /// The assessment off, as built, and changing the task only when restated (question 5).
        case assessment
    }

    /// A model of a switch plan, with the window it runs at when not the checkpoint's.
    public struct Leg: Sendable, Equatable {
        /// The model.
        public var model: ModelSelection
        /// Its window, in tokens; nil takes the checkpoint's.
        public var window: Int?

        /// Creates a leg.
        public init(model: ModelSelection, window: Int? = nil) {
            self.model = model
            self.window = window
        }

        /// The leg as it is spelled: the model, then `@window` when one is given.
        public var spelling: String { "\(model)" + (window.map { "@\($0)" } ?? "") }
    }

    /// Why the environment does not describe a checkpoint.
    public struct Failure: Error, CustomStringConvertible, Equatable {
        /// What was wrong, naming the variable.
        public var description: String
    }

    /// The parts to run, in `Part`'s order.
    public var parts: [Part]
    /// The targets the grid tries, as shares of the window.
    public var targets: [Double]
    /// The headrooms the grid tries, in turns.
    public var headrooms: [Int]
    /// The window every model runs at, unless a switch leg says otherwise.
    public var window: Int
    /// How many times each cell runs.
    public var runs: Int
    /// The switch plans: each a list of two or three legs.
    public var switchPlans: [[Leg]]

    /// The variable that turns the checkpoint on and names its parts (`all`, or a comma-separated list of parts).
    public static let partsVariable = "WISP_CHECKPOINT"
    /// The targets, comma-separated shares.
    public static let targetsVariable = "WISP_CHECKPOINT_TARGETS"
    /// The headrooms, comma-separated turn counts.
    public static let headroomsVariable = "WISP_CHECKPOINT_HEADROOMS"
    /// The window, in tokens.
    public static let windowVariable = "WISP_CHECKPOINT_WINDOW"
    /// Runs of each cell.
    public static let runsVariable = "WISP_CHECKPOINT_RUNS"
    /// The switch plans: `;` between plans, `>` between legs, `@N` after a model for its window.
    public static let switchesVariable = "WISP_CHECKPOINT_SWITCHES"

    /// The grid's targets by default: the default, and a tenth either side (ADR 0045's open item).
    public static let defaultTargets = [0.4, 0.5, 0.6]
    /// The grid's headrooms by default: none (phase 2's trigger), the last turn (D5's floor), and the default eight.
    public static let defaultHeadrooms = [0, 1, 8]
    /// The window by default: the on-device model's.
    public static let defaultWindow = 8192
    /// The switch plans by default: on-device to granite and back, with the same window; and granite at a window
    /// that holds the whole conversation to the on-device model, whose window it does not fit.
    public static let defaultSwitches = "system>ollama:granite4.1:8b>system;ollama:granite4.1:8b@32768>system"

    /// Creates a checkpoint description.
    public init(
        parts: [Part] = Part.allCases, targets: [Double] = defaultTargets, headrooms: [Int] = defaultHeadrooms,
        window: Int = defaultWindow, runs: Int = 1, switchPlans: [[Leg]] = []
    ) {
        self.parts = parts
        self.targets = targets
        self.headrooms = headrooms
        self.window = window
        self.runs = runs
        self.switchPlans = switchPlans
    }

    /// The checkpoint `environment` describes, or nil when `WISP_CHECKPOINT` is unset or empty.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: The checkpoint.
    /// - Throws: `Failure` naming the variable that does not parse.
    public static func parse(_ environment: [String: String]) throws -> ContextCheckpoint? {
        let named = list(environment[partsVariable])
        guard !named.isEmpty else { return nil }
        var parts: Set<Part> = []
        for name in named {
            if name == "all" {
                parts.formUnion(Part.allCases)
            } else if let part = Part(rawValue: name) {
                parts.insert(part)
            } else {
                throw Failure(
                    description: "\(partsVariable): unknown part \(name); use all or "
                        + Part.allCases.map(\.rawValue).joined(separator: ", "))
            }
        }
        let targets = try list(environment[targetsVariable]).map { text in
            guard let value = Double(text), value > 0, value < 1 else {
                throw Failure(description: "\(targetsVariable): \(text) is not a share between 0 and 1")
            }
            return value
        }
        let headrooms = try list(environment[headroomsVariable]).map { text in
            guard let value = Int(text), value >= 0 else {
                throw Failure(description: "\(headroomsVariable): \(text) is not a number of turns")
            }
            return value
        }
        let window = try number(environment[windowVariable], defaultWindow, windowVariable, minimum: 1024)
        let runs = try number(environment[runsVariable], 1, runsVariable, minimum: 1)
        let plans = try (environment[switchesVariable].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSwitches)
            .split(separator: ";").map { plan in
                let legs = try plan.split(separator: ">").map { try leg(String($0)) }
                guard (2...3).contains(legs.count) else {
                    throw Failure(description: "\(switchesVariable): \(plan) needs two or three models")
                }
                return legs
            }
        return ContextCheckpoint(
            parts: Part.allCases.filter(parts.contains), targets: targets.isEmpty ? defaultTargets : targets,
            headrooms: headrooms.isEmpty ? defaultHeadrooms : headrooms, window: window, runs: runs,
            switchPlans: plans)
    }

    /// The comma-separated items of `text`, trimmed, without empty ones.
    static func list(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// `text` as a whole number of at least `minimum`, or `fallback` when unset.
    static func number(_ text: String?, _ fallback: Int, _ variable: String, minimum: Int) throws -> Int {
        guard let text, !text.isEmpty else { return fallback }
        guard let value = Int(text), value >= minimum else {
            throw Failure(description: "\(variable): \(text) is not a whole number of at least \(minimum)")
        }
        return value
    }

    /// One leg of a switch plan: a model spelling, then `@N` for its window.
    static func leg(_ text: String) throws -> Leg {
        let text = text.trimmingCharacters(in: .whitespaces)
        var spelling = text
        var window: Int?
        if let at = text.lastIndex(of: "@"), let value = Int(text[text.index(after: at)...]), value >= 1024 {
            spelling = String(text[..<at])
            window = value
        }
        guard let model = try? ModelSelection(parsing: spelling) else {
            throw Failure(description: "\(switchesVariable): \(text) is not a model")
        }
        return Leg(model: model, window: window)
    }

    /// One run of one way of managing the context on one scenario: a cell of the checkpoint's table.
    public struct Cell: Sendable {
        /// The part it answers.
        public var part: Part
        /// Its name in the table and the measurement's variant: `t50-h8`, `half-stack`, `memory-off`, ….
        public var label: String
        /// The conversation.
        public var scenario: ContextEval.Scenario
        /// How the context is managed.
        public var strategy: any ContextStrategy
        /// Whether every built-in tool is offered, rather than `read_file` alone.
        public var allTools: Bool

        /// Creates a cell.
        public init(
            part: Part, label: String, scenario: ContextEval.Scenario, strategy: any ContextStrategy,
            allTools: Bool = false
        ) {
            self.part = part
            self.label = label
            self.scenario = scenario
            self.strategy = strategy
            self.allTools = allTools
        }
    }

    /// The grid's label for a target and a headroom: `t50-h8`.
    public static func gridLabel(target: Double, headroom: Int) -> String {
        "t\(Int((target * 100).rounded()))-h\(headroom)"
    }

    /// The whole default stack at the default budget with `target`: memory, facts, the summary, references, and
    /// condensing to it.
    static func stack(_ target: ContextTarget = .default) -> MemoryStrategy {
        MemoryStrategy(policy: .target(target))
    }

    /// The cells of `part` that run on each model; empty for the switches, whose cells need resolved models
    /// (`switchCell`).
    ///
    /// - Parameter part: The part.
    /// - Returns: The cells, in the order they run.
    public func cells(_ part: Part) -> [Cell] {
        let sustained = ContextEval.sustained()
        switch part {
        case .grid:
            return targets.flatMap { target in
                headrooms.map { headroom in
                    Cell(
                        part: .grid, label: Self.gridLabel(target: target, headroom: headroom), scenario: sustained,
                        strategy: Self.stack(ContextTarget(share: target, headroomTurns: headroom)))
                }
            }
        case .half:
            let recalling = ContextEval.recalling()
            return [
                Cell(
                    part: .half, label: "half-stack", scenario: recalling,
                    strategy: MemoryStrategy(budget: 0.5, policy: .default)),
                Cell(
                    part: .half, label: "half-no-memory", scenario: recalling,
                    strategy: SummaryStrategy(together: true, budget: 0.5, policy: .default)),
                Cell(part: .half, label: "half-fixed", scenario: recalling, strategy: MemoryStrategy(budget: 0.5)),
                Cell(part: .half, label: "half-dropping", scenario: recalling, strategy: DroppingStrategy(budget: 0.5)),
            ]
        case .memory:
            let target = ContextTarget.default
            return [
                Cell(
                    part: .memory, label: Self.gridLabel(target: target.share, headroom: target.headroomTurns),
                    scenario: sustained, strategy: Self.stack()),
                Cell(
                    part: .memory, label: "memory-off", scenario: sustained,
                    strategy: SummaryStrategy(together: true, policy: .default)),
            ]
        case .assessment:
            return [
                Cell(
                    part: .assessment, label: "assess-off", scenario: sustained, strategy: Self.stack(), allTools: true),
                Cell(
                    part: .assessment, label: "assess-any", scenario: sustained,
                    strategy: AssessingStrategy(tools: .request, policy: .default), allTools: true),
                Cell(
                    part: .assessment, label: "assess-restated", scenario: sustained,
                    strategy: AssessingStrategy(tools: .request, taskChanges: .restated, policy: .default),
                    allTools: true),
            ]
        case .switches:
            return []
        }
    }

    /// The turns before which a switch plan's second and third models take over in the sustained scenario: the
    /// return to the task, then the first question.
    public static var switchTurns: [Int] {
        let scenario = ContextEval.sustained()
        let back = (scenario.steps.firstIndex { $0.prompt.hasPrefix("Back to the task") } ?? 0) + 1
        return [back, scenario.steps.count + 1]
    }

    /// The cell for a switch plan whose legs are resolved: the default stack on the sustained scenario, opening on
    /// the first model and moving to the next at each of `switchTurns`.
    ///
    /// - Parameters:
    ///   - legs: The plan, as spelled.
    ///   - models: Its models, resolved, in the same order.
    /// - Returns: The cell.
    public static func switchCell(_ legs: [Leg], models: [ResolvedModel]) -> Cell {
        let switches = zip(switchTurns, models.dropFirst()).map { ModelSwitch(turn: $0, model: $1) }
        return Cell(
            part: .switches, label: "switch " + legs.map(\.spelling).joined(separator: ">"),
            scenario: ContextEval.sustained(), strategy: SwitchingStrategy(base: stack(), switches: switches))
    }

    /// The header of `row`'s fields, tab-separated, for the saved table.
    public static let rowHeader = [
        "model", "part", "cell", "run", "passed", "total", "facts", "details", "task", "first file", "condensations",
        "floors", "turns between", "fill median", "tokens median", "tokens max", "turn p50 s", "turn p95 s",
        "distillations", "distilling s", "memory calls", "task changes", "assessment calls", "verdicts", "switches",
        "load",
    ].joined(separator: "\t")

    /// One run as the line `scripts/check eval checkpoint` gathers into its table and saves: `checkpoint row`, then
    /// `rowHeader`'s fields, tab-separated.
    ///
    /// - Parameters:
    ///   - run: The run.
    ///   - model: The model it opened on, as the table's row.
    ///   - cell: The cell it ran.
    ///   - number: Which run of the cell, from 1.
    /// - Returns: The line.
    public static func row(_ run: ContextEval.Run, model: ModelSelection, cell: Cell, number: Int) -> String {
        let facts = run.correct([.fact, .changedFact, .noted])
        let details = run.correct([.detail])
        let verdict = { (probe: ContextEval.Probe) in
            run.answers.first { $0.question.probe == probe }?.verdict.rawValue ?? "-"
        }
        let seconds = { (fraction: Double) in
            String(format: "%.1f", (ContextEval.percentile(run.milliseconds, fraction) ?? 0) / 1000)
        }
        let fill = ContextEval.percentile(run.fills.map(Double.init), 0.5).map { String(Int($0)) } ?? "-"
        let tokens = ContextEval.percentile(run.tokens.map(Double.init), 0.5).map { String(Int($0)) } ?? "-"
        let fields: [String] = [
            "\(model)", cell.part.rawValue, cell.label, "\(number)",
            "\(run.answers.filter { $0.verdict == .correct }.count)", "\(run.answers.count)",
            "\(facts.correct)/\(facts.total)", "\(details.correct)/\(details.total)", verdict(.task), verdict(.order),
            "\(run.condensations)", "\(run.floors)",
            run.condensationGaps.isEmpty ? "-" : run.condensationGaps.map(String.init).joined(separator: ","), fill,
            tokens, run.tokens.max().map(String.init) ?? "-", seconds(0.5), seconds(0.95), "\(run.distillations.count)",
            String(format: "%.0f", run.distillations.reduce(0, +)), "\(run.memoryCalls.count)", "\(run.taskChanges)",
            "\(run.assessmentCalls)",
            run.answers.map { "\($0.question.id)=\($0.verdict.rawValue)" }.joined(separator: " "),
            run.switches.isEmpty ? "-" : run.switches.joined(separator: "; "),
            String(format: "%.0f-%.0f", run.load.start, run.load.end),
        ]
        return (["checkpoint row"] + fields.map { $0.replacingOccurrences(of: "\t", with: " ") })
            .joined(separator: "\t")
    }
}

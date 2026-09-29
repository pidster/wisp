import Foundation
import FoundationModels
import WispCore

/// The context eval: one scripted conversation that plants facts and a task, fills the window with file
/// reads and a long digression, then asks for each fact, for the first file read, and for the task
/// (docs/proposals/2026-09-29-layered-context.md, "Evaluation"). Everything here runs without a model,
/// so the scenario, the scoring, and the runner are tested in the gate; `ContextEvalTests` in
/// `ModelEvalTests` drives it on real models.
///
/// A `ContextStrategy` is the seam later designs plug into: each one opens a conversation over the same
/// model, tools, and instructions, and the same scenario runs through it. `DroppingStrategy` is the
/// baseline: an `Agent` whose `ContextComposer` composes literal turns only, as phase 2 of the proposal
/// built it to reproduce what came before. `CuttingStrategy` adds phase 3's output handling, and
/// `showing()` is the scenario that gives it presentational text to cut.
public enum ContextEval {
    /// One scripted user turn before the questions.
    public struct Step: Sendable, Equatable {
        /// What the turn does to the conversation.
        public enum Kind: String, Sendable, Equatable {
            /// States a fact or the task.
            case plant
            /// Reads a file for the task.
            case read
            /// Reads a file away from the task.
            case digression
            /// Reads a file and changes a fact planted earlier.
            case change
            /// Reads a file and asks to be shown its contents, so the reply is presentational text.
            case show
        }

        /// What the turn does.
        public var kind: Kind
        /// The prompt, verbatim.
        public var prompt: String
        /// The fixture the prompt asks to read, by file name; nil when it reads none.
        public var file: String?

        /// Creates a step.
        public init(kind: Kind, prompt: String, file: String? = nil) {
            self.kind = kind
            self.prompt = prompt
            self.file = file
        }
    }

    /// How a reply is scored, on its normalised text (`ContextEval.normalised`).
    public enum Check: Sendable, Equatable {
        /// Correct when the reply contains any one of these phrases.
        case mentions([String])
        /// Correct when the reply names the current value (any `current` phrase), even beside the old one;
        /// stale when it names only the old value (a `stale` phrase and no `current` one); wrong otherwise.
        case currentValue(current: [String], stale: [String])
    }

    /// The outcome of one scored reply.
    public enum Verdict: String, Sendable, Equatable {
        /// The reply carries the expected answer.
        case correct
        /// The reply carries a value the conversation later replaced.
        case stale
        /// Anything else, including "I don't know".
        case wrong
    }

    /// What a question probes, so results group the way the proposal scores them.
    public enum Probe: String, Sendable, Equatable {
        /// A fact planted once.
        case fact
        /// A fact whose value changed later in the conversation (D2).
        case changedFact
        /// What came first in the conversation.
        case order
        /// A return to the task stated at the start.
        case task
    }

    /// A question asked once the window has been filled.
    public struct Question: Sendable, Equatable {
        /// A short stable name, such as `codename`.
        public var id: String
        /// What the question probes.
        public var probe: Probe
        /// The prompt, verbatim.
        public var prompt: String
        /// How the reply is scored.
        public var check: Check

        /// Creates a question.
        public init(id: String, probe: Probe, prompt: String, check: Check) {
            self.id = id
            self.probe = probe
            self.prompt = prompt
            self.check = check
        }

        /// Scores a reply.
        public func score(_ reply: String) -> Verdict { ContextEval.score(reply, check) }
    }

    /// A conversation to run: the turns in order, then the questions.
    public struct Scenario: Sendable, Equatable {
        /// A short name for reports.
        public var name: String
        /// Where the fixtures are.
        public var fixtures: URL
        /// The turns before the questions.
        public var steps: [Step]
        /// The questions, asked in order after the steps.
        public var questions: [Question]
        /// What the conversation does, for a measurement's notes.
        public var summary: String

        /// Creates a scenario.
        public init(
            name: String, fixtures: URL, steps: [Step], questions: [Question],
            summary: String = ContextEval.baselineSummary
        ) {
            self.name = name
            self.fixtures = fixtures
            self.steps = steps
            self.questions = questions
            self.summary = summary
        }

        /// The fixtures the steps read, in order.
        public var files: [String] { steps.compactMap(\.file) }
    }

    /// `Tests/ModelEvalTests/Fixtures/context`, found from this source file's place in the repository.
    public static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ModelEvalTests/Fixtures/context")
    }

    /// The on-task files, read in this order after the task is stated.
    static let taskFiles = ["harbour-sync-overview.md", "harbour-sync-flags.md", "SyncCommand.swift"]
    /// The digression: ten incident reviews from an unrelated shop, read in this order.
    static let digressionFiles = [
        "postmortem-01-queue-backlog.md", "postmortem-02-dns-expiry.md", "postmortem-03-clock-skew.md",
        "postmortem-04-cache-stampede.md", "postmortem-05-disk-full.md", "postmortem-06-cert-rotation.md",
        "postmortem-07-retry-storm.md", "postmortem-08-migration-lock.md", "postmortem-09-config-typo.md",
        "postmortem-10-leap-day.md",
    ]
    /// The digression read whose turn also changes the CI fact, so the change sits mid-digression.
    static let changeAt = 5
    /// The file the showing scenario asks to be shown: a short configuration file the model can retype.
    static let shownFile = "harbour.toml"
    /// The baseline scenario's description, for a measurement's notes.
    public static let baselineSummary =
        "four facts and a task planted, 13 file reads including a ten-file digression, a fact changed midway"

    /// The baseline scenario with one more step after the task files: read a short configuration file and
    /// show it in full. A model asked to show a file retypes it, so that reply is presentational text,
    /// which the cutting strategy cuts from later requests and dropping keeps until its turn is dropped.
    /// The questions are the baseline's.
    ///
    /// - Parameter fixtures: Where the fixture files are; defaults to the repository's.
    /// - Returns: The scenario.
    public static func showing(fixtures: URL = fixturesDirectory) -> Scenario {
        var scenario = baseline(fixtures: fixtures)
        scenario.name = "showing"
        scenario.summary =
            "four facts and a task planted, 13 file reads including a ten-file digression, a fact changed midway, "
            + "and one file shown in full after the task files"
        let at = 1 + taskFiles.count
        scenario.steps.insert(
            Step(
                kind: .show,
                prompt: "Use read_file to read \(fixtures.appending(path: shownFile).path) and show me its full "
                    + "contents exactly as they are, in a code block.",
                file: shownFile),
            at: at)
        return scenario
    }

    /// The baseline scenario: the task and four facts planted over the first four turns (a codename, the
    /// CI state, a reviewer's preference, a ticket number), the three task files read, ten unrelated
    /// incident reviews read as a digression with the CI state changing halfway through, then six
    /// questions. Each read is one `read_file` page of about 3.6 KB, about 1,200 tokens with its summary, so
    /// the whole conversation comes to about 16,000 tokens (granite's count, nothing dropped), two
    /// on-device windows; on 2026-09-29 the on-device model passed the 85% budget at the seventh turn.
    ///
    /// - Parameter fixtures: Where the fixture files are; defaults to the repository's.
    /// - Returns: The scenario.
    public static func baseline(fixtures: URL = fixturesDirectory) -> Scenario {
        let path = { (name: String) in fixtures.appending(path: name).path }
        let summarise = "Summarise it in two sentences."
        var steps = [
            Step(
                kind: .plant,
                prompt: "We're working on harbour, a small command-line file-sync tool written in Swift. Today's "
                    + "task: add a --dry-run flag to `harbour sync` that lists what would be copied, updated, or "
                    + "deleted without changing anything. The codename for this release is BLUE HERON. Reply in "
                    + "one sentence to confirm."),
            Step(
                kind: .read,
                prompt: "For context, the CI build is failing at the moment. Use read_file to read "
                    + "\(path(taskFiles[0])). \(summarise)",
                file: taskFiles[0]),
            Step(
                kind: .read,
                prompt: "Maria reviews this code, and she prefers early returns over nested conditionals. Use "
                    + "read_file to read \(path(taskFiles[1])). \(summarise)",
                file: taskFiles[1]),
            Step(
                kind: .read,
                prompt: "The ticket number for this work is 4127. Use read_file to read \(path(taskFiles[2])). "
                    + summarise,
                file: taskFiles[2]),
        ]
        for (index, file) in digressionFiles.enumerated() {
            let lead =
                index == 0
                ? "Let's take a detour from the task for a while. "
                : index == changeAt ? "By the way, the CI build is green again now. Next, " : "Next, "
            let verb = lead.hasSuffix("Next, ") ? "use" : "Use"
            steps.append(
                Step(
                    kind: index == changeAt ? .change : .digression,
                    prompt: "\(lead)\(verb) read_file to read \(path(file)), and tell me in two sentences what went "
                        + "wrong.",
                    file: file))
        }
        let questions = [
            Question(
                id: "codename", probe: .fact, prompt: "What is the codename for this release?",
                check: .mentions(["blue heron"])),
            Question(
                id: "ticket", probe: .fact, prompt: "What is the ticket number for this work?",
                check: .mentions(["4127"])),
            Question(
                id: "preference", probe: .fact, prompt: "What does Maria prefer in the code she reviews?",
                check: .mentions(["early return", "early exit", "guard"])),
            Question(
                id: "ci", probe: .changedFact, prompt: "What is the current state of the CI build?",
                check: .currentValue(
                    current: ["green", "pass", "succeed", "success", "fixed"], stale: ["fail", "broken"])),
            Question(
                id: "first-file", probe: .order,
                prompt: "Which file did you read first in this conversation? Give its file name.",
                check: .mentions(["harbour sync overview", "sync overview"])),
            Question(
                id: "task", probe: .task,
                prompt: "Let's get back to the task we started with. What is the task, and what is your first step?",
                check: .mentions(["dry run"])),
        ]
        return Scenario(name: "baseline", fixtures: fixtures, steps: steps, questions: questions)
    }

    /// `text` lowercased, with commas between digits removed (so `4,127` reads `4127`) and every other
    /// character that is not a letter or a digit turned into one space: `BLUE-HERON`, `Blue Heron.` and
    /// `blue heron` all read `blue heron`.
    public static func normalised(_ text: String) -> String {
        let characters = Array(text.lowercased())
        var result = ""
        var pendingSpace = false
        for (index, character) in characters.enumerated() {
            if character == ",", index > 0, index + 1 < characters.count, characters[index - 1].isNumber,
                characters[index + 1].isNumber
            {
                continue
            }
            if character.isLetter || character.isNumber {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// Scores `reply` against `check`. Phrases are matched as substrings of the normalised reply, so
    /// `pass` also finds `passing` and `passes`; the rule is lenient on phrasing by design, and every reply
    /// is kept in the run so a person can read what was counted.
    public static func score(_ reply: String, _ check: Check) -> Verdict {
        let text = normalised(reply)
        let has = { (phrases: [String]) in phrases.contains { text.contains(normalised($0)) } }
        switch check {
        case .mentions(let phrases):
            return has(phrases) ? .correct : .wrong
        case .currentValue(let current, let stale):
            if has(current) { return .correct }
            return has(stale) ? .stale : .wrong
        }
    }
}

/// A conversation under test: the one operation the scenario needs, and a reading of how full the
/// window is. Later designs (layers without recall, the full design, D5's cap and floor variants, D7's
/// repeated facts) conform with their own composer; the scenario and scoring do not change.
public protocol ContextConversation: AnyObject {
    /// Sends one user turn and returns the reply text.
    ///
    /// - Parameter prompt: The user's message.
    /// - Returns: The reply.
    /// - Throws: Whatever the model or runtime throws; the runner records it as the turn's reply.
    nonisolated(nonsending) func send(_ prompt: String) async throws -> String

    /// Tokens the conversation occupies now: counted by the model when it can, else the runtime's report
    /// for the last request, else nil.
    nonisolated(nonsending) func occupiedTokens() async -> Int?
}

/// A way of managing the context, opened fresh for each run.
public protocol ContextStrategy: Sendable {
    /// A short stable name, used in the measurement's task (`context.<name>`).
    var name: String { get }
    /// One sentence on what the strategy does, for the measurement's notes.
    var summary: String { get }

    /// Opens a conversation.
    ///
    /// - Parameters:
    ///   - model: The model every request goes to.
    ///   - tools: The tools the model may call.
    ///   - instructions: The instructions the conversation starts with.
    ///   - audit: Where turns, tool calls, and condensations are recorded.
    /// - Returns: The conversation.
    func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextConversation
}

/// The baseline: an `Agent` with its default policy and output handling off, whose composer sends the
/// store's active turns literally and condenses to the last four ahead of an 85% budget or on overflow,
/// which is what phase 2 of the proposal built and phase 1 measured.
public struct DroppingStrategy: ContextStrategy {
    /// `dropping`.
    public let name = "dropping"
    /// What it does.
    public let summary = "today's Agent: whole oldest turns dropped to the last four at 85% of the window"

    /// Creates the strategy.
    public init() {}

    /// Opens an `Agent` with the default context policy and presentational text kept.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextConversation
    {
        let agent = Agent(instructions: instructions, tools: tools, model: model, audit: audit)
        agent.cutsPresentation = false
        return AgentConversation(agent)
    }
}

/// Output handling on (phase 3 of the proposal): dropping as `DroppingStrategy` does, and presentational
/// text, a stretch of a reply that reproduces a tool output of its turn, cut from later requests and
/// replaced by a marker. This is `Agent`'s default.
public struct CuttingStrategy: ContextStrategy {
    /// `cutting`.
    public let name = "cutting"
    /// What it does.
    public let summary =
        "dropping, with presentational text (a reply's retyping of its turn's tool output) cut to a marker"

    /// Creates the strategy.
    public init() {}

    /// Opens an `Agent` with the default context policy and output handling on.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextConversation
    {
        let agent = Agent(instructions: instructions, tools: tools, model: model, audit: audit)
        agent.cutsPresentation = true
        return AgentConversation(agent)
    }
}

/// An `Agent` as a conversation under test.
public final class AgentConversation: ContextConversation {
    /// The agent, unchanged.
    public let agent: Agent

    /// Wraps an agent.
    public init(_ agent: Agent) { self.agent = agent }

    /// The agent's reply text.
    nonisolated(nonsending) public func send(_ prompt: String) async throws -> String {
        try await agent.respond(to: prompt).text
    }

    /// `Agent.contextTokens()`, nil when it cannot tell or counting fails.
    nonisolated(nonsending) public func occupiedTokens() async -> Int? {
        (try? await agent.contextTokens()) ?? nil
    }
}

extension ContextEval {
    /// What one turn of a run did.
    public struct Turn: Sendable, Equatable {
        /// 1-based position in the conversation.
        public var number: Int
        /// The step's kind, or `question:<id>` for a question.
        public var label: String
        /// The reply, or `error: …` when the turn threw.
        public var reply: String
        /// Whether the turn threw.
        public var failed: Bool
        /// Wall time of the turn, not counting the token reading after it.
        public var seconds: Double
        /// Tokens occupied after the turn (`ContextConversation.occupiedTokens`).
        public var tokens: Int?
        /// The reason of each condensation during the turn (`budget`, `overflow`), from the audit.
        public var condensations: [String]
        /// The tools called during the turn, in order.
        public var tools: [String]
        /// Stretches of presentational text cut after the turn (`context.cut` events).
        public var cuts: Int

        /// Creates a turn record.
        public init(
            number: Int, label: String, reply: String, failed: Bool, seconds: Double, tokens: Int?,
            condensations: [String], tools: [String], cuts: Int = 0
        ) {
            self.cuts = cuts
            self.number = number
            self.label = label
            self.reply = reply
            self.failed = failed
            self.seconds = seconds
            self.tokens = tokens
            self.condensations = condensations
            self.tools = tools
        }

        /// One line for the eval's output.
        public var line: String {
            let shown = reply.replacingOccurrences(of: "\n", with: "⏎").prefix(160)
            return
                "turn \(number) \(label): \(String(format: "%.1f", seconds)) s, tokens \(tokens.map(String.init) ?? "?")"
                + (condensations.isEmpty ? "" : ", condensed \(condensations.joined(separator: "+"))")
                + (tools.isEmpty ? "" : ", tools \(tools.joined(separator: ","))")
                + (cuts == 0 ? "" : ", cut \(cuts)") + (failed ? ", FAILED" : "")
                + " | \(shown)"
        }
    }

    /// A scored answer.
    public struct Answer: Sendable, Equatable {
        /// The question.
        public var question: Question
        /// The reply.
        public var reply: String
        /// How it scored.
        public var verdict: Verdict

        /// Creates an answer.
        public init(question: Question, reply: String, verdict: Verdict) {
            self.question = question
            self.reply = reply
            self.verdict = verdict
        }
    }

    /// One run of a scenario through a strategy on a model.
    public struct Run: Sendable, Equatable {
        /// The strategy's name.
        public var strategy: String
        /// The model, as a `ModelSelection` spelling.
        public var model: String
        /// The window the model or its settings stated; nil when unknown.
        public var window: Int?
        /// Every turn, questions included.
        public var turns: [Turn]
        /// The questions' scored answers, in order.
        public var answers: [Answer]
        /// The one-minute load average when the run started and when it ended.
        public var load: (start: Double, end: Double)
        /// What the scenario does (`Scenario.summary`).
        public var scenario: String

        /// Creates a run.
        public init(
            strategy: String, model: String, window: Int?, turns: [Turn], answers: [Answer],
            load: (start: Double, end: Double) = (0, 0), scenario: String = ContextEval.baselineSummary
        ) {
            self.scenario = scenario
            self.strategy = strategy
            self.model = model
            self.window = window
            self.turns = turns
            self.answers = answers
            self.load = load
        }

        /// Equal when every recorded field is.
        public static func == (lhs: Run, rhs: Run) -> Bool {
            lhs.strategy == rhs.strategy && lhs.model == rhs.model && lhs.window == rhs.window
                && lhs.turns == rhs.turns && lhs.answers == rhs.answers && lhs.load.start == rhs.load.start
                && lhs.load.end == rhs.load.end && lhs.scenario == rhs.scenario
        }

        /// Correct answers among the questions probing `probes`.
        public func correct(_ probes: Set<Probe>) -> (correct: Int, total: Int) {
            let asked = answers.filter { probes.contains($0.question.probe) }
            return (asked.filter { $0.verdict == .correct }.count, asked.count)
        }

        /// Condensations over the whole run.
        public var condensations: Int { turns.map(\.condensations.count).reduce(0, +) }

        /// Stretches of presentational text cut over the whole run.
        public var cuts: Int { turns.map(\.cuts).reduce(0, +) }

        /// The turn times, in milliseconds.
        public var milliseconds: [Double] { turns.map { $0.seconds * 1000 } }

        /// The token readings that were available.
        public var tokens: [Int] { turns.compactMap(\.tokens) }

        /// The summary lines the eval prints.
        public var report: [String] {
            let facts = correct([.fact, .changedFact])
            let verdicts = answers.map { "\($0.question.id)=\($0.verdict.rawValue)" }.joined(separator: " ")
            return [
                "\(strategy) on \(model) (window \(window.map(String.init) ?? "unknown")): facts \(facts.correct)/"
                    + "\(facts.total), \(verdicts)",
                "\(condensations) condensations and \(cuts) cuts over \(turns.count) turns; tokens after a turn median "
                    + "\(ContextEval.percentile(tokens.map(Double.init), 0.5).map { String(Int($0)) } ?? "?"), max "
                    + "\(tokens.max().map(String.init) ?? "?"); time per turn median "
                    + String(
                        format: "%.1f s, p95 %.1f s", (ContextEval.percentile(milliseconds, 0.5) ?? 0) / 1000,
                        (ContextEval.percentile(milliseconds, 0.95) ?? 0) / 1000)
                    + String(format: "; load average %.0f then %.0f", load.start, load.end),
            ]
        }

        /// The run as a measurement: every question counts once; the notes carry what was asked and the
        /// run's condensations, tokens, and load, since `Measurement` has no fields for them.
        ///
        /// - Parameter variant: Distinguishes runs of one strategy on one model, such as a window size;
        ///   appended to the task as `context.<strategy>.<variant>`.
        /// - Returns: The measurement.
        public func measurement(variant: String? = nil) -> WispCore.Measurement {
            let facts = correct([.fact, .changedFact])
            let byID = Dictionary(answers.map { ($0.question.id, $0.verdict.rawValue) }) { first, _ in first }
            let task = "context.\(strategy)" + (variant.map { ".\($0)" } ?? "")
            return WispCore.Measurement(
                task: task, model: model, passed: answers.filter { $0.verdict == .correct }.count,
                total: answers.count,
                notes: "a scripted conversation of \(turns.count - answers.count) turns (\(scenario)) then "
                    + "\(answers.count) questions, scored by phrase; window \(window.map(String.init) ?? "unknown"); "
                    + "this run: facts \(facts.correct)/"
                    + "\(facts.total), ci \(byID["ci"] ?? "?"), first file \(byID["first-file"] ?? "?"), task "
                    + "\(byID["task"] ?? "?"), \(condensations) condensations, \(cuts) cuts, median "
                    + "\(ContextEval.percentile(tokens.map(Double.init), 0.5).map { String(Int($0)) } ?? "?") "
                    + String(format: "tokens after a turn, load average %.0f", load.start),
                p50Milliseconds: ContextEval.percentile(milliseconds, 0.5),
                p95Milliseconds: ContextEval.percentile(milliseconds, 0.95))
        }
    }

    /// The value at `fraction` (0 to 1) of `values`, nearest rank; nil for none.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// The one-minute load average, or 0 when it cannot be read.
    public static func loadAverage() -> Double {
        var loads = [0.0, 0.0, 0.0]
        return getloadavg(&loads, 3) > 0 ? loads[0] : 0
    }

    /// Runs `scenario` through `strategy`: each step, then each question, one turn at a time. A turn that
    /// throws is recorded with its error as the reply and the run continues, so every question is scored.
    ///
    /// - Parameters:
    ///   - scenario: The conversation.
    ///   - strategy: How context is managed.
    ///   - model: The model.
    ///   - instructions: The instructions the conversation starts with.
    ///   - tools: Makes the model's tools over the run's audit log, so their calls are recorded there.
    ///   - onTurn: Called after each turn, for progress output.
    /// - Returns: The run.
    nonisolated(nonsending) public static func run(
        _ scenario: Scenario, strategy: some ContextStrategy, model: ResolvedModel, instructions: String,
        tools: (AuditLog) -> [any Tool], onTurn: (Turn) -> Void = { _ in }
    ) async -> Run {
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "context-eval", sink: sink)
        let conversation = strategy.open(
            model: model, tools: tools(audit), instructions: instructions, audit: audit)
        let loadAtStart = loadAverage()
        let prompts =
            scenario.steps.map { ($0.kind.rawValue, $0.prompt) }
            + scenario.questions.map { ("question:\($0.id)", $0.prompt) }
        var turns: [Turn] = []
        for (label, prompt) in prompts {
            let first = sink.events.count
            let clock = ContinuousClock()
            let started = clock.now
            var reply: String
            var failed = false
            do {
                reply = try await conversation.send(prompt)
            } catch {
                reply = "error: \(error)"
                failed = true
            }
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let events = sink.events.dropFirst(first)
            let turn = Turn(
                number: turns.count + 1, label: label, reply: reply, failed: failed, seconds: seconds,
                tokens: await conversation.occupiedTokens(),
                condensations: events.filter { $0.kind == .condensation }.map {
                    $0.details["reason"]?.stringValue ?? "?"
                },
                tools: events.filter { $0.kind == .toolCall }.map { $0.details["tool"]?.stringValue ?? "?" },
                cuts: events.filter { $0.kind == .presentationCut }.count)
            turns.append(turn)
            onTurn(turn)
        }
        let replies = turns.suffix(scenario.questions.count).map(\.reply)
        let answers = zip(scenario.questions, replies).map { question, reply in
            Answer(question: question, reply: reply, verdict: question.score(reply))
        }
        return Run(
            strategy: strategy.name, model: model.selection.description, window: model.contextSize, turns: turns,
            answers: answers, load: (loadAtStart, loadAverage()), scenario: scenario.summary)
    }
}

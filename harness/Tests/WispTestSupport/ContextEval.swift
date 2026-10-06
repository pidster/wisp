import Foundation
import FoundationModels
import WispCore

/// The context eval: one scripted conversation that plants facts and a task, fills the window with file
/// reads and a long digression, then asks for each fact, for the first file read, and for the task
/// (docs/proposals/2026-09-29-layered-context.md, "Evaluation"). Everything here runs without a model,
/// so the scenario, the scoring, and the runner are tested in the gate; `ContextEvalTests` in
/// `harness/Evals` drives it on real models.
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
            /// Asks for prose with no tool: a follow-up, or a line to write.
            case talk
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
        /// A detail only an early tool output held, which no fact or summary carries: what `memory`'s recall is for.
        case detail
        /// A fact the person stated in passing mid-digression, which the model can note as it works (`memory`'s
        /// note) before distilling reaches that turn.
        case noted
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

    /// `Tests/WispTestSupport/Fixtures/context`, found from this source file's place in the repository. The
    /// gate's tests read them and so do the evaluations in `Evals/`, which is why they live here.
    public static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/context")
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
    /// The digression read whose turn, in the noting scenario, states the release date in passing.
    static let notedAt = 7
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

    /// The showing scenario with one more question at the end, about a detail of the first file read that no fact
    /// or summary carries: what the temporary file a copy writes to is called (`.harbour-tmp-<random>`, line 52 of
    /// the design overview). A model can answer it only from the file's text: from the literal turns while the
    /// read is still there, and once condensing has dropped it, by recalling the read (phase 4c).
    ///
    /// - Parameter fixtures: Where the fixture files are; defaults to the repository's.
    /// - Returns: The scenario.
    public static func recalling(fixtures: URL = fixturesDirectory) -> Scenario {
        var scenario = showing(fixtures: fixtures)
        scenario.name = "recalling"
        scenario.summary += ", then one question on a detail of the first file"
        scenario.questions.append(
            Question(
                id: "detail", probe: .detail,
                prompt: "In the design overview you read first, what exactly is the temporary file that each copy "
                    + "writes to named? Give the name as the file writes it.",
                check: .mentions(["harbour tmp"])))
        return scenario
    }

    /// The recalling scenario with a fact stated in passing during the digression, which no tool output holds and
    /// which the model can note as it works (`memory`'s note, phase 4c): the release date moves to 14 November at
    /// the eighth incident review, and an eighth question asks for it. Without a note, the answer depends on the
    /// distiller keeping it when that turn is dropped, or on the turn still being in view.
    ///
    /// - Parameter fixtures: Where the fixture files are; defaults to the repository's.
    /// - Returns: The scenario.
    public static func noting(fixtures: URL = fixturesDirectory) -> Scenario {
        var scenario = recalling(fixtures: fixtures)
        scenario.name = "noting"
        scenario.summary += ", and a release date stated in passing mid-digression, asked for last"
        let at = scenario.steps.firstIndex { $0.file == digressionFiles[notedAt] } ?? scenario.steps.count - 1
        scenario.steps[at].prompt =
            "Keep this in mind for later: the release date moved to 14 November. "
            + scenario.steps[at].prompt.replacingOccurrences(of: "Next, use", with: "Now use")
        scenario.questions.append(
            Question(
                id: "release-date", probe: .noted, prompt: "When is the release date?",
                check: .mentions(["14 november", "november 14", "14 nov", "nov 14", "14th november", "november 14th"])))
        return scenario
    }

    /// The files the sustained scenario reads after the digression, on the task, in order; `SyncCommand.swift` is
    /// read a second time between the changelog and the test output.
    static let returnFiles = [
        "Planner.swift", "PlannerTests.swift", "harbour-issue-212.md", "harbour-changelog.md", "SyncCommand.swift",
        "swift-test-output.log", "harbour-review-notes.md",
    ]

    /// The noting scenario followed by a return to the task that a working session would have (context checkpoint 2,
    /// docs/proposals/2026-10-06-context-checkpoint-2.md): 14 more turns, which restate the task, read the planner,
    /// its tests, the issue that asked for the flag, the changelog, the command again, a failing test run, and review
    /// notes, plant one more fact, and ask twice for prose with no tool (one a short follow-up); then four turns
    /// that come back to earlier files (the flags reference, the planner, the configuration file) and ask for one more
    /// line. Then the noting scenario's eight questions and two more: the late fact, and a detail of the issue (who
    /// opened it) that no fact or summary need carry. 29 turns and ten questions, long enough to condense at the
    /// default budget on the on-device model's 8,192 tokens, where the 22 turns of `recalling` never did (ADR 0045's
    /// checkpoint).
    ///
    /// - Parameter fixtures: Where the fixture files are; defaults to the repository's.
    /// - Returns: The scenario.
    public static func sustained(fixtures: URL = fixturesDirectory) -> Scenario {
        var scenario = noting(fixtures: fixtures)
        scenario.name = "sustained"
        scenario.summary +=
            ", then 14 turns back on the task (the task restated, ten reads of which four are files read again, a "
            + "fact planted, three replies with no tool), and two more questions"
        let path = { (name: String) in fixtures.appending(path: name).path }
        let files = returnFiles
        scenario.steps += [
            Step(
                kind: .read,
                prompt: "Back to the task: the --dry-run flag for `harbour sync`. Use read_file to read "
                    + "\(path(files[0])). Summarise it in two sentences.",
                file: files[0]),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[1])). Which cases do these tests cover? Answer in two "
                    + "sentences.",
                file: files[1]),
            Step(kind: .talk, prompt: "And which case will the new flag need that they do not cover yet?"),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[2])), the issue that asked for this flag. Summarise the "
                    + "request in two sentences.",
                file: files[2]),
            Step(
                kind: .plant,
                prompt: "The beta testers follow progress in the #harbour-beta channel; we'll post there when this "
                    + "lands. Reply in one sentence to confirm."),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[3])). What did the last release change? Two sentences.",
                file: files[3]),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[4])) again, and tell me in two sentences where the new "
                    + "flag would be checked.",
                file: files[4]),
            Step(
                kind: .read,
                prompt: "I ran swift test after a first change. Use read_file to read \(path(files[5])) and tell me "
                    + "in two sentences what failed.",
                file: files[5]),
            Step(kind: .talk, prompt: "Write the help text for the new flag, in one line."),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[6])), notes from the last review of this command. What "
                    + "should this change take from them? Two sentences.",
                file: files[6]),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(taskFiles[1])) again, and draft the new flag's entry in the "
                    + "same style, in at most four lines.",
                file: taskFiles[1]),
            Step(kind: .talk, prompt: "Now the changelog line for it, in one sentence, as the review notes asked."),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(files[0])) again. Which call should the new flag stop "
                    + "after? One sentence.",
                file: files[0]),
            Step(
                kind: .read,
                prompt: "Use read_file to read \(path(shownFile)) again. Should the new flag have a setting in this "
                    + "file too? One sentence.",
                file: shownFile),
        ]
        scenario.questions += [
            Question(
                id: "channel", probe: .fact, prompt: "Where do the beta testers follow progress?",
                check: .mentions(["harbour beta"])),
            Question(
                id: "reporter", probe: .detail,
                prompt: "Who opened the issue that asked for this flag? Give their name.",
                check: .mentions(["solberg"])),
        ]
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

extension ContextEval {
    /// Whether `reply` repeats where a fact came from, as the facts' lines write it: a bracketed source
    /// (`[the person]`, `[tool read_file, turn 2]`, the form before 2026-09-30), the dash form that replaced it
    /// (`— from the person`), or `(source: …)`. Both models copied the bracketed form into answers in phase 4c.
    ///
    /// - Parameter reply: A reply.
    /// - Returns: Whether it echoes a source.
    public static func echoesSource(_ reply: String) -> Bool {
        reply.contains(
            #/(?i)\[(the person|the caller|tool\b|model\b)|[—–-]\s*from (the person|the caller|tool |model\b)|\(source:/#
        )
    }
}

/// A conversation under test: the one operation the scenario needs, and a reading of how full the
/// window is. Later designs (layers without recall, the full design, D5's cap and floor variants, D7's
/// repeated facts) conform with their own composer; the scenario and scoring do not change.
public protocol ContextThread: AnyObject {
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
        -> any ContextThread

    /// Whether the conversation's agent is given the run's tool events, as `WispThread.openAgent` gives a
    /// face's agent its `ToolEventTrail`, so tool entries link to their audit events and facts can be
    /// extracted from them. False by default, so the earlier strategies run as they were measured.
    var linksToolEvents: Bool { get }

    /// Whether the conversation has `memory`, so its instructions carry the system prompt's memory rule
    /// (`Prompting.rendered(toolsAvailable:memory:)`). False by default: a strategy without the tool is not told
    /// of it.
    var hasMemory: Bool { get }
}

extension ContextStrategy {
    /// No: the agent runs without the run's tool events.
    public var linksToolEvents: Bool { false }
    /// No: the conversation has no `memory`.
    public var hasMemory: Bool { false }
}

/// The baseline: an `Agent` with phase 2's policy (`ContextPolicy.fixed`) and output handling off, whose composer
/// sends the store's active turns literally and condenses to the last four ahead of an 85% budget or on overflow,
/// which is what phase 2 of the proposal built and phase 1 measured.
public struct DroppingStrategy: ContextStrategy {
    /// `dropping`.
    public let name = "dropping"
    /// What it does.
    public let summary = "today's Agent: whole oldest turns dropped to the last four at 85% of the window"
    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double

    /// Creates the strategy.
    ///
    /// - Parameter budget: When to condense; the default is the agent's, 85%. The phase-6 checkpoint also runs it
    ///   at half the window, beside the full design at the same budget.
    public init(budget: Double = 0.85) {
        self.budget = budget
    }

    /// Opens an `Agent` with phase 2's context policy and presentational text kept.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let agent = Agent(
            instructions: instructions, tools: tools, model: model, contextPolicy: .fixed, audit: audit)
        agent.contextBudget = budget
        agent.cutsPresentation = false
        agent.referencesOutput = false
        return AgentThread(agent)
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

    /// Opens an `Agent` with phase 2's context policy and presentational text cut.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let agent = Agent(
            instructions: instructions, tools: tools, model: model, contextPolicy: .fixed, audit: audit)
        agent.cutsPresentation = true
        agent.referencesOutput = false
        return AgentThread(agent)
    }
}

/// Output handling as decision D12 of the proposal settled it (phase 3b), `Agent`'s default: dropping as
/// `DroppingStrategy` does, cutting limited to exact copies, and each tool output sent whole only in the
/// turn that produced it and as a compact reference in every later request.
public struct ReferencingStrategy: ContextStrategy {
    /// `referencing`, with `-target` when it condenses to a target.
    public var name: String { "referencing" + ContextEval.suffix(policy) }
    /// What it does.
    public let summary =
        "dropping, with exact copies of tool output cut and each output a reference after its own turn"

    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double
    /// How it condenses (`Agent.contextPolicy`).
    public var policy: ContextPolicy

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - budget: When to condense; the default is the agent's, 85%.
    ///   - policy: How it condenses; phase 2's four turns by default, as the recorded figures were measured.
    public init(budget: Double = 0.85, policy: ContextPolicy = .fixed) {
        self.budget = budget
        self.policy = policy
    }

    /// Opens an `Agent` with the strategy's context policy and both kinds of output handling on.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let agent = Agent(instructions: instructions, tools: tools, model: model, contextPolicy: policy, audit: audit)
        agent.contextBudget = budget
        agent.cutsPresentation = true
        agent.referencesOutput = true
        return AgentThread(agent)
    }
}

/// Facts (phase 4a of the proposal, decisions D1 and D2) on top of `ReferencingStrategy`: facts extracted from
/// tool output each turn, the prose of the turns a condensation drops distilled into facts by the model, and
/// the facts in force composed into each request on the prompt side, capped at `share` of the window. Every
/// fact is kept in memory, so a run neither reads nor writes `~/.wisp/facts.json`.
public struct FactsStrategy: ContextStrategy {
    /// `facts`, with `-target` when it condenses to a target.
    public var name: String { "facts" + ContextEval.suffix(policy) }
    /// What it does.
    public let summary =
        "referencing, with facts extracted from tool output, the dropped turns' prose distilled into facts at each "
        + "condensation, and the facts composed on the prompt side"
    /// The share of the window the facts may take (`Agent.factsShare`).
    public var share: Double
    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double
    /// How it condenses (`Agent.contextPolicy`).
    public var policy: ContextPolicy
    /// Yes: facts are extracted from the turn's tool events.
    public var linksToolEvents: Bool { true }

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - share: The facts' share of the window; the default is the composer's.
    ///   - budget: When to condense; the default is the agent's, 85%. A lower budget makes a run condense
    ///     earlier, so distillation is measured on a model whose reads happen to fit.
    ///   - policy: How it condenses; phase 2's four turns by default, as the recorded figures were measured.
    public init(share: Double = 0.1, budget: Double = 0.85, policy: ContextPolicy = .fixed) {
        self.share = share
        self.budget = budget
        self.policy = policy
    }

    /// Opens an `Agent` with output handling on and facts kept in memory.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let agent = Agent(instructions: instructions, tools: tools, model: model, contextPolicy: policy, audit: audit)
        agent.cutsPresentation = true
        agent.referencesOutput = true
        agent.contextBudget = budget
        agent.factsShare = share
        agent.summarises = false
        agent.facts = FactSettings()
        return AgentThread(agent)
    }
}

/// The running summary (phase 4b of the proposal, decision D1) on top of `FactsStrategy`: when condensing drops
/// at least `batchTurns` turns not yet summarised, the model adds them to the summary so far, which the earlier
/// block carries after the facts, capped at `summaryShare` of the window. `together` writes the summary in the
/// facts' call; otherwise it has a call of its own.
public struct SummaryStrategy: ContextStrategy {
    /// `summary`, or `summary-separate` when the summary has a call of its own, with `-target` when it condenses
    /// to a target.
    public var name: String { (together ? "summary" : "summary-separate") + ContextEval.suffix(policy) }
    /// What it does.
    public var summary: String {
        "facts, with the turns condensing drops added to a running summary in the earlier block"
            + (together ? ", written in the facts' call" : ", written in a call of its own")
    }
    /// The share of the window the facts may take (`Agent.factsShare`).
    public var share: Double
    /// The share of the window the summary may take (`Agent.summaryShare`).
    public var summaryShare: Double
    /// Dropped turns that wait for the summary (`Agent.summaryBatchTurns`).
    public var batchTurns: Int
    /// Whether the summary is written in the facts' call (`FactSettings.summaryWithFacts`).
    public var together: Bool
    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double
    /// How it condenses (`Agent.contextPolicy`).
    public var policy: ContextPolicy
    /// Yes: facts are extracted from the turn's tool events.
    public var linksToolEvents: Bool { true }

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - share: The facts' share of the window; the default is the composer's.
    ///   - summaryShare: The summary's share of the window; the default is the composer's.
    ///   - batchTurns: Dropped turns that wait for the summary; the default is the composer's.
    ///   - together: Whether the summary is written in the facts' call; the default is `FactSettings`'s.
    ///   - budget: When to condense; the default is the agent's, 85%.
    ///   - policy: How it condenses; phase 2's four turns by default, as the recorded figures were measured.
    public init(
        share: Double = 0.1, summaryShare: Double = 0.05, batchTurns: Int = 3,
        together: Bool = FactSettings.summaryWithFactsDefault, budget: Double = 0.85, policy: ContextPolicy = .fixed
    ) {
        self.policy = policy
        self.share = share
        self.summaryShare = summaryShare
        self.batchTurns = batchTurns
        self.together = together
        self.budget = budget
    }

    /// Opens an `Agent` with output handling on, facts kept in memory, and the running summary.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let agent = Agent(instructions: instructions, tools: tools, model: model, contextPolicy: policy, audit: audit)
        agent.cutsPresentation = true
        agent.referencesOutput = true
        agent.contextBudget = budget
        agent.factsShare = share
        agent.summarises = true
        agent.summaryShare = summaryShare
        agent.summaryBatchTurns = batchTurns
        agent.facts = FactSettings(summaryWithFacts: together)
        return AgentThread(agent)
    }
}

/// `memory` (phase 4c of the proposal) on top of `SummaryStrategy`, with the summary written in the facts' call:
/// the model can recall any stored entry, a turn, the task, the summary's versions, or a fact's history for the
/// turn it asks in, and note facts as it works; references name it (`to see it: memory "recall entry 7"`) instead
/// of a second call. The full design of the proposal short of the per-request assessment (phase 4d).
public struct MemoryStrategy: ContextStrategy {
    /// `memory`, with `-target` when it condenses to a target.
    public var name: String { "memory" + ContextEval.suffix(policy) }
    /// What it does.
    public let summary =
        "summary (in the facts' call), with the memory tool recalling stored entries, turns, the task, and facts' "
        + "histories and noting facts, and references naming it"
    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double
    /// How it condenses (`Agent.contextPolicy`).
    public var policy: ContextPolicy
    /// Yes: facts are extracted from the turn's tool events.
    public var linksToolEvents: Bool { true }
    /// Yes: the conversation has `memory`.
    public var hasMemory: Bool { true }

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - budget: When to condense; the default is the agent's, 85%.
    ///   - policy: How it condenses; phase 2's four turns by default, as the recorded figures were measured.
    public init(budget: Double = 0.85, policy: ContextPolicy = .fixed) {
        self.budget = budget
        self.policy = policy
    }

    /// Opens an `Agent` as `SummaryStrategy` does, with `memory` added to its tools and wired to it.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let source = MemorySource()
        let memory = ToolRegistry(audit: audit, memory: source).select([MemoryTool.toolName]).tools
        let agent = Agent(
            instructions: instructions, tools: tools + memory, model: model, contextPolicy: policy, audit: audit)
        agent.cutsPresentation = true
        agent.referencesOutput = true
        agent.contextBudget = budget
        agent.summarises = true
        agent.facts = FactSettings(summaryWithFacts: true)
        agent.memory = source
        return AgentThread(agent)
    }
}

/// The assessment per request (phase 4d of the proposal, decision D12) on top of `MemoryStrategy`: before each
/// request, rules or one model call outside the context choose the tools the request registers (D4), infer the task
/// and its objective (D6), and pick the facts repeated next to the request (D7); the instructions carry the tool
/// catalogue. `tools` chooses D11's alternatives: per request, grown within the task, or every tool (the assessment's
/// cost and its task and facts without the tools' saving). The phase-6 eval runs it against `MemoryStrategy`.
public struct AssessingStrategy: ContextStrategy {
    /// `assessing`, then `-task` or `-all` for the other tool sets, and `-target` when it condenses to a target.
    public var name: String {
        let base =
            switch tools {
            case .request: "assessing"
            case .task: "assessing-task"
            case .all: "assessing-all"
            }
        return base + (taskChanges == .restated ? "-restated" : "") + ContextEval.suffix(policy)
    }
    /// What it does.
    public var summary: String {
        "memory, with each request assessed (rules, else one model call) for its tools, task, and relevant facts; "
            + "tools registered "
            + (tools == .request ? "per request" : tools == .task ? "as grown within the task" : "all, every request")
            + (taskChanges == .restated ? "; the task changed only by a request that states one" : "")
    }
    /// Which tools each request registers.
    public var tools: AssessmentSettings.ToolSets
    /// Whether the task is inferred, as in chat.
    public var infersTask: Bool
    /// When an inferred task may change: on any request (as phase 4d built it), or only on one that states a task.
    public var taskChanges: AssessmentSettings.TaskChanges
    /// The fraction of the window a turn may start at before condensing (`Agent.contextBudget`).
    public var budget: Double
    /// How it condenses (`Agent.contextPolicy`).
    public var policy: ContextPolicy
    /// Yes: facts are extracted from the turn's tool events.
    public var linksToolEvents: Bool { true }
    /// Yes: the conversation has `memory`.
    public var hasMemory: Bool { true }

    /// Creates the strategy.
    ///
    /// - Parameters:
    ///   - tools: Which tools each request registers; per request by default (D4).
    ///   - infersTask: Whether the task is inferred; yes, as in chat.
    ///   - taskChanges: When an inferred task may change; on any request by default, as the checkpoint measured it.
    ///   - budget: When to condense; the default is the agent's, 85%.
    ///   - policy: How it condenses; phase 2's four turns by default, as `MemoryStrategy`'s.
    public init(
        tools: AssessmentSettings.ToolSets = .request, infersTask: Bool = true,
        taskChanges: AssessmentSettings.TaskChanges = .any, budget: Double = 0.85, policy: ContextPolicy = .fixed
    ) {
        self.tools = tools
        self.infersTask = infersTask
        self.taskChanges = taskChanges
        self.budget = budget
        self.policy = policy
    }

    /// Opens an `Agent` as `MemoryStrategy` does, with the assessment on.
    public func open(
        model: ResolvedModel, tools: [any Tool], instructions: String, audit: AuditLog
    )
        -> any ContextThread
    {
        let thread = MemoryStrategy(budget: budget, policy: policy).open(
            model: model, tools: tools, instructions: instructions, audit: audit)
        if let agent = (thread as? AgentThread)?.agent {
            agent.assessment = AssessmentSettings(tools: self.tools, infersTask: infersTask, taskChanges: taskChanges)
        }
        return thread
    }
}

/// A conversation under test that runs on an `Agent`, so the runner can give it the run's tool events and read its
/// store when the run ends: `AgentThread`, and `SwitchingThread`, whose agent changes when the model does.
public protocol AgentHolding: AnyObject {
    /// The agent the next turn goes to.
    var agent: Agent { get }
}

/// An `Agent` as a conversation under test.
public final class AgentThread: ContextThread, AgentHolding {
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
    /// What a strategy's name adds for its condensing policy: `-target` for a token target (phase 5), nothing for
    /// phase 2's fixed turns, under which every recorded figure before phase 5 was measured.
    ///
    /// - Parameter policy: The policy.
    /// - Returns: The suffix.
    public static func suffix(_ policy: ContextPolicy) -> String {
        if case .target = policy { return "-target" }
        return ""
    }

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
        /// Tokens occupied after the turn (`ContextThread.occupiedTokens`).
        public var tokens: Int?
        /// The reason of each condensation during the turn (`budget`, `overflow`), from the audit, with `:floor`
        /// when a condensation to a target could not reach its target.
        public var condensations: [String]
        /// The tools called during the turn, in order.
        public var tools: [String]
        /// Stretches of presentational text cut after the turn (`context.cut` events).
        public var cuts: Int
        /// Tool outputs switched to references at the turn's start (`context.reference` events).
        public var references: Int
        /// The seconds each distillation during the turn took (`context.distillation` events).
        public var distillations: [Double]
        /// Facts recorded during the turn, new versions included (`fact.recorded` events).
        public var facts: Int
        /// The facts distilled during the turn, as `subject name = value`.
        public var distilled: [String] = []
        /// The seconds each summary call during the turn took (`context.summary` events), with whether it
        /// shared the facts' call and whether it failed.
        public var summaries: [SummaryCall] = []
        /// Each `memory` call during the turn (`context.memory` events): a recall as `request -> target` with
        /// `found` or `none`, a note as `request -> noted` or `refused (reason)`.
        public var memoryCalls: [String] = []
        /// Each assessment during the turn (`context.assessment` events), as `method tools (seconds)`, with
        /// `retry` when a selection missed a tool the model called; empty when the strategy assesses nothing.
        public var assessments: [String] = []
        /// The tokens the context took after each condensation to a target during the turn (`fillAfter`); empty
        /// under phase 2's fixed turns, whose events carry no fill.
        public var fills: [Int] = []
        /// The goal each of those condensations aimed for, in tokens (`target`), in the same order.
        public var targets: [Int] = []
        /// Assessments during the turn that changed the task (`context.assessment` with `taskChanged`).
        public var taskChanges = 0

        /// Creates a turn record.
        public init(
            number: Int, label: String, reply: String, failed: Bool, seconds: Double, tokens: Int?,
            condensations: [String], tools: [String], cuts: Int = 0, references: Int = 0,
            distillations: [Double] = [], facts: Int = 0
        ) {
            self.distillations = distillations
            self.facts = facts
            self.cuts = cuts
            self.references = references
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
                + (cuts == 0 ? "" : ", cut \(cuts)") + (references == 0 ? "" : ", referenced \(references)")
                + (distillations.isEmpty
                    ? ""
                    : ", distilled in " + distillations.map { String(format: "%.1f s", $0) }.joined(separator: "+"))
                + (facts == 0 ? "" : ", facts \(facts)")
                + (distilled.isEmpty ? "" : ", distilled [\(distilled.joined(separator: "; "))]")
                + (summaries.isEmpty ? "" : ", summarised " + summaries.map(\.words).joined(separator: "+"))
                + (memoryCalls.isEmpty ? "" : ", memory [\(memoryCalls.joined(separator: "; "))]")
                + (assessments.isEmpty ? "" : ", assessed [\(assessments.joined(separator: "; "))]")
                + (taskChanges == 0 ? "" : ", task changed")
                + (fills.isEmpty
                    ? ""
                    : ", fill after "
                        + zip(fills, targets).map { "\($0) of target \($1)" }.joined(separator: "+"))
                + (failed ? ", FAILED" : "")
                + " | \(shown)"
        }
    }

    /// One summary call (`context.summary`).
    public struct SummaryCall: Sendable, Equatable {
        /// How long it took; for one shared with the facts, the shared call's time.
        public var seconds: Double
        /// Whether it shared the facts' call.
        public var combined: Bool
        /// Why no version was written, or nil.
        public var failure: String?

        /// Creates a record.
        public init(seconds: Double, combined: Bool, failure: String? = nil) {
            self.seconds = seconds
            self.combined = combined
            self.failure = failure
        }

        /// In words: `4.2 s`, `in the facts' call`, and `failed` where it did.
        var words: String {
            (combined ? "in the facts' call" : String(format: "%.1f s", seconds)) + (failure == nil ? "" : " failed")
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
        /// The running summary's last version when the run ended, for a strategy that writes one.
        public var summary: RunningSummary?
        /// Each model switch during the run, in words (`SwitchingThread.log`); empty when the model never changed.
        public var switches: [String] = []

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
                && lhs.load.end == rhs.load.end && lhs.scenario == rhs.scenario && lhs.summary == rhs.summary
                && lhs.switches == rhs.switches
        }

        /// Correct answers among the questions probing `probes`.
        public func correct(_ probes: Set<Probe>) -> (correct: Int, total: Int) {
            let asked = answers.filter { probes.contains($0.question.probe) }
            return (asked.filter { $0.verdict == .correct }.count, asked.count)
        }

        /// Condensations over the whole run.
        public var condensations: Int { turns.map(\.condensations.count).reduce(0, +) }

        /// Condensations to a target that could not reach it even at the floor of one literal turn.
        public var floors: Int { turns.flatMap(\.condensations).filter { $0.hasSuffix(":floor") }.count }

        /// Assessments that changed the task, over the whole run.
        public var taskChanges: Int { turns.map(\.taskChanges).reduce(0, +) }

        /// Assessments that called the model (`ContextEval.assessmentLine`'s method is `model`), over the whole run.
        public var assessmentCalls: Int { turns.flatMap(\.assessments).filter { $0.hasPrefix("model ") }.count }

        /// Stretches of presentational text cut over the whole run.
        public var cuts: Int { turns.map(\.cuts).reduce(0, +) }

        /// Tool outputs sent as references over the whole run.
        public var references: Int { turns.map(\.references).reduce(0, +) }

        /// The seconds each distillation took, over the whole run.
        public var distillations: [Double] { turns.flatMap(\.distillations) }

        /// Facts recorded over the whole run.
        public var facts: Int { turns.map(\.facts).reduce(0, +) }

        /// The summary calls, over the whole run.
        public var summaries: [SummaryCall] { turns.flatMap(\.summaries) }

        /// The `memory` calls, over the whole run.
        public var memoryCalls: [String] { turns.flatMap(\.memoryCalls) }

        /// The answers that repeat a fact's source (`ContextEval.echoesSource`).
        public var echoes: Int { answers.filter { ContextEval.echoesSource($0.reply) }.count }

        /// Tool calls other than `memory` made while answering the questions: a model re-reading a file its
        /// context holds as a reference, which recalling should make unnecessary.
        public var questionCalls: [String] {
            turns.filter { $0.label.hasPrefix("question:") }.flatMap(\.tools).filter { $0 != MemoryTool.toolName }
        }

        /// The memory calls and the questions' other tool calls in words, for the report and the notes: empty
        /// when there were neither.
        var recalled: String {
            guard !memoryCalls.isEmpty || !questionCalls.isEmpty else { return "" }
            return "\(memoryCalls.count) memory call\(memoryCalls.count == 1 ? "" : "s")"
                + (memoryCalls.isEmpty ? "" : " (\(memoryCalls.joined(separator: "; ")))")
                + ", \(questionCalls.count) other tool call\(questionCalls.count == 1 ? "" : "s") in the questions"
        }

        /// The summary calls in words, for the report and the notes: empty when none were made.
        var summarised: String {
            let calls = summaries
            guard !calls.isEmpty else { return "" }
            return "\(calls.count) summar\(calls.count == 1 ? "y" : "ies") ("
                + calls.map(\.words).joined(separator: ", ") + ")"
        }

        /// The distillations in words, for the report and the notes: `none`, or the count and each one's time.
        var distilled: String {
            distillations.isEmpty
                ? "no distillations"
                : "\(distillations.count) distillation\(distillations.count == 1 ? "" : "s") ("
                    + distillations.map { String(format: "%.1f s", $0) }.joined(separator: ", ") + ")"
        }

        /// The tokens the context took after each condensation to a target, over the whole run.
        public var fills: [Int] { turns.flatMap(\.fills) }

        /// For each condensation but the last, how many turns later the next one came: the turns a condensation
        /// bought. Several condensations in one turn count once.
        public var condensationGaps: [Int] {
            let at = turns.filter { !$0.condensations.isEmpty }.map(\.number)
            return zip(at, at.dropFirst()).map { $1 - $0 }
        }

        /// The fill after condensing and the turns between condensations in words, for the report and the notes:
        /// empty when there were no fills to report.
        var condensing: String {
            guard !fills.isEmpty else { return "" }
            let median = ContextEval.percentile(fills.map(Double.init), 0.5).map { Int($0) } ?? 0
            let share =
                window.map { String(format: " (%.0f%% of the window)", 100 * Double(median) / Double($0)) } ?? ""
            let gaps = condensationGaps.map(String.init).joined(separator: ",")
            return "fill after condensing median \(median)\(share), turns between condensations [\(gaps)]"
        }

        /// The number of the first turn during which a condensation happened; nil when none did. The turns
        /// before it all fit in the window.
        public var firstCondensation: Int? { turns.first { !$0.condensations.isEmpty }?.number }

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
                    + "\(facts.total), \(verdicts); \(echoes) of \(answers.count) answers echo a fact's source",
                "\(condensations) condensations (first at turn \(firstCondensation.map(String.init) ?? "none")), "
                    + "\(cuts) cuts, \(references) references, \(self.facts) facts recorded, "
                    + (summaries.isEmpty ? "" : "\(summarised), ") + (recalled.isEmpty ? "" : "\(recalled), ")
                    + (condensing.isEmpty ? "" : "\(condensing), ")
                    + "and \(distilled) over \(turns.count) turns; "
                    + "tokens after a turn median "
                    + "\(ContextEval.percentile(tokens.map(Double.init), 0.5).map { String(Int($0)) } ?? "?"), max "
                    + "\(tokens.max().map(String.init) ?? "?"); time per turn median "
                    + String(
                        format: "%.1f s, p95 %.1f s", (ContextEval.percentile(milliseconds, 0.5) ?? 0) / 1000,
                        (ContextEval.percentile(milliseconds, 0.95) ?? 0) / 1000)
                    + String(format: "; load average %.0f then %.0f", load.start, load.end),
            ] + switches.map { "switched at \($0)" }
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
                    + "\(byID["task"] ?? "?")" + (byID["detail"].map { ", detail \($0)" } ?? "")
                    + (byID["release-date"].map { ", release date \($0)" } ?? "")
                    + ", \(echoes) answer\(echoes == 1 ? "" : "s") echoing a fact's source"
                    + ", \(condensations) condensations (first at turn "
                    + "\(firstCondensation.map(String.init) ?? "none")), \(cuts) cuts, \(references) references, "
                    + (self.facts == 0 && distillations.isEmpty ? "" : "\(self.facts) facts recorded, \(distilled), ")
                    + (summaries.isEmpty ? "" : "\(summarised), ") + (recalled.isEmpty ? "" : "\(recalled), ")
                    + (condensing.isEmpty ? "" : "\(condensing), ")
                    + (switches.isEmpty ? "" : "switched at \(switches.joined(separator: "; then at ")), ")
                    + "median "
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

    /// One `context.assessment` event as the eval's turn line shows it: the method, the tools chosen, the tools
    /// registered when they differ, and the time.
    ///
    /// - Parameter event: The event.
    /// - Returns: The line.
    static func assessmentLine(_ event: AuditEvent) -> String {
        func names(_ value: JSONValue?) -> String {
            guard case .array(let items)? = value else { return value?.stringValue ?? "?" }
            return items.compactMap(\.stringValue).joined(separator: ",")
        }
        let chosen = names(event.details["tools"])
        let registered = names(event.details["registered"])
        return "\(event.details["method"]?.stringValue ?? "?") \(chosen)"
            + (registered == chosen ? "" : " registered \(registered)")
            + (event.details["taskChanged"] == true ? " task" : "")
            + String(format: " (%.1f s)", event.details["seconds"]?.doubleValue ?? 0)
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
        let trail = ToolEventTrail()
        let audit = AuditLog(session: "context-eval", sink: TeeAuditSink([sink, trail]))
        let thread = strategy.open(
            model: model, tools: tools(audit), instructions: instructions, audit: audit)
        if strategy.linksToolEvents, let agent = (thread as? any AgentHolding)?.agent {
            agent.toolEvents = trail
        }
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
                reply = try await thread.send(prompt)
            } catch {
                reply = "error: \(error)"
                failed = true
            }
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let events = sink.events.dropFirst(first)
            var turn = Turn(
                number: turns.count + 1, label: label, reply: reply, failed: failed, seconds: seconds,
                tokens: await thread.occupiedTokens(),
                condensations: events.filter { $0.kind == .condensation }.map {
                    ($0.details["reason"]?.stringValue ?? "?") + ($0.details["floor"] == true ? ":floor" : "")
                },
                tools: events.filter { $0.kind == .toolCall }.map { $0.details["tool"]?.stringValue ?? "?" },
                cuts: events.filter { $0.kind == .presentationCut }.count,
                references: events.filter { $0.kind == .outputReferenced }.count,
                distillations: events.filter { $0.kind == .distillation }.map {
                    $0.details["seconds"]?.doubleValue ?? 0
                },
                facts: events.filter { $0.kind == .factRecorded }.count)
            turn.distilled = events.filter { $0.kind == .factRecorded && $0.details["method"] == "distilled" }.map {
                "\($0.details["subject"]?.stringValue ?? "") \($0.details["name"]?.stringValue ?? "") = "
                    + ($0.details["value"]?.stringValue ?? "")
            }
            turn.memoryCalls = events.filter { $0.kind == .memory }.map { event in
                let request = event.details["request"]?.stringValue ?? "?"
                guard event.details["action"] == "note" else {
                    return "\(request) -> \(event.details["target"]?.stringValue ?? "?") "
                        + (event.details["found"] == true ? "found" : "none")
                }
                return "\(request) -> "
                    + (event.details["noted"] == true
                        ? "noted" : "refused (\(event.details["failure"]?.stringValue ?? "?"))")
            }
            turn.assessments = events.filter { $0.kind == .assessment }.map(Self.assessmentLine)
            turn.taskChanges = events.filter { $0.kind == .assessment && $0.details["taskChanged"] == true }.count
            let targeted = events.filter { $0.kind == .condensation && $0.details["fillAfter"] != nil }
            turn.fills = targeted.compactMap { $0.details["fillAfter"]?.intValue }
            turn.targets = targeted.compactMap { $0.details["target"]?.intValue }
            turn.summaries = events.filter { $0.kind == .summary }.map {
                SummaryCall(
                    seconds: $0.details["seconds"]?.doubleValue ?? 0, combined: $0.details["combined"] == true,
                    failure: $0.details["failure"]?.stringValue)
            }
            turns.append(turn)
            onTurn(turn)
        }
        let replies = turns.suffix(scenario.questions.count).map(\.reply)
        let answers = zip(scenario.questions, replies).map { question, reply in
            Answer(question: question, reply: reply, verdict: question.score(reply))
        }
        var run = Run(
            strategy: strategy.name, model: model.selection.description, window: model.contextSize, turns: turns,
            answers: answers, load: (loadAtStart, loadAverage()), scenario: scenario.summary)
        run.summary = (thread as? any AgentHolding)?.agent.store.summary
        run.switches = (thread as? SwitchingThread)?.log ?? []
        return run
    }
}

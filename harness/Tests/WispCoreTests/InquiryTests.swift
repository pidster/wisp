import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// An asker that answers from a script and keeps what it was asked.
final class ScriptedAsker: Asker, Sendable {
    let outcomes: Mutex<[Question.Outcome]>
    let asked = Mutex<[Question]>([])
    let ways = ["terminal"]

    init(_ outcomes: [Question.Outcome]) { self.outcomes = Mutex(outcomes) }

    func ask(_ question: Question, box: InquiryBox, audit: AuditLog?) async -> Question.Reply {
        asked.withLock { $0.append(question) }
        return Question.Reply(outcomes.withLock { $0.isEmpty ? .declined : $0.removeFirst() }, via: "terminal")
    }

    var questions: [Question] { asked.withLock { $0 } }
}

/// The inquiry verb (ADR 0062): the question's limits and the rule on secrets, the thread's box, each face's asker,
/// the tool through the framework's tool loop, the pending kind, the command's endings, the policy, and the reader.
@Suite struct InquiryTests {
    /// A session in a temporary home, with a thread over `asker` that has only `ask`.
    struct Place {
        let place: ModelActionsTests.Place
        let session: Session

        init(config: String? = nil, entryPoint: EntryPoint = .chat, autoApprove: Bool = false) throws {
            place = try ModelActionsTests.Place(config: config)
            var dependencies = Session.Dependencies.testing(sink: place.sink)
            dependencies.puller = nil
            session = try Session.begin(
                .init(entryPoint: entryPoint, autoApprove: autoApprove), home: place.home, dependencies: dependencies)
        }

        /// A thread with `ask` alone, asking through `asker`.
        func thread(_ asker: any Asker, id: String = "t") throws -> WispThread {
            try session.thread(
                id: id, host: session.host(approver: DenyingApprover(reason: "no"), asker: asker),
                tools: .named(["ask"]))
        }

        /// The agent of `thread` on a model scripted with `steps`.
        func agent(_ thread: WispThread, steps: [ScriptedModel.Step]) throws -> Agent {
            try thread.openAgent(on: ResolvedModel(selection: .system, custom: ScriptedModel(steps: steps)))
        }

        func events(_ kind: AuditEvent.Kind, session: String = "t") -> [AuditEvent] {
            place.sink.events.filter { $0.kind == kind && $0.session == session }
        }

        func remove() { place.remove() }
    }

    /// An `ask` call of the question, with options when given.
    static func ask(_ question: String, options: [String]? = nil) -> ScriptedModel.Step {
        let encoded =
            options.map { opts in
                ", \"options\": "
                    + (String(data: (try? JSONEncoder().encode(opts)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]")
            } ?? ""
        return .call(name: "ask", arguments: "{\"question\": \"\(question)\"\(encoded)}")
    }

    @Test func theQuestionAndItsOptionsAreBoundedAndASecretIsRefusedByRule() throws {
        let valid = try Question.validate(text: "  Which config? ", options: ["a", "b"], thread: "t", timeout: nil)
        #expect(valid.text == "Which config?" && valid.options == ["a", "b"] && valid.isChoice)
        #expect(valid.id.count == 8 && valid.thread == "t" && valid.timeout == nil)
        let free = try Question.validate(text: "What is the codename?", options: [], thread: nil, timeout: .seconds(30))
        #expect(!free.isChoice && free.timeout == .seconds(30))
        func refused(_ text: String, _ options: [String]? = nil) -> Question.Refusal? {
            do {
                _ = try Question.validate(text: text, options: options, thread: nil, timeout: nil)
                return nil
            } catch {
                return error
            }
        }
        #expect(refused("") == .text("must say what you need to know"))
        #expect(refused(String(repeating: "x", count: 301)) == .text("must be at most 300 characters"))
        #expect(refused("one\n\ntwo") == .text("must be one paragraph"))
        #expect(refused("Which?", ["only"]) == .options("must be 2 to 6; leave them out for free text"))
        #expect(refused("Which?", ["1", "2", "3", "4", "5", "6", "7"]) != nil)
        #expect(refused("Which?", ["a", ""]) == .options("must each say something"))
        #expect(
            refused("Which?", ["a", String(repeating: "b", count: 81)])
                == .options("must each be at most 80 characters"))
        #expect(refused("Which?", ["a", "a"]) == .options("must differ from one another"))
        // The rule on secrets (D5): the words as words, in any case; "pinned" is not "PIN".
        for text in [
            "What is your password?", "Paste the API key for the service", "Give me the token", "your 2FA code?",
            "What are the login details", "the passphrase for the key", "What is the PIN",
        ] {
            #expect(refused(text) == .secret, "\(text)")
            #expect(Question.asksForSecret(text))
        }
        #expect(!Question.asksForSecret("Which pinned version did you mean?"))
        #expect(!Question.asksForSecret("Should I tokenise the input?"))
        #expect("\(Question.Refusal.secret)".hasPrefix("ask does not ask for secrets"))
    }

    @Test func anAnswerTypedOrPickedMapsToAnOutcomeAndACredentialShapedValueIsMasked() {
        let choice = Question(text: "Which?", options: ["~/.wisp", "./wisp.json"])
        #expect(choice.outcome(typed: nil) == .declined && choice.outcome(typed: "  ") == .declined)
        #expect(choice.outcome(typed: "2") == .chose("./wisp.json"))
        #expect(choice.outcome(typed: "./wisp.json") == .chose("./wisp.json"))
        #expect(choice.outcome(typed: "3") == .noneOfThese && choice.outcome(typed: "None of these") == .noneOfThese)
        #expect(choice.outcome(typed: "something else") == nil, "a choice takes no other text")
        let free = Question(text: "What is the codename?")
        #expect(free.outcome(typed: " BLUE HERON ") == .answered("BLUE HERON"))
        #expect(free.outcome(typed: "") == .declined)
        // The choice a face offers: the options, then none of these; typed text only for free text.
        let offered = choice.choice
        #expect(
            offered.kind == "question" && offered.options.map(\.value) == ["~/.wisp", "./wisp.json", "none of these"])
        #expect(!offered.acceptsText && free.choice.acceptsText && free.choice.options.isEmpty)
        // The answer scan (D5): a credential-shaped value is replaced by its marker, everywhere wisp records it.
        let leaked = Question.Outcome.answered("use AKIAIOSFODNN7QWERTYU for it").masked()
        #expect(leaked.outcome == .answered("use [REDACTED:aws-access-key#1] for it"))
        #expect(leaked.redacted == ["aws-access-key"])
        #expect(Question.Outcome.chose("a").masked() == (.chose("a"), []))
        #expect(Question.Outcome.declined.masked().outcome == .declined)
        // A long answer is cut with a note, inside the tool-result bound.
        let long = Question.Outcome.answered(String(repeating: "y", count: 3000)).masked().outcome
        #expect(long.answer?.utf8.count ?? 0 < 2100 && long.answer?.contains("[truncated: 3000 bytes") == true)
        #expect(Question.outcome(decision: "chose", text: "a") == .chose("a"))
        #expect(Question.outcome(decision: "none", text: nil) == .noneOfThese)
        #expect(Question.outcome(decision: "decline", text: nil) == .declined)
    }

    @Test func theBoxAdmitsOneWaitingQuestionTwoATurnAndNeverARepeat() throws {
        let box = InquiryBox(conversation: "t")
        let first = Question(text: "A?")
        try box.begin(first, turn: 1)
        #expect(box.waiting == first)
        #expect(throws: Question.Refusal.waiting) { try box.begin(Question(text: "B?"), turn: 1) }
        #expect(box.settle(first.id, outcome: .answered("x"), delivered: "tool")?.outcome == .answered("x"))
        #expect(box.waiting == nil)
        #expect(throws: Question.Refusal.repeated) { try box.begin(Question(text: "A?"), turn: 1) }
        let second = Question(text: "B?")
        try box.begin(second, turn: 1)
        box.settle(second.id, outcome: .declined)
        #expect(throws: Question.Refusal.turnLimit) { try box.begin(Question(text: "C?"), turn: 1) }
        // A new turn starts the count again, and the same text may be asked.
        try box.begin(Question(text: "A?"), turn: 2)
        let records = box.records
        #expect(records.count == 3 && records.map(\.turn) == [1, 1, 2])
        #expect(records[0].json.objectValue?["state"] == "answered" && records[0].json.objectValue?["answer"] == "x")
        #expect(records[2].json.objectValue?["state"] == "waiting" && box.records(turn: 2).count == 1)
        #expect(box.stillWaitingNote?.contains("your question \"A?\"") == true)
        // Withdrawing settles the one waiting; nothing waits after.
        #expect(box.withdraw(audit: nil)?.text == "A?")
        #expect(box.waiting == nil && box.stillWaitingNote == nil && box.withdraw(audit: nil) == nil)
        #expect(box.records.last?.outcome == .withdrawn)
        // Settling a question that is not waiting changes nothing.
        #expect(box.settle("nope", outcome: .declined) == nil)
    }

    /// What a scripted terminal saw: what the asker wrote, and the deadline each read was given.
    final class Recorded: Sendable {
        let written = Mutex<[String]>([])
        let deadlines = Mutex<[Duration?]>([])
    }

    /// A terminal asker over a scripted reader, keeping what it wrote and the deadline each read was given.
    final class Terminal: Sendable {
        let asker: TerminalAsker
        let recorded = Recorded()

        init(_ reads: [LineReader.Read], style: Style = .plain) {
            let queue = Mutex(reads)
            let recorded = recorded
            asker = TerminalAsker(
                style: style,
                read: { _, timeout in
                    recorded.deadlines.withLock { $0.append(timeout) }
                    return queue.withLock { $0.isEmpty ? .end : $0.removeFirst() }
                },
                write: { text in recorded.written.withLock { $0.append(text) } })
        }

        var written: [String] { recorded.written.withLock { $0 } }
        var deadlines: [Duration?] { recorded.deadlines.withLock { $0 } }
    }

    /// A terminal asker over `reads`.
    private func terminal(_ reads: [LineReader.Read]) -> Terminal { Terminal(reads) }

    @Test func plainChatsDialogIsTheModelsNumberedListReadUntilAnswered() async throws {
        let question = Question(text: "Which config?", options: ["~/.wisp", "./wisp.json"], thread: "chat")
        let dialog = TerminalAsker.render(question, style: .plain)
        #expect(dialog.contains("? the model asks (thread chat)") && dialog.contains("  Which config?"))
        #expect(dialog.contains("  1  ~/.wisp") && dialog.contains("  3  none of these"))
        #expect(dialog.contains("type a number, or press Enter to decline ›"))
        #expect(!dialog.contains("approve") && !dialog.contains("[y]"), "never styled as an approval")
        // Escaped, so a question cannot redraw the terminal.
        let sneaky = TerminalAsker.render(Question(text: "a\u{1B}[2Kb"), style: .plain)
        #expect(sneaky.contains("a\\e[2Kb"))
        let free = TerminalAsker.render(Question(text: "Codename?", timeout: .seconds(300)), style: .plain)
        #expect(free.contains("type your answer, or press Enter to decline; 5 min to answer"))
        let box = InquiryBox()
        // A number picks; no deadline by default, so the read is given none.
        let picked = terminal([.line("2")])
        #expect(await picked.asker.ask(question, box: box, audit: nil).outcome == .chose("./wisp.json"))
        #expect(picked.deadlines == [nil])
        #expect(picked.written.first?.contains("Which config?") == true)
        // Text that is no option is asked again; the third miss declines.
        let missed = terminal([.line("what"), .line("3")])
        #expect(await missed.asker.ask(question, box: box, audit: nil).outcome == .noneOfThese)
        #expect(missed.written.count == 2)
        let gaveUp = terminal([.line("x"), .line("y"), .line("z")])
        #expect(await gaveUp.asker.ask(question, box: box, audit: nil).outcome == .declined)
        // An empty line and end of input decline; typed text answers a free-text question.
        #expect(await terminal([.line("")]).asker.ask(question, box: box, audit: nil).outcome == .declined)
        #expect(await terminal([.end]).asker.ask(question, box: box, audit: nil).outcome == .declined)
        #expect(
            await terminal([.line("BLUE HERON")]).asker.ask(Question(text: "Codename?"), box: box, audit: nil).outcome
                == .answered("BLUE HERON"))
        // Ctrl-C ends the read: the turn stops. A deadline set is passed to the read and ends it.
        #expect(await terminal([.stopped]).asker.ask(question, box: box, audit: nil).outcome == .stopped)
        let bounded = terminal([.expired])
        let timed = Question(text: "Codename?", timeout: .seconds(30))
        #expect(await bounded.asker.ask(timed, box: box, audit: nil).outcome == .unanswered(.seconds(30)))
        #expect(bounded.deadlines.first.flatMap { $0 }.map { $0 <= .seconds(30) && $0 > .seconds(29) } == true)
    }

    @Test func theLineReaderEndsOnALineTheStopOrTheDeadline() async throws {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let reader = LineReader(descriptor: fds[0], pollInterval: .milliseconds(10))
        // A deadline with nothing written.
        #expect(await reader.read(stop: nil, within: .milliseconds(50)) == .expired)
        // A stop asked for while it waits.
        let stop = TurnStop()
        let reading = Task { await reader.read(stop: stop, within: nil) }
        try await Task.sleep(for: .milliseconds(30))
        stop.request()
        #expect(await reading.value == .stopped)
        // A line, without its newline, and nothing past it consumed; then end of input.
        _ = "yes\r\nmore\n".withCString { write(fds[1], $0, strlen($0)) }
        #expect(await reader.read(stop: nil, within: .seconds(5)) == .line("yes"))
        #expect(await reader.read(stop: nil, within: .seconds(5)) == .line("more"))
        close(fds[1])
        fds[1] = open("/dev/null", O_RDONLY)
        #expect(await reader.read(stop: nil, within: .seconds(5)) == .end)
    }

    @Test func theToolCarriesTheAnswerIntoTheTurnAsATheRecordAndAPersonFact() async throws {
        let place = try Place()
        defer { place.remove() }
        let asker = ScriptedAsker([.answered("BLUE HERON")])
        let thread = try place.thread(asker)
        #expect(thread.tools.map(\.name) == ["ask"])
        let agent = try place.agent(thread, steps: [Self.ask("What is the codename?"), .say("{tool}")])
        let reply = try await agent.respond(to: "name it")
        #expect(reply.text == "answer: BLUE HERON\n(from the person)")
        #expect(asker.questions.map(\.text) == ["What is the codename?"] && asker.questions.first?.thread == "t")
        // Audited on the thread: requested with the ways and the call, settled answered via the terminal, delivered tool.
        let requested = try #require(place.events(.inquiryRequested).first)
        #expect(
            requested.details["question"] == "What is the codename?"
                && requested.details["ways"] == .array(["terminal"]))
        #expect(requested.details["call"]?.stringValue?.count == 8 && requested.details["timeoutSeconds"] == nil)
        let settled = try #require(place.events(.inquirySettled).first)
        #expect(settled.details["outcome"] == "answered" && settled.details["answer"] == "BLUE HERON")
        #expect(settled.details["via"] == "terminal" && settled.details["delivered"] == "tool")
        #expect(settled.details["inquiry"] == requested.details["inquiry"])
        // The answer is the thread's fact, the person's, named by the question (D14).
        let fact = try #require(agent.allFacts.first { $0.identity.subject == "answer" })
        #expect(fact.source == .person && fact.value == "BLUE HERON" && fact.identity.name == "What is the codename?")
        #expect(reply.facts.contains { $0.id == fact.id })
        #expect(thread.inquiries.records.first?.outcome == .answered("BLUE HERON"))
        #expect(thread.inquiries.records.first?.delivered == "tool")
    }

    @Test func theToolRefusesSecretsLimitsAndRepeatsAndTellsTheModelWhatToDoOnSilence() async throws {
        let place = try Place()
        defer { place.remove() }
        let asker = ScriptedAsker([
            .chose("b"), .declined, .chose("a"), .chose("a"), .unanswered(.seconds(30)), .stopped,
        ])
        let thread = try place.thread(asker)
        let agent = try place.agent(
            thread,
            steps: [
                Self.ask("What is your password?"), .say("{tool}"),
                Self.ask("Which?", options: ["a", "b"]), .say("{tool}"),
                Self.ask("Which?", options: ["a", "b"]), .say("{tool}"),
            ])
        #expect(
            try await agent.respond(to: "1").text
                == "error: ask does not ask for secrets; tell the person what is needed and where to set it")
        let refused = try #require(place.events(.inquirySettled).first)
        #expect(refused.details["outcome"] == "refused" && asker.questions.isEmpty)
        #expect(try await agent.respond(to: "2").text == "chose: b\n(from the person)")
        // The same question again in the same turn would be refused; in a new turn it is asked.
        #expect(
            try await agent.respond(to: "3").text
                == "the person declined to answer. Do not ask this again; say in your reply what you needed")
        let box = thread.inquiries
        #expect(box.records.map(\.outcome) == [.chose("b"), .declined])
        // Three questions in one turn: the third is refused.
        let busy = try place.agent(
            thread,
            steps: [
                Self.ask("One?"), Self.ask("Two?"), Self.ask("Three?"), .say("{tool}"),
            ])
        #expect(try await busy.respond(to: "4").text.hasPrefix("error: you have asked 2 questions this turn"))
        // No answer within a deadline, and a stopped turn, each say so without an answer.
        let silent = try place.agent(thread, steps: [Self.ask("Five?"), .say("{tool}")])
        #expect(try await silent.respond(to: "5").text.hasPrefix("no answer within 30 s. Do not guess"))
        #expect(place.events(.inquirySettled).last?.details["outcome"] == "unanswered")
        let stopped = try place.agent(thread, steps: [Self.ask("Six?"), .say("{tool}")])
        #expect(try await stopped.respond(to: "6").text == "the person stopped the turn; the question was withdrawn")
        #expect(place.events(.inquirySettled).last?.details["outcome"] == "stopped")
        // An answer declined or unanswered records no fact.
        #expect(!silent.allFacts.contains { $0.identity.subject == "answer" })
    }

    @Test func nobodyIsAskedUnderRespondYesOrAnMCPServerWithTheChannelOff() async throws {
        let respond = try Place(entryPoint: .respond)
        defer { respond.remove() }
        let thread = try respond.session.thread(
            id: "r", approver: DenyingApprover(reason: "no"), tools: .named(["ask"]))
        let agent = try respond.agent(thread, steps: [Self.ask("Which?", options: ["a", "b"]), .say("{tool}")])
        #expect(
            try await agent.respond(to: "go").text
                == "no person can answer here (wisp respond); say in your reply what you need")
        #expect(respond.events(.inquirySettled, session: "r").first?.details["outcome"] == "refused")
        #expect(respond.events(.inquiryRequested, session: "r").first?.details["ways"] == .array([]))
        // --yes answers approvals ahead of time, never a question.
        let yes = try Place(entryPoint: .chat, autoApprove: true)
        defer { yes.remove() }
        let asked = ScriptedAsker([.answered("x")])
        let auto = try yes.agent(try yes.thread(asked), steps: [Self.ask("Which?"), .say("{tool}")])
        #expect(
            try await auto.respond(to: "go").text
                == "no person can answer here (--yes); say in your reply what you need")
        #expect(asked.questions.isEmpty)
        // An MCP server with approval.outOfBand off has no trusted way to ask.
        let off = try Place(config: #"{"approval":{"outOfBand":false}}"#, entryPoint: .mcp)
        defer { off.remove() }
        #expect(off.session.mcpAsker(elicitation: { nil }) is NobodyAsker)
        #expect(off.session.mcpAsker(elicitation: { nil }).ways.isEmpty)
        let on = try Place(entryPoint: .mcp)
        defer { on.remove() }
        #expect(on.session.mcpAsker(elicitation: { nil }).ways == ["pending"])
        // The elicitation leg is behind inquiry.elicitation (D8): off, a client's dialog is never consulted.
        let leg: OutOfBandAsker.Ask = { _ in .answered(.declined) }
        #expect(on.session.mcpAsker(elicitation: { leg }).ways == ["pending"])
        let switched = try Place(config: #"{"inquiry":{"elicitation":true}}"#, entryPoint: .mcp)
        defer { switched.remove() }
        #expect(switched.session.mcpAsker(elicitation: { leg }).ways == ["elicitation", "pending"])
    }

    @Test func theToolIsOffByDefaultAndOnWhenNamedOrTurnedOn() throws {
        let place = try ModelActionsTests.Place()
        defer { place.remove() }
        let deny = DenyingApprover(reason: "x")
        #expect(ToolRegistry.builtInNames.last == AskTool.toolName)
        #expect(Config().resolved.toolsAsk == false && ConfigSettings.defaultValue("tools.ask") == false)
        #expect(ConfigSettings.defaultValue("inquiry.timeoutSeconds") == 0)
        #expect(ConfigSettings.defaultValue("inquiry.elicitation") == false)
        let session = try place.session(.chat)
        #expect(!(try session.thread(id: "all", approver: deny)).tools.map(\.name).contains("ask"))
        #expect(try session.thread(id: "a", approver: deny, tools: .named(["ask"])).tools.map(\.name) == ["ask"])
        try Data(#"{"tools": {"ask": true}, "inquiry": {"timeoutSeconds": 300}}"#.utf8).write(to: place.home.configFile)
        let on = try place.session(.chat)
        #expect(try on.thread(id: "all", approver: deny).tools.map(\.name).contains("ask"))
        #expect(on.toolNames.contains("ask") && !on.toolNames.contains("models"))
        #expect(on.config.inquiryTimeout == .seconds(300))
        // The deadline has a floor of 10 s and a ceiling of a day; 0 waits until answered.
        try Data(#"{"inquiry": {"timeoutSeconds": 3}}"#.utf8).write(to: place.home.configFile)
        #expect(try place.session(.chat).config.inquiryTimeout == .seconds(10))
        #expect(try ConfigEdit.value("on", for: #require(ConfigSettings.setting("tools.ask"))) == .bool(true))
        // The catalogue's tool answers that nobody can be asked, and says its limits.
        let catalogue = AskTool()
        #expect(catalogue.limits.contains("Waits until the person answers") && catalogue.examplePrompt.contains("ask"))
        #expect(AskTool(timeout: .seconds(300)).limits.contains("The person has 5 min to answer"))
        #expect(catalogue.description.contains("Not for permission") && catalogue.description.count < 300)
        // The introspection view shows the settings.
        let view = Introspection(home: place.home, config: on.config).configuration.objectValue
        #expect(view?["tools"]?.objectValue?["ask"] == true)
        #expect(view?["inquiry"]?.objectValue?["timeoutSeconds"] == 300)
    }

    @Test func theJSONFaceAsksWithAChoiceLineOfKindQuestion() async throws {
        let router = LineRouter()
        let sent = SentLines()
        let asker = JSONAsker(router: router, send: sent.keep)
        let box = InquiryBox()
        let question = Question(text: "Which?", options: ["a", "b"], thread: "chat")
        async let asked = asker.ask(question, box: box, audit: nil)
        let line = try await firstValue("the choice line") { sent.of("choice").first }
        #expect(line["kind"] == "question" && line["title"] == "Which?" && line["thread"] == "chat")
        #expect(line["acceptsText"] == false && line["source"] == nil)
        #expect(line["options"]?.arrayValue?.map { $0.objectValue?["value"] } == ["a", "b", "none of these"])
        let id = try #require(line["id"]?.stringValue)
        router.receive(#"{"type":"choose","id":"\#(id)","value":"b"}"#)
        #expect(await asked == Question.Reply(.chose("b"), via: "json"))
        // Free text typed; no value declines.
        async let typed = asker.ask(Question(text: "Codename?"), box: box, audit: nil)
        let free = try await firstValue("the second choice") { sent.of("choice").dropFirst().first }
        #expect(free["acceptsText"] == true)
        router.receive(#"{"type":"choose","id":"\#(free["id"]?.stringValue ?? "")","value":"BLUE HERON"}"#)
        #expect(await typed.outcome == .answered("BLUE HERON"))
        async let declined = asker.ask(Question(text: "Codename?"), box: box, audit: nil)
        let third = try await firstValue("the third choice") { sent.of("choice").dropFirst(2).first }
        router.receive(#"{"type":"choose","id":"\#(third["id"]?.stringValue ?? "")"}"#)
        #expect(await declined.outcome == .declined)
        // A deadline that lapses withdraws the choice, so the front end closes it.
        let bounded = await asker.ask(Question(text: "Codename?", timeout: .milliseconds(50)), box: box, audit: nil)
        #expect(bounded.outcome == .unanswered(.milliseconds(50)) && bounded.via == nil)
        let withdrawn = try await firstValue("withdrawn") { sent.of("withdrawn").first }
        #expect(withdrawn["id"] == sent.of("choice").last?["id"])
        // The turn's stop withdraws the question: the turn stops.
        let stop = TurnStop()
        let stopping = Task {
            await TurnStop.$current.withValue(stop) {
                await asker.ask(Question(text: "Codename?"), box: box, audit: nil)
            }
        }
        _ = try await firstValue("the fifth choice") { sent.of("choice").dropFirst(4).first }
        stop.request()
        #expect(await stopping.value.outcome == .stopped)
        #expect(sent.of("withdrawn").count == 2)
    }

    @Test func aQuestionIsFiledBoundAnsweredOnceAndStaleWhenItsServerHasGone() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let question = Question(text: "Which config?", options: ["~/.wisp", "./wisp.json"], thread: "git")
        let request = PendingApprovals.request(asking: question, client: "claude-code")
        #expect(request.kind == .question && request.id == question.id && request.question == "Which config?")
        #expect(request.options == ["~/.wisp", "./wisp.json"] && request.expiresAt == nil, "no expiry by default")
        #expect(request.asked?.text == "Which config?" && request.asked?.timeout == nil)
        try channel.file(request)
        #expect(
            FileManager.default.fileExists(
                atPath: channel.directory.appending(path: "\(request.id).question.json").path))
        // Listed under its kind, and never as a command or a fact: a 0.23 wisp lists only those suffixes.
        #expect(channel.waiting(.question).map(\.id) == [request.id])
        #expect(channel.waiting(.command).isEmpty && channel.waiting(.fact).isEmpty)
        #expect(try channel.request(id: request.id).binding == request.binding)
        // A wrong decision, text that is no option, and a command's word are refused before anything is written.
        #expect(throws: PendingApprovals.Failure.otherKind(request.id, .question)) {
            try channel.answer(request.id, decision: "once", via: "cli")
        }
        #expect(throws: PendingApprovals.Failure.self) {
            try channel.answer(request.id, decision: "chose", text: "nope", via: "cli")
        }
        #expect(throws: PendingApprovals.Failure.self) {
            try channel.answer(request.id, decision: "answer", text: "typed", via: "cli")
        }
        #expect(throws: PendingApprovals.Failure.invalidDecision("maybe")) {
            try channel.answer(request.id, decision: "maybe", via: "cli")
        }
        #expect(channel.take(request) == nil)
        // The first answer wins; the second is refused; the server takes it with its text.
        try channel.answer(request.id, decision: "chose", text: "./wisp.json", via: "cli")
        #expect(throws: PendingApprovals.Failure.answered(request.id)) {
            try channel.answer(request.id, decision: "none", via: "tui")
        }
        guard case .answer(let answer)? = channel.take(request) else {
            Issue.record("no answer taken")
            return
        }
        #expect(answer.decision == "chose" && answer.text == "./wisp.json" && answer.via == "cli")
        #expect(channel.waiting(.question).isEmpty && channel.delivery(of: request.id) == .taken)
        // An altered request is refused: the question in the file is not the one the binding covers.
        let altered = PendingApprovals.request(asking: Question(text: "Original?"), client: nil)
        try channel.file(altered)
        var edited = try channel.request(id: altered.id)
        edited.question = "Changed?"
        try PendingApprovals.encoded(edited).write(to: channel.directory.appending(path: "\(altered.id).question.json"))
        #expect(throws: PendingApprovals.Failure.altered(altered.id)) {
            try channel.answer(altered.id, decision: "decline", via: "cli")
        }
        channel.withdraw(altered)
        // A replayed answer (another request's) is rejected and the request stays.
        let a = PendingApprovals.request(asking: Question(text: "A?"), client: nil)
        let b = PendingApprovals.request(asking: Question(text: "B?"), client: nil)
        try channel.file(a)
        try channel.file(b)
        try channel.answer(a.id, decision: "decline", via: "cli")
        let stolen = try Data(contentsOf: channel.directory.appending(path: "\(a.id).answer.json"))
        try stolen.write(to: channel.directory.appending(path: "\(b.id).answer.json"))
        #expect(channel.take(b) == .rejected("the answer was not bound to this request") && channel.isFiled(b))
        _ = channel.take(a)
        // A free-text question takes an answer with text, and declines; with a deadline, it expires.
        let free = PendingApprovals.request(
            asking: Question(text: "Codename?", timeout: .seconds(30)), client: nil,
            now: Date(timeIntervalSince1970: 1_000_000))
        #expect(free.expiresAt == Date(timeIntervalSince1970: 1_000_030) && free.asked?.timeout == .seconds(30))
        try channel.file(free)
        #expect(channel.waiting(.question, now: Date(timeIntervalSince1970: 1_000_031)).map(\.id) == [b.id], "expired")
        #expect(
            Set(channel.waiting(.question, now: Date(timeIntervalSince1970: 1_000_010)).map(\.id)) == [b.id, free.id])
        // Stale when the server has gone: only its thread could take the answer.
        #expect(channel.waiting(.question, now: Date(timeIntervalSince1970: 1_000_010)) { _ in false }.isEmpty)
        #expect(
            channel.sweep(now: Date(timeIntervalSince1970: 1_000_010)) { _ in false }.map(\.id).sorted()
                == [b.id, free.id].sorted())
        #expect("\(PendingApprovals.Failure.otherKind("a", .question))".contains("wisp questions answer or decline"))
    }

    @Test func theCommandsEndingsAndTheListing() throws {
        let question = Question(text: "Which config?", options: ["a", "b"], thread: "git")
        let request = PendingApprovals.request(
            asking: question, client: "claude-code", now: Date(timeIntervalSince1970: 0))
        #expect(
            PendingAnswer.ending(of: request, decision: "chose", delivery: .taken)
                == .printed("answered: Which config?; thread git reads it on its next turn"))
        #expect(
            PendingAnswer.ending(of: request, decision: "decline", delivery: .waiting)
                == .printed(
                    "declined: Which config?; thread git reads it on its next turn; wisp has not read the answer yet"))
        #expect(
            PendingAnswer.ending(of: request, decision: "answer", delivery: .tooLate)
                == .failed("thread git closed first; your answer was not used"))
        #expect(
            PendingAnswer.ending(for: .otherKind("x", .question))
                == .usage("\(PendingApprovals.Failure.otherKind("x", .question))"))
        let piped = ListingLayout.questions([request], width: nil, now: Date(timeIntervalSince1970: 42))
        #expect(piped == ["\(request.id)\t42\tclaude-code/git\ta | b\tWhich config?"])
        let shown = ListingLayout.questions([request], width: 80, now: Date(timeIntervalSince1970: 42))
        #expect(
            shown.first?.hasPrefix("ID") == true && shown.count == 2 && shown[1].contains("42 s")
                && shown[1].contains("a | b"))
        let free = PendingApprovals.request(asking: Question(text: "Codename?"), client: nil)
        #expect(ListingLayout.questions([free], width: 80)[1].contains("free text"))
        // The notification names the question and the command that answers it, once.
        let message = OutOfBandAsker.message(for: request)
        #expect(
            message.title == "wisp: the model asks"
                && message.body == "Which config? — wisp questions answer \(request.id)")
        #expect(message.subtitle == "claude-code, thread git")
    }

    @Test func theRelayShowsAQuestionAsAChoiceAndWritesTheAnswer() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let sink = MemoryAuditSink()
        #expect(PendingRelay.kinds(declared: { $0 == "answer-questions" }) == [.question])
        let relay = PendingRelay(
            channel: channel, router: router, audit: AuditLog(session: "chat", sink: sink), kinds: [.question],
            send: sent.keep)
        let request = PendingApprovals.request(
            asking: Question(text: "Which?", options: ["a", "b"], thread: "git"), client: "claude-code")
        try channel.file(request)
        relay.poll()
        relay.poll()
        let shown = sent.of("choice")
        #expect(shown.count == 1 && sent.of("approval").isEmpty)
        let line = try #require(shown.first)
        #expect(line["id"] == .string("mcp-\(request.id)") && line["kind"] == "question" && line["source"] == "mcp")
        #expect(line["thread"] == "git" && line["client"] == "claude-code" && line["request"] == .string(request.id))
        #expect(line["options"]?.arrayValue?.count == 3)
        router.receive(#"{"type":"choose","id":"mcp-\#(request.id)","value":"b"}"#)
        let taken = try await firstValue("the answer written") { channel.take(request) }
        guard case .answer(let answer) = taken else {
            Issue.record("no answer written: \(taken)")
            return
        }
        #expect(answer.decision == "chose" && answer.text == "b" && answer.via == "tui")
        #expect(sink.events.last?.kind == .inquiryAnswered && sink.events.last?.details["via"] == "tui")
        relay.poll()
        #expect(sent.of("withdrawn").map { $0["id"] } == [.string("mcp-\(request.id)")])
        // A question a command's front end does not declare is not shown.
        let commandsOnly = PendingRelay(
            channel: channel, router: router, audit: nil, kinds: [.command], send: sent.keep)
        try channel.file(PendingApprovals.request(asking: Question(text: "Other?"), client: nil))
        commandsOnly.poll()
        #expect(sent.of("choice").count == 1)
    }

    @Test func theModelIsRefusedAnsweringItsOwnQuestion() {
        let policy = CommandPolicy.default
        #expect(policy.check("wisp questions answer a1b2c3d4") != .allowed)
        #expect(policy.check("wisp questions decline a1b2c3d4") != .allowed)
        #expect(policy.check("echo x; 'wisp' \"questions\" answer a1") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp questions answer a1") != .allowed)
        #expect(policy.check("wisp questions pending") == .allowed)
        #expect(policy.check("wisp questions") == .allowed)
    }

    @Test func theAnswerReaderFlagsAClaimedAnswerNoAskCallGave() {
        let tools = ["run_command", "ask"]
        let asked = TurnCalls.Call(
            id: nil, call: nil, tool: "ask", arguments: #"{"question":"Which?"}"#, command: nil, exitStatus: nil,
            output: "chose: b\n(from the person)", error: nil)
        let declined = TurnCalls.Call(
            id: nil, call: nil, tool: "ask", arguments: #"{"question":"Which?"}"#, command: nil, exitStatus: nil,
            output: "the person declined to answer. Do not ask this again; say in your reply what you needed",
            error: nil)
        for reply in [
            "You chose b, so I used it.", "As you confirmed, the file is replaced.", "The person said to keep it.",
            "Per your answer, I went with ./wisp.json.", "You told me the codename is BLUE HERON.",
        ] {
            let claims = ReplyVerification.claims(in: reply, calls: [], tools: tools)
            #expect(claims.count == 1 && claims.first?.reader == .answer, "\(reply)")
            #expect(claims.first?.reason == "no ask call was answered by the person")
            #expect(ReplyVerification.claims(in: reply, calls: [asked], tools: tools).isEmpty, "\(reply)")
            #expect(ReplyVerification.claims(in: reply, calls: [], tools: tools, earlier: [asked]).isEmpty)
            // An answer that reached the thread as a note after a park is a fact, not a call.
            #expect(ReplyVerification.claims(in: reply, calls: [], tools: tools, answered: true).isEmpty)
        }
        #expect(ReplyVerification.claims(in: "You chose b.", calls: [declined], tools: tools).count == 1)
        #expect(
            ReplyVerification.claims(in: "You could choose either; tell me which.", calls: [], tools: tools).isEmpty)
        #expect(ReplyVerification.claims(in: "I chose the first file.", calls: [], tools: tools).isEmpty)
    }

    @Test func chatShowsTheQuestionsEventsAndPausesItsWorkingLine() {
        let question = Question(text: "Which config?", options: ["a", "b"], thread: "t")
        let requested = AuditEvent(
            session: "t", kind: .inquiryRequested,
            details: AuditEvent.Details.inquiryRequested(question, ways: ["terminal"], call: "c1"))
        #expect(ChatEvents.render(requested, style: .plain) == "  ? the model asks: Which config?")
        #expect(ChatEvents.progress(requested) == "waiting for the person's answer: Which config?")
        let activity = ChatActivity()
        activity.begin(turn: true)
        activity.apply(requested)
        #expect(activity.current?.asking == true && activity.current?.doing == "waiting for your answer")
        let settled = AuditEvent(
            session: "t", kind: .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: .answered("[REDACTED:aws-access-key#1]"), via: "terminal", delivered: "tool",
                redacted: ["aws-access-key"], seconds: 2))
        #expect(
            ChatEvents.render(settled, style: .plain)
                == "  · a credential-shaped value in your answer was masked (aws-access-key) and not passed on")
        activity.apply(settled)
        #expect(activity.current?.asking == false)
        let quiet = AuditEvent(
            session: "t", kind: .inquirySettled,
            details: AuditEvent.Details.inquirySettled(
                question, outcome: .chose("a"), via: "terminal", delivered: "tool", redacted: []))
        #expect(ChatEvents.render(quiet, style: .plain) == nil, "the dialog showed the answer")
        let parked = AuditEvent(
            session: "t", kind: .inquiryParked, details: AuditEvent.Details.inquiryParked(question, waitedSeconds: 60))
        #expect(
            ChatEvents.render(parked, style: .plain)
                == "  · the question waits for you: wisp questions answer \(question.id)")
        // Every kind has its documented keys, as the others do.
        for kind in [AuditEvent.Kind.inquiryRequested, .inquiryParked, .inquiryAnswered, .inquirySettled] {
            #expect(!AuditEvent.fields(for: kind).isEmpty, "\(kind.rawValue)")
            #expect(AuditEvent.Kind(rawValue: kind.rawValue) == kind)
        }
        #expect(settled.summary.contains("inquiry.settled session=t") && settled.summary.contains("outcome=answered"))
    }
}

extension PendingApprovals {
    /// `request` encoded as the channel files it, for a test that alters a file.
    static func encoded(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(request)
    }
}

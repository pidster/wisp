import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The model's `models` tool (ADR 0059): off by default, its listing bounded and paged, every change it asks for an
/// approval request of its own kind (a pull asked every time and never covered by an earlier answer), `trust` the
/// person's alone, and a pull it asked for running in the background, its end a note in the conversation.
@Suite struct ModelsToolTests {
    /// Answers each request from a script, in order, and keeps each request it was asked; once the script runs out it
    /// refuses.
    final class Answering: Approver {
        let answers: Mutex<[ApprovalDecision]>
        let asked = Mutex<[ApprovalRequest]>([])

        init(_ answers: [ApprovalDecision]) { self.answers = Mutex(answers) }

        func decide(_ request: ApprovalRequest) async -> ApprovalDecision {
            asked.withLock { $0.append(request) }
            return answers.withLock { $0.isEmpty ? .denied("no more answers") : $0.removeFirst() }
        }

        var requests: [ApprovalRequest] { asked.withLock { $0 } }
    }

    /// A session in a temporary home pulling with `puller`, its conversation `t`'s log, and a gate over `approver`.
    struct Place {
        let place: ModelActionsTests.Place
        let session: Session
        let log: AuditLog
        let gate: ApprovalGate

        init(config: String? = nil, puller: (any ModelPuller)? = FakePuller(), approver: any Approver) throws {
            place = try ModelActionsTests.Place(config: config)
            session = try place.session(.mcp, puller: puller)
            log = session.audit.log(forSession: "t")
            gate = ApprovalGate(
                classifier: RuleRiskClassifier.standard, approver: approver,
                threshold: session.config.approvalThreshold,
                audit: log, sessionApprovals: session.sessionApprovals)
        }

        /// The tool as a thread would build it, listing `listing` when given.
        func tool(listing: ModelListing.Listing? = nil, current: ModelSelection? = .system) -> ModelsTool {
            var actions = ModelActions(session: session, face: .tool, audit: log)
            if let listing { actions.listing = { _ in listing } }
            return ModelsTool(actions: actions, gate: gate, conversation: "t", current: current)
        }

        /// The events of `kind`.
        func events(_ kind: AuditEvent.Kind) -> [AuditEvent] { place.events(kind) }

        func remove() { place.remove() }
    }

    /// Calls the tool.
    private func call(_ tool: ModelsTool, _ action: String, _ name: String? = nil, page: Int? = nil) async -> String {
        await tool.call(arguments: .init(action: action, name: name, page: page))
    }

    @Test func theToolIsOffByDefaultAndOnWhenNamedOrTurnedOn() throws {
        let place = try ModelActionsTests.Place()
        defer { place.remove() }
        let deny = DenyingApprover(reason: "x")
        #expect(ToolRegistry.builtInNames.last == ModelsTool.toolName)
        #expect(Config().resolved.toolsModels == false && ConfigSettings.defaultValue("tools.models") == false)
        let session = try place.session(.mcp)
        #expect(!(try session.thread(id: "all", approver: deny)).tools.map(\.name).contains("models"))
        // MCP's git thread stays run_command alone; a list that names it gets it.
        #expect(try session.thread(id: "git", approver: deny, tools: .named(["run_command"])).tools.count == 1)
        #expect(try session.thread(id: "m", approver: deny, tools: .named(["models"])).tools.map(\.name) == ["models"])
        // With tools.models on, a conversation given every tool gets it.
        try Data(#"{"tools": {"models": true}}"#.utf8).write(to: place.home.configFile)
        let on = try place.session(.mcp)
        #expect(try on.thread(id: "all", approver: deny).tools.map(\.name).contains("models"))
        #expect(on.toolNames.contains("models") && !on.toolNames.contains("memory"))
        // A catalogue's tool answers that models cannot be managed there.
        #expect(ToolRegistry().all.contains { $0.name == "models" })
    }

    @Test func listAndShowAnswerAtOnceBoundedAndPaged() async throws {
        let place = try Place(approver: Answering([]))
        defer { place.remove() }
        let entries = (1...45).map { number in
            ModelListing.Entry(
                selection: .ollama("model-\(number)"), parameters: "8B", bytes: 5_000_000_000,
                capabilities: ["toolCalling"], enabled: number != 3)
        }
        let listing = ModelListing.Listing(
            entries: [.init(selection: .system, capabilities: ["toolCalling"])] + entries,
            unreachable: ["lmstudio: no server"])
        let tool = place.tool(listing: listing)
        let first = await call(tool, "list")
        let lines = first.split(separator: "\n").map(String.init)
        #expect(lines.first == "* system | on-device | enabled | tools")
        #expect(lines.contains("ollama:model-1 | Ollama | 8B | 5 GB | enabled | tools"))
        #expect(lines.contains("ollama:model-3 | Ollama | 8B | 5 GB | disabled | tools"))
        #expect(lines.last == "page 1 of 3; list with page 2 for more")
        #expect(lines.contains("(lmstudio: no server)"))
        #expect(first.utf8.count <= ModelsTool.maxBytes)
        let last = await call(tool, "list", page: 9)
        #expect(last.hasSuffix("page 3 of 3") && last.contains("ollama:model-45"))
        // show gives every fact the listing has; a name not listed says so.
        let shown = await call(tool, "show", "ollama:model-2")
        #expect(
            shown.contains("model: ollama:model-2") && shown.contains("params: 8B") && shown.contains("usable: yes"))
        #expect(
            await call(tool, "show", "ollama:nope")
                == "error: no model ollama:nope is listed; models list shows the names")
        #expect(await call(tool, "show") == "error: show needs name, as list names the model")
        // Reading asks nobody and changes nothing.
        #expect(place.events(.approvalRequested).isEmpty && place.events(.configChange).isEmpty)
    }

    @Test func trustSwitchAndUnknownActionsAreRefusedToTheModel() async throws {
        let approver = Answering([.approved(.once)])
        let place = try Place(approver: approver)
        defer { place.remove() }
        let tool = place.tool()
        #expect((await call(tool, "trust", "ornith-ai")).hasPrefix("error: trusting a publisher is the person's alone"))
        #expect(await call(tool, "switch", "ollama:x") == "error: switch is not offered to the model")
        #expect(await call(tool, "frob") == "error: action must be list, show, pull, enable, disable, or check")
        #expect(approver.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: place.session.home.configFile.path))
        // Without a gate a change is refused; without actions nothing is managed.
        let ungated = ModelsTool(actions: ModelActions(session: place.session, face: .tool))
        #expect(await call(ungated, "enable", "ollama:x") == "error: not approved: nobody can be asked here")
        #expect(await call(ModelsTool(), "list") == "error: models cannot be managed here")
    }

    @Test func aPullAsksEveryTimeAndRunsInTheBackgroundEndingInANote() async throws {
        // The person answers "always" twice: each pull is still asked, and approved for that pull alone.
        let approver = Answering([.approved(.always), .approved(.always)])
        let place = try Place(approver: approver)
        defer { place.remove() }
        let notes = Mutex<[String]>([])
        place.session.notices.watch("t") { note in notes.withLock { $0.append(note) } }
        let tool = place.tool()
        let reply = await call(tool, "pull", "ornith-ai/q")
        #expect(reply.hasPrefix("pulling ornith-ai/q in the background (approval "))
        #expect(
            reply.hasSuffix(
                "about 2 GB in 2 of 3 files. Its end will arrive as a note in this conversation; do not call models to check on it."
            ))
        await place.session.modelPulls.wait(for: "ornith-ai/q")
        try await eventually("the note") { !notes.withLock { $0 }.isEmpty }
        // The request was its own kind, with the publisher, the download, and the licence beside the rule's reason.
        let request = try #require(approver.requests.first)
        #expect(request.command == "models pull ornith-ai/q" && request.kind == .modelAction(pull: true))
        #expect(request.assessment.reasons.contains("downloads a model from Hugging Face"))
        #expect(
            request.assessment.reasons.contains { $0.hasPrefix("downloads 2 GB in 2 of 3 files from Hugging Face") })
        #expect(request.assessment.reasons.contains { $0.contains("publisher ornith-ai is not trusted") })
        #expect(request.assessment.reasons.contains { $0.hasPrefix("licence: apache-2.0") })
        // Approved once whatever was answered; the id ties the decision to what the pull recorded.
        let decided = try #require(place.events(.approvalDecided).last)
        #expect(decided.details["scope"] == "once" && decided.details["downgradedFrom"] == "always")
        let id = try #require(decided.details["approvalID"]?.stringValue)
        #expect(reply.contains("(approval \(id))"))
        let publisher = try #require(place.events(.modelPublisher).last)
        #expect(publisher.details["decision"] == "once" && publisher.details["approval"] == .string(id))
        #expect(publisher.details["source"] == "tool" && publisher.session == "t")
        let pull = try #require(place.events(.modelPull).last)
        #expect(pull.details["outcome"] == "fetched" && pull.details["source"] == "tool")
        #expect(pull.details["approval"] == .string(id) && pull.session == "t")
        // Trusting from now on is not the model's to give: nothing was added.
        #expect(place.events(.configChange).isEmpty)
        // The note waits for the conversation, and was shown to its watcher as it arrived.
        let note = try #require(notes.withLock { $0 }.first)
        #expect(note.hasPrefix("[wisp: the pull of ornith-ai/q you asked for (approval \(id)) finished: fetched 2 GB"))
        #expect(place.session.notices.take(for: "t") == [note])
        // The next pull is asked again: no earlier answer covers it.
        _ = await call(tool, "pull", "ornith-ai/q")
        await place.session.modelPulls.wait(for: "ornith-ai/q")
        #expect(approver.requests.count == 2)
        let cached = place.events(.approvalDecided).filter {
            $0.details["decision"]?.stringValue?.hasPrefix("cached") == true
        }
        #expect(cached.isEmpty)
    }

    @Test func aPullDeclinedTimedOutOrUnansweredStartsNothing() async throws {
        for answer in [ApprovalDecision.denied("declined by the user"), .unanswered(.seconds(1))] {
            let approver = Answering([answer])
            let place = try Place(approver: approver)
            defer { place.remove() }
            let reply = await call(place.tool(), "pull", "mlx-community/q")
            #expect(reply.hasPrefix("error: not approved: "), "\(reply)")
            #expect(place.session.modelPulls.all.isEmpty)
            #expect(place.events(.modelPull).last?.details["outcome"] == "declined")
            #expect(place.events(.modelPublisher).isEmpty)
        }
        // `--yes` approves a command; a pull it does not answer.
        let yes = try Place(approver: AutoApprover())
        defer { yes.remove() }
        #expect(
            await call(yes.tool(), "pull", "mlx-community/q")
                == "error: not approved: a pull is asked of the person every time, and --yes does not answer it")
        #expect(yes.session.modelPulls.all.isEmpty)
        // A name that is no repository is refused before anyone is asked.
        let approver = Answering([.approved(.once)])
        let place = try Place(approver: approver)
        defer { place.remove() }
        #expect(await call(place.tool(), "pull", "../x") == "error: '../x' is not a Hugging Face repository")
        #expect(await call(place.tool(), "pull") == "error: pull needs name, the repository <organisation>/<name>")
        #expect(approver.requests.isEmpty)
    }

    @Test func aBackgroundPullCancelledSaysSoInItsNote() async throws {
        let approver = Answering([.approved(.once)])
        let place = try Place(puller: FakePuller(blocks: true), approver: approver)
        defer { place.remove() }
        let reply = await call(place.tool(), "pull", "mlx-community/q")
        #expect(reply.hasPrefix("pulling mlx-community/q in the background"))
        try await eventually("the fetch to start") {
            place.session.modelPulls.all.first?.progress != nil
        }
        // Asked for again while it runs: refused, not started twice.
        #expect(
            await call(place.tool(), "pull", "mlx-community/q")
                == "error: mlx-community/q is being pulled already; its end will arrive as a note")
        #expect(place.session.modelPulls.cancel() == ["mlx-community/q"])
        await place.session.modelPulls.wait(for: "mlx-community/q")
        try await eventually("the note") {
            place.session.notices.take(for: "t").contains {
                $0.contains("was cancelled after 500 MB; what arrived is kept")
            }
        }
        #expect(place.events(.modelPull).last?.details["outcome"] == "cancelled")
    }

    @Test func enableDisableAndCheckAskAndAreRememberedForTheSessionAtMost() async throws {
        let approver = Answering([.approved(.always), .denied("declined by the user"), .approved(.once)])
        let place = try Place(config: #"{"models": {"disabled": ["ollama:a", "ollama:b"]}}"#, approver: approver)
        defer { place.remove() }
        let tool = place.tool()
        let configFile = place.session.home.configFile
        #expect(await call(tool, "enable", "ollama:a") == "enabled ollama:a")
        let first = try #require(approver.requests.first)
        #expect(first.command == "models enable ollama:a" && first.kind == .modelAction(pull: false))
        #expect(first.pattern == "models enable *")
        let decided = try #require(place.events(.approvalDecided).last)
        #expect(decided.details["scope"] == "session" && decided.details["downgradedFrom"] == "always")
        let id = try #require(decided.details["approvalID"]?.stringValue)
        let change = try #require(place.events(.configChange).last)
        #expect(change.details["source"] == "tool" && change.details["approval"] == .string(id))
        #expect(change.session == "t")
        // Remembered for the session: enabling another asks nobody.
        #expect(await call(tool, "enable", "ollama:b") == "enabled ollama:b")
        #expect(approver.requests.count == 1)
        #expect(place.events(.approvalDecided).last?.details["decision"] == "cached")
        #expect(try Config.load(from: configFile).models?.disabled == nil)
        // Nothing is remembered beyond the session: the store holds no standing approval.
        #expect(await place.session.store.all.isEmpty)
        // Disable is asked on its own; declined, nothing changes.
        #expect(await call(tool, "disable", "ollama:a") == "error: not approved: declined by the user")
        #expect(try Config.load(from: configFile).models?.disabled == nil)
        // A check of a model whose runtime reports its own capabilities records nothing.
        #expect(
            await call(tool, "check", "ollama:a")
                == "ollama:a: its runtime reports what it can do; there is nothing to check")
        #expect(
            approver.requests.map(\.command) == [
                "models enable ollama:a", "models disable ollama:a", "models check ollama:a",
            ])
    }

    @Test func theRequestsDialogOffersOnlyTheScopesItsKindAllows() {
        let assessment = RiskAssessment(level: .moderate, reasons: ["downloads a model"], sources: ["rules"])
        let pull = ApprovalRequest(
            command: "models pull ornith-ai/q", pattern: "models pull *", workingDirectory: "/r",
            assessment: assessment,
            kind: .modelAction(pull: true))
        let shown = TerminalApprover.render(pull, style: .plain)
        #expect(shown.contains("  [y]once  [n]o ›") && shown.contains("never remembered"))
        #expect(!shown.contains("[s]ession") && !shown.contains("remembered as"))
        var enable = pull
        enable.kind = .modelAction(pull: false)
        let offered = TerminalApprover.render(enable, style: .plain)
        #expect(offered.contains("  [y]once  [s]ession  [n]o ›") && offered.contains("remembered as: models pull *"))
        var command = pull
        command.kind = .command
        #expect(TerminalApprover.render(command, style: .plain).contains("[p]roject 30d  [a]lways 30d  [n]o"))
    }

    @Test func aNoteReachesTheModelWithTheNextTurnAndIsNoTurnOfItsOwn() async throws {
        let notices = ConversationNotices()
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("one"), .say("two")])),
            audit: AuditLog(session: "c", sink: MemoryAuditSink()))
        agent.notices = notices
        _ = try await agent.respond(to: "first")
        notices.post("[wisp: the pull of mlx-community/q you asked for (approval a1) finished]", to: "c")
        notices.post("for another conversation", to: "d")
        _ = try await agent.respond(to: "second")
        let notice = try #require(agent.store.entries.first { $0.kind == .notice })
        #expect(ThreadRecord.text(of: notice.value).hasPrefix("[wisp: the pull of mlx-community/q"))
        #expect(notice.turn == 2)
        // The request carried it ahead of the prompt; it is no turn of its own.
        let sent = agent.transcript
        #expect(ThreadRecord.text(of: try #require(sent.dropLast(2).last)).hasPrefix("[wisp: the pull"))
        #expect(agent.turnCount == 2)
        #expect(notices.take(for: "c").isEmpty && notices.take(for: "d") == ["for another conversation"])
    }
}

import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The verification pass run by the agent (ADR 0060): the readers over the audit's call list, the model step behind
/// the setting, what each face carries, the audit event, and the setting itself.
@Suite struct AgentVerificationTests {
    /// A chat conversation on a scripted model, as `WispThread.setUp` builds it, with a trail and an output store.
    private struct Conversation {
        let dir: URL
        let sink = MemoryAuditSink()
        let model: ScriptedModel
        let agent: Agent

        init(steps: [ScriptedModel.Step], config: String = "{}") throws {
            dir = FileManager.default.temporaryDirectory.appending(path: "wisp-verify-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let home = Home(root: dir.appending(path: "home"))
            try home.ensure()
            try Data(config.utf8).write(to: home.configFile)
            let session = try Session.begin(
                .init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
            let thread = try WispThread.setUp(
                session: session, audit: session.audit,
                host: session.host(approver: DenyingApprover(reason: "not in tests")),
                prompting: session.prompting, toolNames: ["read_file", "run_command", "notify"], model: .system)
            model = ScriptedModel(steps: steps)
            agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }

        /// The `response.verification` events.
        var events: [AuditEvent] { sink.events.filter { $0.kind == .verification } }
    }

    /// A `run_command` step that runs `echo hi` in `dir`.
    private static func echo(in dir: URL) -> ScriptedModel.Step {
        .call(name: "run_command", arguments: #"{"command":"echo hi","workingDirectory":"\#(dir.path)"}"#)
    }

    @Test func theReadersCheckTheReplyAgainstTheAuditsCallList() async throws {
        let conversation = try Conversation(steps: [
            .say("placeholder"),
            .say("Removed the scratch file.\n`sudo ls` was denied per policy."),
        ])
        defer { conversation.remove() }
        // The first step is replaced below: the echo needs the directory.
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        let reply = try await conversation.agent.respond(to: "clean up")
        let verification = try #require(reply.verification)
        #expect(verification.status == .unsupported && verification.method == .readers && verification.calls == 1)
        #expect(verification.claims.map(\.reader) == [.outcome, .removal])
        #expect(
            reply.verified?.hasPrefix(
                "unsupported: \"`sudo ls` was denied per policy.\" (no call in this turn was denied)") == true)
        #expect(reply.verified?.hasSuffix(" +1 more") == true)
        let event = try #require(conversation.events.first)
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .verification)))
        #expect(event.details["method"] == "readers" && event.details["status"] == "unsupported")
        #expect(event.details["calls"] == 1 && event.details["claims"]?.arrayValue?.count == 2)
        #expect(event.details["model"] == nil && event.details["bytes"] == nil, "no model step")
        #expect(event.turn == 1)
        // The model made no further request: the readers need none.
        #expect(conversation.model.script.requests.withLock { $0.count } == 2)
        // The JSON shape `respond` returns.
        let json = try #require(verification.json.objectValue)
        #expect(json["status"] == "unsupported" && json["method"] == "readers" && json["calls"] == 1)
        #expect(json["claims"]?.arrayValue?.first?.objectValue?["reader"] == "outcome")
    }

    @Test func nothingRunsOnAReplyWithNoClaims() async throws {
        let conversation = try Conversation(steps: [.say("Hello! What would you like to do?")])
        defer { conversation.remove() }
        let reply = try await conversation.agent.respond(to: "hi")
        #expect(reply.verification == nil && reply.verified == nil)
        #expect(conversation.events.isEmpty)
        #expect(conversation.model.script.requests.withLock { $0.count } == 1)
    }

    @Test func aReplyWithResultLanguageAndNoClaimIsVerifiedByTheReaders() async throws {
        let conversation = try Conversation(steps: [.say("placeholder"), .say("I executed `echo hi`; exit status 0.")])
        defer { conversation.remove() }
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        let reply = try await conversation.agent.respond(to: "go")
        #expect(reply.verification == Verification(status: .verified, method: .readers, claims: [], calls: 1))
        #expect(reply.verified == nil, "a verified reply shows no line")
        #expect(conversation.events.first?.details["status"] == "verified")
    }

    @Test func theModelStepRunsAsASideCallWhenTheReadersFindNothing() async throws {
        let verdict =
            #"{"reason":"The reply reports macOS 13.6; the call printed 27.0.","claim":"macOS Ventura 13.6","verdict":"unsupported"}"#
        let conversation = try Conversation(
            steps: [.say("placeholder"), .say("I ran `echo hi`. This Mac runs macOS Ventura 13.6."), .say(verdict)],
            config: #"{"verification":{"mode":"model"}}"#)
        defer { conversation.remove() }
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        #expect(conversation.agent.verification == .model)
        let reply = try await conversation.agent.respond(to: "go")
        let verification = try #require(reply.verification)
        #expect(verification.status == .unsupported && verification.method == .model && verification.failure == nil)
        #expect(
            verification.claims == [
                ReplyVerification.Claim(
                    reader: nil, claim: "macOS Ventura 13.6",
                    reason: "The reply reports macOS 13.6; the call printed 27.0.")
            ])
        #expect(
            reply.verified
                == "unsupported: \"macOS Ventura 13.6\" (the model found no call producing it: The reply reports macOS 13.6; the call printed 27.0.)"
        )
        // The side call: a third request, with the schema, the reply and the call list in its prompt, asking for no
        // thinking, and no observer recording it as the turn's.
        let requests = conversation.model.script.requests.withLock { $0 }
        #expect(requests.count == 3 && requests[2].schema != nil)
        let prompt = requests[2].transcript.compactMap { entry -> String? in
            if case .prompt(let prompt) = entry { ContextArchive.text(prompt.segments) } else { nil }
        }.joined()
        #expect(prompt.contains("<<<REPLY\nI ran `echo hi`. This Mac runs macOS Ventura 13.6.\nREPLY>>>"))
        #expect(
            prompt.contains("Calls this turn (1):\n1. run_command") && prompt.contains("echo hi")
                && prompt.contains("exit status 0"))
        #expect(prompt.contains("output: exit status: 0 ⏎ stdout: ⏎ hi"))
        #expect(conversation.model.script.thinking.withLock { $0.last } == .off)
        #expect(conversation.sink.events.filter { $0.kind == .modelReasoning }.isEmpty)
        let event = try #require(conversation.events.first)
        #expect(event.details["method"] == "model" && event.details["status"] == "unsupported")
        #expect(event.details["model"] == "system" && (event.details["bytes"]?.intValue ?? 0) > 100)
        #expect(event.details["claims"]?.arrayValue?.first?.objectValue?["reader"] == "model")
    }

    @Test func theModelStepsVerifiedVerdictAndItsFailureNeverFailTheTurn() async throws {
        let verified = #"{"reason":"The reply reports what echo printed.","claim":"","verdict":"verified"}"#
        let conversation = try Conversation(
            steps: [
                .say("placeholder"), .say("I ran `echo hi` and it printed hi."), .say(verified),
                .say("I ran it again and it printed hi."), .say("not json at all"),
            ],
            config: #"{"verification":{"mode":"model"}}"#)
        defer { conversation.remove() }
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        let first = try await conversation.agent.respond(to: "go")
        #expect(first.verification == Verification(status: .verified, method: .model, claims: [], calls: 1))
        #expect(first.verified == nil)
        let second = try await conversation.agent.respond(to: "again")
        let verification = try #require(second.verification)
        #expect(verification.status == .verified && verification.method == .model && verification.claims.isEmpty)
        #expect(verification.failure != nil, "the bad answer is recorded, not thrown")
        #expect(second.verified == nil)
        let events = conversation.events
        #expect(events.count == 2 && events[1].details["failure"] != nil && events[1].details["status"] == "verified")
        // The second turn's calls list is empty, and the first turn's echo is earlier support, so "ran `echo hi`"
        // in a later reply would not be flagged; its own list is what the event counts.
        #expect(events[1].details["calls"] == 0)
    }

    @Test func aVerdictWithoutAClaimIsNeverAnError() async throws {
        // The on-device model's answers in the eval of 2026-10-12 left `claim` out; a verified one needs none, and an
        // unsupported one without a claim stays unsupported, saying the model named none.
        let verified = #"{"reason":"The reply reports what echo printed.","verdict":"verified"}"#
        let unnamed = #"{"reason":"No call printed a version.","verdict":"unsupported"}"#
        let conversation = try Conversation(
            steps: [
                .say("placeholder"), .say("I ran `echo hi` and it printed hi."), .say(verified),
                .say("I ran it again; this Mac runs macOS 13.6."), .say(unnamed),
            ],
            config: #"{"verification":{"mode":"model"}}"#)
        defer { conversation.remove() }
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        let first = try await conversation.agent.respond(to: "go")
        #expect(first.verification == Verification(status: .verified, method: .model, claims: [], calls: 1))
        let second = try await conversation.agent.respond(to: "again")
        let verification = try #require(second.verification)
        #expect(verification.failure == nil, "\(String(describing: verification.failure))")
        #expect(
            verification.status == .unsupported && verification.method == .model
                && verification.claims == [
                    ReplyVerification.Claim(
                        reader: nil, claim: ReplyVerifier.unnamedClaim, reason: "No call printed a version.")
                ])
        #expect(conversation.events.allSatisfy { $0.details["failure"] == nil })
        // The rule itself, on verdicts built directly: an empty or blank claim is the same as none.
        let blank = ReplyVerifier.Verdict(reason: " ", claim: "  ", verdict: .unsupported)
        #expect(ReplyVerifier.claim(of: blank)?.claim == ReplyVerifier.unnamedClaim)
        #expect(ReplyVerifier.claim(of: blank)?.reason == "no listed call produced it")
        let named = ReplyVerifier.Verdict(reason: "r", claim: "**macOS 13.6**", verdict: .unsupported)
        #expect(ReplyVerifier.claim(of: named)?.claim == "macOS 13.6")
        #expect(ReplyVerifier.claim(of: .init(reason: "r", claim: nil, verdict: .verified)) == nil)
    }

    @Test func offChecksNothingAndAnAgentWithoutATrailChecksNothing() async throws {
        let conversation = try Conversation(
            steps: [.say("Removed the scratch file.")], config: #"{"verification":{"mode":"off"}}"#)
        defer { conversation.remove() }
        #expect(conversation.agent.verification == .off)
        let reply = try await conversation.agent.respond(to: "go")
        #expect(reply.verification == nil && conversation.events.isEmpty)
        // Made directly, with no trail: no call list, so nothing to check against.
        let bare = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("Removed the scratch file.")])))
        let direct = try await bare.respond(to: "go")
        #expect(direct.verification == nil && direct.verified == nil)
    }

    /// What the person typed in their messages supports a reply that says they said it; a quote they never typed
    /// is still flagged (found live on Bonsai 2 9B, 2026-10-19: a correct recall of "hi" was flagged).
    @Test func thePersonsOwnMessagesSupportWhatTheReplySaysTheySaid() async throws {
        let conversation = try Conversation(steps: [
            .say("Hello!"), .say(#"The first thing you said to me was "hi"."#), .say(#"You said "yes"."#),
        ])
        defer { conversation.remove() }
        _ = try await conversation.agent.respond(to: "hi")
        let recall = try await conversation.agent.respond(to: "What was the first thing I said to you?")
        #expect(recall.verified == nil, "\(String(describing: recall.verification))")
        let invented = try await conversation.agent.respond(to: "and then?")
        #expect(invented.verification?.claims.map(\.reader) == [.answer])
    }

    @Test func earlierTurnsCallsAreKeptAsSupportWithinTheBound() async throws {
        let conversation = try Conversation(steps: [
            .say("placeholder"), .say("Done."), .say("Earlier I executed `echo hi`, as you asked."),
        ])
        defer { conversation.remove() }
        conversation.model.script.steps.withLock { $0[0] = Self.echo(in: conversation.dir) }
        _ = try await conversation.agent.respond(to: "go")
        #expect(conversation.agent.store.continuity.earlierCalls.map(\.tool) == ["run_command"])
        let later = try await conversation.agent.respond(to: "what did you run?")
        #expect(later.verification?.status == .verified, "\(String(describing: later.verification))")
        let many = (0..<300).map { _ in
            TurnCalls.Call(
                id: nil, call: nil, tool: "x", arguments: "{}", command: nil, exitStatus: nil, output: nil, error: nil)
        }
        conversation.agent.rememberCalls(many)
        #expect(conversation.agent.store.continuity.earlierCalls.count == Agent.earlierCallsLimit)
    }

    @Test func thePromptIsBoundedAndTheOutcomesAreNamed() {
        func call(_ tool: String, output: String) -> TurnCalls.Call {
            TurnCalls.Call(
                id: nil, call: nil, tool: tool, arguments: #"{"a":"\#(String(repeating: "x", count: 500))"}"#,
                command: nil, exitStatus: nil, output: output, error: nil)
        }
        let big = String(repeating: "line\n", count: 400)
        let many = (0..<60).map { _ in call("read_file", output: big) }
        let prompt = ReplyVerifier.prompt(reply: String(repeating: "r", count: 10_000), calls: many)
        #expect(prompt.text.utf8.count <= ReplyVerifier.inputBytes + 80, "\(prompt.text.utf8.count)")
        #expect(
            prompt.listed < 60
                && prompt.text.contains("(the list is cut at the budget: \(60 - prompt.listed) more calls)"))
        #expect(prompt.text.contains("[…7600 bytes cut]\nREPLY>>>"))
        #expect(
            prompt.text.contains("x […") && prompt.text.contains(" bytes cut]\n") && prompt.text.contains("bytes cut…]")
        )
        // The whole output comes from the store's reader when it has one.
        let small = ReplyVerifier.prompt(reply: "r", calls: [call("read_file", output: "seen")]) { _ in "whole" }
        #expect(small.text.contains("output: whole") && !small.text.contains("seen") && small.listed == 1)
        #expect(ReplyVerifier.prompt(reply: "r", calls: []).text.contains("Calls this turn: none."))
        var denied = TurnCalls.Call(
            id: nil, call: nil, tool: "run_command", arguments: "{}", command: "rm x", exitStatus: nil, output: "x",
            error: nil)
        denied.verdict = "denied"
        #expect(ReplyVerifier.outcome(of: denied) == "denied by the policy, never ran")
        denied.verdict = "disapproved"
        #expect(ReplyVerifier.outcome(of: denied) == "declined at approval, never ran")
        denied.verdict = nil
        #expect(ReplyVerifier.outcome(of: denied) == "did not run")
        denied.exitStatus = 2
        #expect(ReplyVerifier.outcome(of: denied) == "exit status 2")
        denied.timedOut = true
        #expect(ReplyVerifier.outcome(of: denied) == "timed out")
        var threw = call("notify", output: "")
        threw.output = nil
        threw.error = "boom"
        #expect(ReplyVerifier.outcome(of: threw) == "threw: boom")
        #expect(ReplyVerifier.outcome(of: call("notify", output: "error: off")) == "error")
        #expect(ReplyVerifier.outcome(of: call("notify", output: "posted")) == "ok")
    }

    @Test func theSettingHasThreeValuesAndDefaultsToTheReaders() throws {
        #expect(Config().resolved.verificationMode == .readers)
        #expect(Config(verification: .init(mode: .off)).resolved.verificationMode == .off)
        #expect(ConfigSettings.defaultValue("verification.mode") == .string("readers"))
        #expect(ConfigSettings.setting("verification.mode")?.kind == .choice(["off", "readers", "model"]))
        let model = try ConfigEdit.set("verification.mode", to: "model", in: nil)
        #expect(try JSONDecoder().decode(Config.self, from: model.data).resolved.verificationMode == .model)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("verification.mode", to: "always", in: nil) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Config.self, from: Data(#"{"verification":{"mode":"always"}}"#.utf8))
        }
        let shown = Introspection(home: Home(root: URL(fileURLWithPath: "/tmp/x")), config: Config().resolved)
        #expect(shown.configuration.objectValue?["verification"] == .object(["mode": "readers"]))
    }

    @Test func everyFaceCarriesTheLine() {
        let line =
            "unsupported: \"Removed the scratch file.\" (no rm, rmdir, unlink, or trash command ran in this turn)"
        let end = ChatTurn.end(turn: 1, seconds: 1, failed: false, ran: "ran: no tools", verified: line)
        #expect(end.footer(style: .plain) == "  ran: no tools\n  \(line)\n  1.0 s")
        #expect(ChatProtocol.turn(end)["verified"] == .string(line))
        #expect(ChatProtocol.turn(.end(turn: 1, seconds: 1, failed: false))["verified"] == nil)
    }
}

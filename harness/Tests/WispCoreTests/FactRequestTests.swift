import Darwin
import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The fact a caller asks to keep, as a request names it.
func proposedFact(
    _ id: String = "c3", name: String = "release codename", value: String = "BLUE HERON"
) -> PendingApprovals.ProposedFact {
    .init(id: id, subject: "entity", name: name, value: value, source: "model")
}

/// The pending channel's second kind of request (ADR 0048): a fact a caller asked to keep as permanent, filed
/// apart from commands, bound to what the person is shown, and answered `keep` or `drop` only.
@Suite(.timeLimit(.minutes(1))) struct FactRequestTests {
    @Test func aFactRequestIsFiledApartFromCommandsAndAnsweredKeepOrDrop() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(
            keeping: proposedFact(), thread: "git", client: "claude-code", timeout: .seconds(60))
        #expect(request.kind == .fact && request.subject == "release codename = BLUE HERON")
        try channel.file(request)
        let file = channel.directory.appending(path: "\(request.id).fact.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: channel.directory.appending(path: "\(request.id).request.json").path))
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        try channel.file(command)
        #expect(channel.waiting(.fact) == [request])
        #expect(channel.waiting(.command) == [command])
        #expect(channel.waiting().count == 2)
        #expect(try channel.request(id: request.id) == request)
        // Each kind takes its own answers; the other kind's are refused with a pointer to the right command.
        #expect(throws: PendingApprovals.Failure.otherKind(request.id, .fact)) {
            try channel.answer(request.id, decision: "once", via: "cli")
        }
        #expect(throws: PendingApprovals.Failure.otherKind(command.id, .command)) {
            try channel.answer(command.id, decision: "keep", via: "cli")
        }
        #expect("\(PendingApprovals.Failure.otherKind("a", .fact))".contains("wisp facts keep or drop"))
        #expect("\(PendingApprovals.Failure.otherKind("a", .command))".contains("wisp approvals approve or deny"))
        #expect("\(PendingApprovals.Failure.invalidDecision("maybe"))".contains("keep or drop"))
        try channel.answer(request.id, decision: "keep", via: "cli")
        #expect(throws: PendingApprovals.Failure.answered(request.id)) {
            try channel.answer(request.id, decision: "drop", via: "tui")
        }
        guard case .answer(let answer)? = channel.take(request) else { Issue.record("no answer taken"); return }
        #expect(answer.decision == "keep" && answer.binding == request.binding)
        #expect(!channel.isFiled(request) && channel.delivery(of: request.id) == .taken)
        #expect(channel.waiting(.fact).isEmpty)
    }

    @Test func aFactRequestIsBoundToTheFactShown() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let request = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil)
        // A fact binding never equals a command's, nor another fact's.
        let other = PendingApprovals.request(
            keeping: proposedFact(value: "GREY HERON"), thread: "git", client: nil, timeout: nil)
        #expect(request.binding == request.expectedBinding && request.binding != other.binding)
        try channel.file(request)
        // The file is changed to keep another value: the answering process refuses it.
        let file = channel.directory.appending(path: "\(request.id).fact.json")
        let text = try String(contentsOf: file, encoding: .utf8).replacing("BLUE HERON", with: "RED HERON")
        try Data(text.utf8).write(to: file)
        #expect(throws: PendingApprovals.Failure.altered(request.id)) {
            try channel.answer(request.id, decision: "keep", via: "cli")
        }
        // An answer bound to another request is refused by the server.
        try channel.file(other)
        let replay = PendingApprovals.Answer(
            id: other.id, binding: request.binding, decision: "keep", via: "cli", pid: getpid(), answeredAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(replay).write(to: channel.directory.appending(path: "\(other.id).answer.json"))
        #expect(channel.take(other) == .rejected("the answer was not bound to this request"))
        // So is a command's decision written straight to the file, which no answering process would write.
        let wrong = PendingApprovals.Answer(
            id: other.id, binding: other.binding, decision: "always", via: "cli", pid: getpid(), answeredAt: Date())
        try encoder.encode(wrong).write(to: channel.directory.appending(path: "\(other.id).answer.json"))
        #expect(channel.take(other) == .rejected("the answer's decision 'always' is not one wisp knows"))
        #expect(channel.isFiled(other))
    }

    @Test func aStaleFactRequestIsSweptAndARequestWithoutAKindIsACommand() throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let expired = PendingApprovals.request(
            keeping: proposedFact(), thread: "git", client: nil, now: Date().addingTimeInterval(-120),
            timeout: .seconds(60))
        let orphan = PendingApprovals.request(
            keeping: proposedFact("c4"), thread: "git", client: nil, pid: 999_999, timeout: nil)
        try channel.file(expired)
        try channel.file(orphan)
        #expect(channel.waiting(.fact).isEmpty)
        #expect(throws: PendingApprovals.Failure.stale(expired.id)) {
            try channel.answer(expired.id, decision: "keep", via: "cli")
        }
        #expect(Set(channel.sweep().map(\.id)) == [expired.id, orphan.id])
        #expect(!channel.isFiled(expired) && !channel.isFiled(orphan))
        // A request as wisp 0.16.0 filed it, with no kind, reads as a command.
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        var object = try #require(
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(command)).objectValue)
        object["kind"] = nil
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let legacy = try decoder.decode(
            PendingApprovals.Request.self, from: JSONEncoder().encode(JSONValue.object(object)))
        #expect(legacy.kind == .command && legacy.fact == nil && legacy.binding == legacy.expectedBinding)
    }

    @Test func listsWaitingFactsForPeopleAndForScripts() {
        let now = Date()
        let request = PendingApprovals.request(
            keeping: proposedFact(), thread: "git", client: "claude-code", now: now.addingTimeInterval(-90),
            timeout: nil)
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        let piped = ListingLayout.factRequests([request, command], width: nil, now: now)
        #expect(piped == ["\(request.id)\t90\tclaude-code/git\tc3\tmodel\tentity\trelease codename\tBLUE HERON"])
        let terminal = ListingLayout.factRequests([request], width: 100, now: now)
        #expect(terminal.first?.hasPrefix("ID") == true && terminal.first?.contains("KEEP AS PERMANENT") == true)
        #expect(
            terminal.last?.contains("1 min") == true && terminal.last?.contains("release codename = BLUE HERON") == true
        )
    }

    @Test func theDefaultPolicyRefusesTheModelKeepingOrDroppingAFact() {
        let policy = CommandPolicy()
        #expect(policy.check("wisp facts keep a1b2c3d4") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp facts drop a1b2c3d4") != .allowed)
        #expect(policy.check("echo x; wisp facts keep a1b2c3d4") != .allowed)
        #expect(policy.check("wisp facts pending") == .allowed)
        #expect(policy.check("wisp facts") == .allowed)
    }

    @Test func theNotificationNamesTheFactAndHowToKeepIt() {
        let request = PendingApprovals.request(
            keeping: proposedFact(), thread: "git", client: "claude-code", timeout: nil)
        let message = FactKeeper.message(for: request)
        #expect(message.title == "wisp: keep as a permanent fact?")
        #expect(message.body == "release codename = BLUE HERON — wisp facts keep \(request.id)")
        #expect(message.subtitle == "from the model · claude-code, thread git")
        let long = PendingApprovals.request(
            keeping: proposedFact(value: String(repeating: "x", count: 200)), thread: nil, client: nil, timeout: nil)
        #expect(FactKeeper.message(for: long).body.contains("… — wisp facts keep \(long.id)"))
        #expect(FactKeeper.message(for: long).subtitle == "from the model")
    }

    @Test func theRelayShowsFactsOnlyToAFrontEndThatDeclaredThem() async throws {
        #expect(PendingRelay.kinds { $0 == "approve-mcp" } == [.command])
        #expect(PendingRelay.kinds { $0 == "keep-facts" } == [.fact])
        #expect(PendingRelay.kinds { _ in false }.isEmpty)
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let router = LineRouter()
        let sent = SentLines()
        let sink = MemoryAuditSink()
        let relay = PendingRelay(
            channel: channel, router: router, audit: AuditLog(session: "chat", sink: sink), kinds: [.fact],
            send: sent.keep)
        let fact = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: "claude-code", timeout: nil)
        let other = PendingApprovals.request(
            keeping: proposedFact("c4", value: "GREY HERON"), thread: "git", client: nil, timeout: nil)
        try channel.file(fact)
        try channel.file(other)
        try channel.file(PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil))
        relay.poll()
        let shown = sent.of("approval")
        #expect(shown.count == 2, "the command is not shown to a front end that declared only keep-facts")
        let line = try #require(shown.first { $0["request"] == .string(fact.id) })
        #expect(line["kind"] == "fact" && line["source"] == "mcp" && line["command"] == "release codename = BLUE HERON")
        let shownFact = try #require(line["fact"]?.objectValue)
        #expect(shownFact["id"] == "c3" && shownFact["value"] == "BLUE HERON" && shownFact["source"] == "model")
        router.receive(#"{"type":"answer","id":"mcp-\#(fact.id)","decision":"keep"}"#)
        // An answer that is not keep or drop drops: refusing is the default.
        router.receive(#"{"type":"answer","id":"mcp-\#(other.id)","decision":"once"}"#)
        var answers: [String: String] = [:]
        try await eventually("both answers written") {
            for request in [fact, other] where answers[request.id] == nil {
                if case .answer(let answer)? = channel.take(request) { answers[request.id] = answer.decision }
            }
            return answers.count == 2
        }
        #expect(answers == [fact.id: "keep", other.id: "drop"])
        let answered = sink.events.filter { $0.kind == .approvalAnswered }
        #expect(answered.allSatisfy { $0.details["kind"] == "fact" && $0.details["via"] == "tui" })
        for event in answered { #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind))) }
    }
}

/// What a keeper applied, kept for the test.
final class AppliedAnswers: Sendable {
    /// Each decision and request id, in order.
    let calls = Mutex<[String]>([])
    /// What to return.
    let result: FactKeeper.Applied?

    /// A recorder that keeps a `keep` as `p1` and drops a `drop`, unless told to return `result`.
    init(result: FactKeeper.Applied? = nil) { self.result = result }

    /// The closure the keeper calls.
    var apply: FactKeeper.Apply {
        { decision, request in
            self.calls.withLock { $0.append("\(decision) \(request)") }
            return self.result ?? (decision == "keep" ? .kept("p1") : .dropped)
        }
    }
}

/// Asking the person to keep a fact over MCP (ADR 0048): the call returns at once, the answer is applied when it
/// comes, a drop is remembered, silence keeps nothing, and every step is audited on the thread.
@Suite(.timeLimit(.minutes(1))) struct FactKeeperTests {
    /// A keeper over `channel` that polls quickly and records what it posts.
    private func keeper(
        _ channel: PendingApprovals, timeout: Duration? = .seconds(5), posted: PostedNotifications = .init()
    ) -> FactKeeper {
        FactKeeper(
            channel: channel, timeout: timeout, client: { "claude-code" },
            notify: { message, _ in posted.messages.withLock { $0.append(message) } }, poll: .milliseconds(20))
    }

    /// An agent keeping facts, with the model's proposal `release codename = BLUE HERON` as `c1`.
    private func proposing(
        sink: MemoryAuditSink = MemoryAuditSink(), value: String = "BLUE HERON"
    ) throws -> (Agent, Fact) {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])),
            audit: AuditLog(session: "git", sink: sink))
        agent.facts = FactSettings()
        let fact = try #require(
            agent.record(
                FactBook.Assertion(
                    identity: FactIdentity(scope: .permanent, subject: "entity", name: "release codename"),
                    source: .model, value: value, temporalClass: .permanent, method: .distilled, turn: 1)))
        agent.refreshFacts()
        return (agent, fact)
    }

    /// Waits until the keeper's request about `fact` has left `pending`.
    private func settled(_ keeper: FactKeeper, fact: String = "c1") async throws -> FactKeeper.Record {
        for _ in 0..<250 {
            if let record = keeper.record(thread: "git", fact: fact), record.state != .pending { return record }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func aKeptFactIsAppliedAsThePersonsAndAudited() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let posted = PostedNotifications()
        let keeper = keeper(channel, posted: posted)
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "git", sink: sink)
        let (_, fact) = try proposing()
        let applied = AppliedAnswers()
        guard case .filed(let record) = try keeper.ask(fact, thread: "git", audit: audit, apply: applied.apply) else {
            Issue.record("not filed")
            return
        }
        #expect(record.state == .pending && record.request.client == "claude-code" && record.request.thread == "git")
        #expect(keeper.pending.map(\.request.id) == [record.request.id])
        #expect(posted.messages.withLock { $0.first?.body.hasSuffix("wisp facts keep \(record.request.id)") } == true)
        // Asked again while it waits, the same request comes back and nobody is told twice.
        #expect(try keeper.ask(fact, thread: "git", audit: audit, apply: applied.apply) == .waiting(record))
        #expect(posted.messages.withLock { $0.count } == 1)
        try channel.answer(record.request.id, decision: "keep", via: "cli")
        let done = try await settled(keeper)
        #expect(done.state == .kept && done.kept == "p1" && done.via == "cli" && done.settledAt != nil)
        #expect(applied.calls.withLock { $0 } == ["keep \(record.request.id)"])
        #expect(!channel.isFiled(record.request))
        let kinds = sink.events.map(\.kind)
        #expect(kinds == [.approvalPending, .approvalSettled])
        let settledEvent = try #require(sink.events.last)
        #expect(settledEvent.details["outcome"] == "answered" && settledEvent.details["decision"] == "keep")
        #expect(settledEvent.details["kept"] == "p1" && settledEvent.details["kind"] == "fact")
        #expect(settledEvent.details["value"] == "BLUE HERON" && settledEvent.details["via"] == "cli")
        for event in sink.events { #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: event.kind))) }
    }

    @Test func aDroppedFactIsRememberedByItsThreadAndNotAskedAgain() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let posted = PostedNotifications()
        let keeper = keeper(channel, posted: posted)
        let (_, fact) = try proposing()
        let applied = AppliedAnswers()
        guard case .filed(let record) = try keeper.ask(fact, thread: "git", audit: nil, apply: applied.apply) else {
            Issue.record("not filed")
            return
        }
        try channel.answer(record.request.id, decision: "drop", via: "tui")
        #expect(try await settled(keeper).state == .dropped)
        guard case .dropped(let earlier) = try keeper.ask(fact, thread: "git", audit: nil, apply: applied.apply) else {
            Issue.record("asked again")
            return
        }
        #expect(earlier.request.id == record.request.id && earlier.via == "tui")
        #expect(posted.messages.withLock { $0.count } == 1)
        // Another thread may still ask; and once this thread closes, its memory goes with it.
        guard case .filed = try keeper.ask(fact, thread: "docs", audit: nil, apply: applied.apply) else {
            Issue.record("another thread was refused")
            return
        }
        keeper.withdraw(thread: "git")
        guard case .filed = try keeper.ask(fact, thread: "git", audit: nil, apply: applied.apply) else {
            Issue.record("the closed thread's memory stayed")
            return
        }
        keeper.withdraw(thread: nil)
    }

    @Test func silenceKeepsNothingAndIsNotRemembered() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let keeper = keeper(channel, timeout: .milliseconds(100))
        let sink = MemoryAuditSink()
        let (_, fact) = try proposing()
        let applied = AppliedAnswers()
        _ = try keeper.ask(fact, thread: "git", audit: AuditLog(session: "git", sink: sink), apply: applied.apply)
        let record = try await settled(keeper)
        #expect(record.state == .timedOut && record.kept == nil)
        #expect(applied.calls.withLock { $0.isEmpty })
        #expect(!channel.isFiled(record.request))
        #expect(sink.events.last?.details["outcome"] == "timed-out")
        guard case .filed = try keeper.ask(fact, thread: "git", audit: nil, apply: applied.apply) else {
            Issue.record("silence was remembered as a drop")
            return
        }
        keeper.withdraw(thread: nil)
    }

    @Test func aClosingThreadWithdrawsItsRequests() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let keeper = keeper(channel, timeout: nil)
        let sink = MemoryAuditSink()
        let (_, fact) = try proposing()
        let applied = AppliedAnswers()
        guard
            case .filed(let record) = try keeper.ask(
                fact, thread: "git", audit: AuditLog(session: "git", sink: sink), apply: applied.apply)
        else {
            Issue.record("not filed")
            return
        }
        #expect(record.request.expiresAt == nil)
        keeper.withdraw(thread: "other")
        #expect(keeper.record(thread: "git", fact: "c1")?.state == .pending)
        keeper.withdraw(thread: "git")
        #expect(try await settled(keeper).state == .withdrawn)
        #expect(!channel.isFiled(record.request))
        #expect(sink.events.last?.details["outcome"] == "withdrawn")
    }

    @Test func anAnswerThatCannotBeAppliedOrARemovedRequestFails() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let keeper = keeper(channel)
        let (_, fact) = try proposing()
        let refusing = AppliedAnswers(result: .failed("fact c1 changed"))
        guard case .filed(let record) = try keeper.ask(fact, thread: "git", audit: nil, apply: refusing.apply) else {
            Issue.record("not filed")
            return
        }
        try channel.answer(record.request.id, decision: "keep", via: "cli")
        let failed = try await settled(keeper)
        #expect(failed.state == .failed && failed.reason == "fact c1 changed" && failed.kept == nil)
        // A request swept away under the keeper fails too, and is not remembered.
        guard case .filed(let second) = try keeper.ask(fact, thread: "git", audit: nil, apply: refusing.apply) else {
            Issue.record("not filed")
            return
        }
        channel.withdraw(second.request)
        for _ in 0..<250 where keeper.record(thread: "git", fact: "c1")?.state == .pending {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(keeper.record(thread: "git", fact: "c1")?.reason == "the pending request was removed")
        // A channel that cannot be used is a thrown error, audited as failed.
        let broken = FactKeeper(
            channel: PendingApprovals(directory: URL(fileURLWithPath: "/dev/null/pending")), timeout: nil,
            notify: { _, _ in })
        let sink = MemoryAuditSink()
        #expect(throws: PendingApprovals.Failure.self) {
            try broken.ask(fact, thread: "git", audit: AuditLog(session: "git", sink: sink), apply: refusing.apply)
        }
        #expect(sink.events.last?.details["outcome"] == "failed" && broken.records.isEmpty)
    }

    @Test func theAgentKeepsOnlyTheFactShownAndADropLeavesItInItsThread() throws {
        let sink = MemoryAuditSink()
        let (agent, fact) = try proposing(sink: sink)
        let shown = FactKeeper.proposed(fact)
        #expect(throws: FactFailure.changed("c1")) {
            try agent.keepAsked(proposedFact("c1", value: "GREY HERON"), request: "a1b2c3d4")
        }
        #expect(throws: FactFailure.changed("c9")) { try agent.keepAsked(proposedFact("c9"), request: "a1b2c3d4") }
        let kept = try agent.keepAsked(shown, request: "a1b2c3d4")
        #expect(kept.id == "p1" && kept.identity.scope == .permanent && kept.approved != nil)
        let change = try #require(sink.events.last { $0.kind == .factScopeChanged })
        #expect(change.details["by"] == "person" && change.details["request"] == "a1b2c3d4")
        #expect(change.details["to"] == "permanent")
        // Kept once, the thread's copy is superseded: asking about it again finds it changed.
        #expect(throws: FactFailure.changed("c1")) { try agent.keepAsked(shown, request: "b") }

        let (other, proposal) = try proposing()
        let dropped = try other.dropAsked(FactKeeper.proposed(proposal), request: "c")
        #expect(dropped.id == "c1" && !dropped.proposed && dropped.identity.scope == .thread)
        // A fact that is not a proposal is left as it is.
        #expect(try other.dropAsked(FactKeeper.proposed(dropped), request: "d") == dropped)
        let off = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("ok")])))
        #expect(throws: FactFailure.off) { try off.keepAsked(shown, request: "e") }
    }
}

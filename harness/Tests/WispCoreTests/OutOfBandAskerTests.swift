import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// The question under `wisp mcp` (ADR 0062, section 6): how `OutOfBandAsker` files, races, withdraws and parks it,
/// and how `InquiryBox` watches a parked question and words the note the next turn carries.
@Suite struct OutOfBandAskerTests {
    /// An asker over a scratch channel with a short poll, keeping the notifications it posted.
    final class Rig: Sendable {
        /// The notifications posted.
        final class Posted: Sendable {
            let messages = Mutex<[Notifier.Message]>([])
        }

        let channel = scratchChannel()
        let posted = Posted()
        let sink = MemoryAuditSink()
        let audit: AuditLog

        init() { audit = AuditLog(session: "t", sink: sink) }

        func asker(
            alongside: @escaping @Sendable () -> OutOfBandAsker.Ask? = { nil }, hold: Duration = .seconds(5)
        ) -> OutOfBandAsker {
            let posted = posted
            return OutOfBandAsker(
                channel: channel, alongside: alongside, client: { "claude-code" },
                notify: { message, _ in posted.messages.withLock { $0.append(message) } }, poll: .milliseconds(5),
                hold: hold)
        }

        func remove() { try? FileManager.default.removeItem(at: channel.directory) }
    }

    @Test func aQuestionThatCannotBeFiledIsAskedInTheClientsDialogOrFailsSaying() async throws {
        let rig = Rig()
        defer { rig.remove() }
        // The channel's directory is a regular file, so nothing can be filed there.
        try Data("x".utf8).write(to: rig.channel.directory)
        let question = Question(text: "Which?", options: ["a", "b"])
        let alone = await rig.asker().ask(question, box: InquiryBox(), audit: rig.audit)
        guard case .failed(let reason) = alone.outcome else {
            Issue.record("expected a failure: \(alone)")
            return
        }
        #expect(reason.hasPrefix("the question could not be filed outside the client"))
        #expect(rig.posted.messages.withLock { $0.isEmpty }, "nothing was announced for a question that was not filed")
        // With the dialog on, the dialog answers instead.
        let dialog = rig.asker(alongside: { { _ in .answered(.chose("b")) } })
        #expect(
            await dialog.ask(question, box: InquiryBox(), audit: rig.audit)
                == Question.Reply(.chose("b"), via: "elicitation"))
        // A dialog that fails too reports both reasons.
        let broken = rig.asker(alongside: { { _ in .failed("no elicitation") } })
        guard case .failed(let both) = await broken.ask(question, box: InquiryBox(), audit: rig.audit).outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(both.contains("the question could not be asked") && both.hasSuffix("no elicitation"))
    }

    @Test func aCancelledCallWithdrawsTheQuestionAndARequestThatVanishesEndsTheHold() async throws {
        let rig = Rig()
        defer { rig.remove() }
        let asker = rig.asker()
        let first = Question(text: "Cancel me?")
        let cancelled = Task { await asker.ask(first, box: InquiryBox(), audit: rig.audit) }
        _ = try await firstValue("the question filed") { rig.channel.waiting(.question).first }
        cancelled.cancel()
        #expect(await cancelled.value == Question.Reply(.abandoned))
        #expect(rig.channel.waiting(.question).isEmpty, "the abandoned question is withdrawn")
        #expect(
            rig.posted.messages.withLock { $0.count } == 1
                && rig.posted.messages.withLock { $0[0].title } == "wisp: the model asks")
        // The thread closing while the call holds the dialog removes the request: the call ends withdrawn.
        let second = Question(text: "Withdraw me?")
        let held = Task { await asker.ask(second, box: InquiryBox(), audit: rig.audit) }
        let filed = try await firstValue("the second question filed") { rig.channel.waiting(.question).first }
        rig.channel.withdraw(filed)
        #expect(await held.value == Question.Reply(.withdrawn))
    }

    @Test func anAnswerThatDoesNotBelongToTheQuestionIsRefusedAuditedAndTheRealOneStillWins() async throws {
        let rig = Rig()
        defer { rig.remove() }
        let asker = rig.asker()
        let question = Question(text: "Which?", options: ["a", "b"])
        let asking = Task { await asker.ask(question, box: InquiryBox(), audit: rig.audit) }
        let filed = try await firstValue("the question filed") { rig.channel.waiting(.question).first }
        // An answer file bound to another request is rejected, audited, and the request stays filed.
        let other = PendingApprovals.request(asking: Question(text: "Other?"), client: nil)
        try rig.channel.file(other)
        try rig.channel.answer(other.id, decision: "decline", via: "cli")
        let stolen = try Data(contentsOf: rig.channel.directory.appending(path: "\(other.id).answer.json"))
        try stolen.write(to: rig.channel.directory.appending(path: "\(filed.id).answer.json"))
        let refusal = try await firstValue("the refusal audited") {
            rig.sink.events.first { $0.kind == .inquiryAnswered }
        }
        #expect(refusal.details["delivery"] == "refused" && refusal.details["via"] == "unknown")
        #expect(rig.channel.isFiled(filed))
        try rig.channel.answer(filed.id, decision: "chose", text: "b", via: "tui")
        #expect(await asking.value == Question.Reply(.chose("b"), via: "tui"))
        #expect(!rig.channel.isFiled(filed), "an answered question leaves the channel")
    }

    @Test func aDeadlineShorterThanTheHoldEndsTheQuestionUnansweredAndWithdrawsIt() async throws {
        let rig = Rig()
        defer { rig.remove() }
        let question = Question(text: "Codename?", timeout: .milliseconds(60))
        let reply = await rig.asker(hold: .seconds(30)).ask(question, box: InquiryBox(), audit: rig.audit)
        #expect(reply == Question.Reply(.unanswered(.milliseconds(60))))
        #expect(rig.channel.waiting(.question).isEmpty)
    }

    @Test func aQuestionHeldPastTheHoldParksAndItsLaterAnswerReachesTheNextTurnAsANote() async throws {
        let rig = Rig()
        defer { rig.remove() }
        let notices = ConversationNotices()
        let box = InquiryBox(conversation: "t", notices: notices)
        let recorded = Mutex<[String]>([])
        box.onAnswer { _, answer in recorded.withLock { $0.append(answer) } }
        let question = Question(text: "Codename?", thread: "t")
        try box.begin(question, turn: 1)
        let reply = await rig.asker(hold: .milliseconds(40)).ask(question, box: box, audit: rig.audit)
        guard case .parked = reply.outcome else {
            Issue.record("expected the turn to park: \(reply)")
            return
        }
        #expect(box.records.first?.parked == true && box.waiting == question)
        #expect(rig.channel.waiting(.question).count == 1, "a parked question stays filed")
        try rig.channel.answer(question.id, decision: "answer", text: "BLUE HERON", via: "cli")
        _ = try await firstValue("the note posted") { notices.take(for: "t").first }
        #expect(box.waiting == nil)
        let settled = try #require(box.records.first)
        #expect(settled.outcome == .answered("BLUE HERON") && settled.delivered == "notice")
        #expect(recorded.withLock { $0 } == ["BLUE HERON"], "the answer is the thread's fact")
        let audited = try await firstValue("the settle audited") {
            rig.sink.events.first { $0.kind == .inquirySettled }
        }
        #expect(audited.details["delivered"] == "notice" && audited.details["via"] == "cli")
    }

    @Test func theRaceFailsOnlyWhenEveryLegHasAndTheFirstSettlementStands() async {
        let all = OutOfBandAsker.Race(legs: 2)
        all.failed("dialog")
        all.settle(.held)
        all.failed("channel")
        // Already settled by the first call to settle; a later failure cannot replace it.
        #expect(await all.winner() == .held)
        let failing = OutOfBandAsker.Race(legs: 2)
        failing.failed("one")
        failing.failed("two")
        #expect(await failing.winner() == .failed(["one", "two"]))
    }
}

/// The parked question's watch and the note's words (ADR 0062, section 6).
@Suite struct InquiryBoxParkTests {
    @Test func theNoteSaysHowEachQuestionEndedAndWhereThePersonAnswered() {
        let question = Question(text: "Which?\u{1B}[2K", options: ["a", "b"])
        func note(_ outcome: Question.Outcome, via: String? = nil) -> String {
            InquiryBox.note(for: question, outcome: outcome, via: via, time: Date(timeIntervalSince1970: 0))
        }
        #expect(note(.answered("BLUE")).hasPrefix("[wisp: the person answered your question \"Which?"))
        #expect(!note(.answered("BLUE")).contains("\u{1B}"), "the question is escaped in the note")
        #expect(note(.chose("a"), via: "cli").contains("they chose a (via "))
        #expect(note(.chose("a"), via: "cli").contains("wisp questions"), "the face names the questions command")
        #expect(note(.noneOfThese).contains("none of the options"))
        #expect(note(.declined).contains("declined to answer") && note(.declined).contains("Do not ask it again"))
        #expect(note(.unanswered(.seconds(30))).contains("went unanswered within its deadline"))
        #expect(note(.unanswered(.seconds(30))).contains("Do not guess the answer"))
        #expect(note(.withdrawn).contains("was withdrawn"))
    }

    @Test func onlyTheNewestHundredSettledRecordsAreKept() throws {
        let box = InquiryBox()
        for index in 0..<(InquiryBox.historyLimit + 5) {
            let question = Question(text: "Question \(index)?")
            try box.begin(question, turn: index)
            box.settle(question.id, outcome: .declined)
        }
        let records = box.records
        #expect(records.count == InquiryBox.historyLimit)
        #expect(records.first?.question.text == "Question 5?" && records.last?.question.text == "Question 104?")
    }

    @Test func aParkedQuestionPastItsDeadlineIsWithdrawnAndNoted() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let notices = ConversationNotices()
        let box = InquiryBox(conversation: "t", notices: notices)
        let question = Question(text: "Codename?", timeout: .seconds(30))
        try box.begin(question, turn: 1)
        // Filed half a minute ago, so its deadline has passed.
        let pending = PendingApprovals.request(
            asking: question, client: nil, now: Date(timeIntervalSinceNow: -60))
        try channel.file(pending)
        box.park(
            question, pending: pending, channel: channel, audit: AuditLog(session: "t", sink: sink),
            poll: .milliseconds(5))
        let note = try await firstValue("the deadline note") { notices.take(for: "t").first }
        #expect(note.contains("went unanswered within its deadline"))
        #expect(box.records.first?.outcome == .unanswered(.seconds(30)) && !channel.isFiled(pending))
        #expect(sink.events.last?.kind == .inquirySettled)
    }

    @Test func aParkedQuestionWhoseRequestVanishesIsSettledWithdrawnAndABadAnswerIsAuditedFirst() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let sink = MemoryAuditSink()
        let notices = ConversationNotices()
        let box = InquiryBox(conversation: "t", notices: notices)
        let question = Question(text: "Which?", options: ["a", "b"])
        try box.begin(question, turn: 1)
        let pending = PendingApprovals.request(asking: question, client: nil)
        try channel.file(pending)
        box.park(
            question, pending: pending, channel: channel, audit: AuditLog(session: "t", sink: sink),
            poll: .milliseconds(5))
        // An answer file that does not decode is refused and audited; the question keeps waiting.
        try Data("not json".utf8).write(to: channel.directory.appending(path: "\(pending.id).answer.json"))
        let refusal = try await firstValue("the refusal") { sink.events.first { $0.kind == .inquiryAnswered } }
        #expect(refusal.details["delivery"] == "refused" && box.waiting == question)
        // The request leaving the channel (the thread closed elsewhere) settles it withdrawn.
        channel.withdraw(pending)
        let note = try await firstValue("the withdrawn note") { notices.take(for: "t").first }
        #expect(note.contains("was withdrawn") && box.records.first?.outcome == .withdrawn)
    }

    @Test func parkingAQuestionThatAlreadySettledStartsNoWatch() async throws {
        let channel = scratchChannel()
        defer { try? FileManager.default.removeItem(at: channel.directory) }
        let notices = ConversationNotices()
        let box = InquiryBox(conversation: "t", notices: notices)
        let question = Question(text: "Gone?")
        let pending = PendingApprovals.request(asking: question, client: nil)
        try channel.file(pending)
        // Never begun, so there is no waiting record: the watch is cancelled before it can deliver.
        box.park(question, pending: pending, channel: channel, audit: nil, poll: .milliseconds(5))
        try await Task.sleep(for: .milliseconds(60))
        #expect(box.records.isEmpty && notices.take(for: "t").isEmpty)
    }

    @Test func plainChatsTerminalAskerNamesTheTerminal() {
        #expect(TerminalAsker().ways == ["terminal"])
        #expect(TerminalAsker(style: .plain).style.bold("x") == "x")
    }
}

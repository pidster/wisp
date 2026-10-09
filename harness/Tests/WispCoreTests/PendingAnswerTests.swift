import Foundation
import Testing

@testable import WispCore

/// How `wisp approvals approve|deny` and `wisp facts keep|drop` end: a usage error only for a mistake in the
/// command line, a runtime failure (exit 1) for an answer the request's state kept from being used.
@Suite struct PendingAnswerTests {
    @Test func anAnswerTooLateIsARuntimeFailureNotAUsageError() {
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        #expect(
            PendingAnswer.ending(of: command, decision: "once", delivery: .tooLate)
                == .failed("git push origin main was answered another way first; your answer was not used"))
        let fact = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil)
        #expect(
            PendingAnswer.ending(of: fact, decision: "keep", delivery: .tooLate)
                == .failed("release codename = BLUE HERON stopped waiting first; your answer was not used"))
    }

    @Test func aTakenOrWaitingAnswerPrintsWhatItDid() {
        let command = PendingApprovals.request(for: approvalRequest(), client: nil, timeout: nil)
        #expect(
            PendingAnswer.ending(of: command, decision: "session", delivery: .taken)
                == .printed("approved (session): git push origin main for thread git"))
        #expect(
            PendingAnswer.ending(of: command, decision: "no", delivery: .waiting)
                == .printed("denied: git push origin main for thread git; wisp has not read the answer yet"))
        let fact = PendingApprovals.request(keeping: proposedFact(), thread: "git", client: nil, timeout: nil)
        #expect(
            PendingAnswer.ending(of: fact, decision: "drop", delivery: .taken)
                == .printed("dropped, left in its thread: release codename = BLUE HERON (thread git)"))
    }

    @Test func onlyAWrongDecisionIsAUsageError() {
        #expect(
            PendingAnswer.ending(for: .invalidDecision("maybe"))
                == .usage("\(PendingApprovals.Failure.invalidDecision("maybe"))"))
        #expect(
            PendingAnswer.ending(for: .otherKind("a1", .fact))
                == .usage("\(PendingApprovals.Failure.otherKind("a1", .fact))"))
        for failure: PendingApprovals.Failure in [
            .unknown("a1"), .answered("a1"), .stale("a1"), .altered("a1"), .unsafeDirectory("/x"), .io("disk"),
        ] {
            #expect(PendingAnswer.ending(for: failure) == .failed("\(failure)"))
        }
    }
}

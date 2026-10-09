import Foundation

/// What `wisp approvals approve|deny` and `wisp facts keep|drop` say, and how they exit, once the person's
/// answer was written to the pending channel (ADR 0046, ADR 0048). Here rather than in the CLI target so it is
/// tested: a usage error (exit 64, with the usage text) is for a mistake in the command line itself; an answer
/// that could not be used because of the request's state (answered elsewhere, too late, gone) is a runtime
/// failure (exit 1) with the same message and no usage text.
public enum PendingAnswer {
    /// How the command ends.
    public enum Ending: Equatable, Sendable {
        /// It worked: print the line on stdout, exit 0.
        case printed(String)
        /// The command line was wrong: a usage error (exit 64) with the message.
        case usage(String)
        /// The answer could not be used: the message on stderr, exit 1.
        case failed(String)
    }

    /// How a refused answer ends: a usage error only for a decision that is not one, or one of the other kind's
    /// words; a request answered, gone, altered, or unsafe to read is a runtime failure.
    ///
    /// - Parameter failure: Why the channel refused the answer.
    /// - Returns: The ending.
    public static func ending(for failure: PendingApprovals.Failure) -> Ending {
        switch failure {
        case .invalidDecision, .otherKind: .usage("\(failure)")
        case .unknown, .altered, .answered, .stale, .unsafeDirectory, .io: .failed("\(failure)")
        }
    }

    /// How an answer written to the channel ends, once the server has looked: printed when taken or still
    /// waiting, a runtime failure when the request went another way first.
    ///
    /// - Parameters:
    ///   - request: The request answered.
    ///   - decision: The decision written.
    ///   - delivery: What became of it.
    /// - Returns: The ending.
    public static func ending(
        of request: PendingApprovals.Request, decision: String, delivery: PendingApprovals.Delivery
    ) -> Ending {
        let fact = request.kind == .fact
        let verb: String
        let from: String
        if fact {
            verb = decision == "keep" ? "kept as a permanent fact" : "dropped, left in its thread"
            from = request.thread.map { " (thread \($0))" } ?? ""
        } else {
            verb = decision == "no" ? "denied" : "approved (\(decision))"
            from = request.thread.map { " for thread \($0)" } ?? ""
        }
        switch delivery {
        case .taken: return .printed("\(verb): \(request.subject)\(from)")
        case .waiting: return .printed("\(verb): \(request.subject)\(from); wisp has not read the answer yet")
        case .tooLate:
            return .failed(
                fact
                    ? "\(request.subject) stopped waiting first; your answer was not used"
                    : "\(request.subject) was answered another way first; your answer was not used")
        }
    }
}

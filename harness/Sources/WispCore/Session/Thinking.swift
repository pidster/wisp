import Foundation
import Synchronization

/// Tells the turn under way that its model is thinking, from inside a model's executor
/// ([ADR 0053](../../../../docs/decisions/0053-the-models-thinking-shown.md)).
///
/// The framework's stream yields a snapshot only when the reply's text changes, so a model that thinks for half a
/// minute before it answers yields nothing in that time (probed on 2026-10-04 with a scripted executor: the first
/// snapshot came with the first reply fragment, after every reasoning event). The executor knows when thinking
/// begins and ends; `Agent` binds an observer for the length of each turn as a task local, which the framework's
/// executors see (the same probe: the value set around `streamResponse` and `respond` was visible in the
/// executor), and the observer records `model.reasoning` at both edges, which every face follows.
///
/// An executor that has no observer bound (a call outside a turn: distillation, the summary, an assessment)
/// reports nothing; its thinking still reaches that call's transcript as a reasoning entry.
public final class ReasoningObserver: Sendable {
    /// The observer of the turn under way, bound by `Agent` around its requests; nil outside a turn.
    @TaskLocal public static var current: ReasoningObserver?

    /// Called when a request's thinking begins.
    private let began: @Sendable () -> Void
    /// Called when it ends, with its text, its tokens, and how long it took in seconds.
    private let ended: @Sendable (String, Int, Double) -> Void

    /// Creates an observer.
    ///
    /// - Parameters:
    ///   - began: Called when a request's thinking begins.
    ///   - ended: Called when it ends, with its text, its tokens, and its seconds.
    public init(
        began: @escaping @Sendable () -> Void, ended: @escaping @Sendable (String, Int, Double) -> Void
    ) {
        self.began = began
        self.ended = ended
    }

    /// An observer that records `model.reasoning` to `audit`: `start` as thinking begins, `end` with the text as it
    /// ends.
    ///
    /// - Parameter audit: The conversation's log; nil records nothing.
    /// - Returns: The observer.
    static func recording(to audit: AuditLog?) -> ReasoningObserver {
        ReasoningObserver(
            began: { audit?.record(.modelReasoning, details: AuditEvent.Details.reasoningStarted()) },
            ended: { text, tokens, seconds in
                audit?.record(
                    .modelReasoning,
                    details: AuditEvent.Details.reasoningEnded(text: text, tokens: tokens, seconds: seconds))
            })
    }

    /// Reports that thinking began.
    public func thinkingBegan() { began() }

    /// Reports that thinking ended.
    ///
    /// - Parameters:
    ///   - text: What the model thought, verbatim.
    ///   - tokens: Its tokens, as the runtime counted them.
    ///   - seconds: How long it took.
    public func thinkingEnded(text: String, tokens: Int, seconds: Double) { ended(text, tokens, seconds) }
}

/// One request's thinking as an executor streams it: the text so far, its token count, and when it began, with the
/// observer told at each edge. An executor keeps one per request and feeds it every chunk.
public struct ThinkingStretch: Sendable {
    /// The thinking so far, in this stretch.
    public private(set) var text = ""
    /// Tokens of thinking in the whole request, every stretch: the usage's reasoning tokens.
    public private(set) var tokens = 0
    /// Tokens of thinking in this stretch.
    private var stretchTokens = 0
    /// When the current stretch began; nil when the model is not thinking.
    private var started: Date?
    /// Whom to tell; the turn's observer when the executor runs inside a turn.
    private let observer: ReasoningObserver?

    /// Creates a stretch reporting to `observer`.
    ///
    /// - Parameter observer: The turn's observer, or nil to report nothing.
    public init(observer: ReasoningObserver? = ReasoningObserver.current) {
        self.observer = observer
    }

    /// Whether the model is thinking now.
    public var thinking: Bool { started != nil }

    /// Adds a chunk of thinking, beginning a stretch when none is under way.
    ///
    /// - Parameters:
    ///   - chunk: The text.
    ///   - tokens: Its tokens.
    ///   - now: The time, for tests.
    public mutating func think(_ chunk: String, tokens: Int = 1, at now: Date = Date()) {
        if started == nil {
            started = now
            text = ""
            stretchTokens = 0
            observer?.thinkingBegan()
        }
        text += chunk
        stretchTokens += tokens
        self.tokens += tokens
    }

    /// Ends the stretch under way, if any, telling the observer what it held.
    ///
    /// - Parameter now: The time, for tests.
    public mutating func end(at now: Date = Date()) {
        guard let started else { return }
        observer?.thinkingEnded(text: text, tokens: stretchTokens, seconds: now.timeIntervalSince(started))
        self.started = nil
    }
}

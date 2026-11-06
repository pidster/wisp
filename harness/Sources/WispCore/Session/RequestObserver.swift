import Foundation
import Synchronization

/// One request a model's server served, as its executor saw it: the tokens and times the server reported, and the
/// request's parts, for telling what changed at its front since the conversation's last request.
///
/// A server that keeps a prompt cache (Ollama) evaluates again only what follows the first part that differs from
/// what it holds, and reports the prompt's whole length either way (`prompt_eval_count`, probed on 2026-11-05,
/// [measurements.md](../../../../docs/measurements.md), "The git thread's slow turns and its approvals"); its
/// evaluation time is what tells a request that reused the cache from one that did not.
public struct ServedRequest: Sendable, Equatable {
    /// The model, as the server names it.
    public var model: String
    /// The prompt's tokens, as the server counted them, cached or not.
    public var promptTokens: Int
    /// The tokens it generated.
    public var outputTokens: Int
    /// Seconds spent loading the model; nil when the server did not say.
    public var loadSeconds: Double?
    /// Seconds spent evaluating the prompt; nil when the server did not say.
    public var promptSeconds: Double?
    /// Seconds spent generating; nil when the server did not say.
    public var outputSeconds: Double?
    /// The request's whole time on the server; nil when the server did not say.
    public var totalSeconds: Double?
    /// One fingerprint for each part of the request, in order: its tools and options first, then each message.
    public var parts: [Int]
    /// What each part is, in the same order: `tools`, then each message's role.
    public var roles: [String]

    /// Creates a record.
    ///
    /// - Parameters:
    ///   - model: The model.
    ///   - promptTokens: The prompt's tokens.
    ///   - outputTokens: The generated tokens.
    ///   - loadSeconds: Load time.
    ///   - promptSeconds: Prompt evaluation time.
    ///   - outputSeconds: Generation time.
    ///   - totalSeconds: The whole time.
    ///   - parts: The parts' fingerprints.
    ///   - roles: The parts' names.
    public init(
        model: String, promptTokens: Int, outputTokens: Int, loadSeconds: Double? = nil, promptSeconds: Double? = nil,
        outputSeconds: Double? = nil, totalSeconds: Double? = nil, parts: [Int] = [], roles: [String] = []
    ) {
        self.model = model
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.loadSeconds = loadSeconds
        self.promptSeconds = promptSeconds
        self.outputSeconds = outputSeconds
        self.totalSeconds = totalSeconds
        self.parts = parts
        self.roles = roles
    }

    /// A fingerprint of `value`'s JSON, equal for equal parts within one process.
    ///
    /// - Parameter value: A part of the request.
    /// - Returns: Its fingerprint.
    public static func fingerprint(_ value: some Encodable) -> Int {
        var hasher = Hasher()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        hasher.combine((try? encoder.encode(value)) ?? Data())
        return hasher.finalize()
    }
}

/// Tells the turn under way that its model's server served a request, from inside the model's executor; `Agent`
/// binds one for the length of each turn as a task local, as it binds `ReasoningObserver`, and it records
/// `model.request`.
///
/// An executor with no observer bound (a call outside a turn: distillation, the summary, an assessment) reports
/// nothing, so the comparison with the last request is always between the conversation's own.
public final class RequestObserver: Sendable {
    /// The observer of the turn under way, bound by `Agent` around its requests; nil outside a turn.
    @TaskLocal public static var current: RequestObserver?

    /// Called with each request served.
    private let served: @Sendable (ServedRequest) -> Void

    /// Creates an observer.
    ///
    /// - Parameter served: Called with each request served.
    public init(served: @escaping @Sendable (ServedRequest) -> Void) {
        self.served = served
    }

    /// An observer that records `model.request` to `audit`, comparing each request with the one before it in
    /// `previous`.
    ///
    /// - Parameters:
    ///   - audit: The conversation's log; nil records nothing.
    ///   - previous: The conversation's last request's parts, kept across its turns.
    /// - Returns: The observer.
    static func recording(to audit: AuditLog?, previous: PreviousRequest) -> RequestObserver {
        RequestObserver { request in
            let change = previous.compare(request.parts)
            audit?.record(.modelRequest, details: AuditEvent.Details.modelRequest(request, change: change))
        }
    }

    /// Reports a request served.
    ///
    /// - Parameter request: What the server reported, with the request's parts.
    public func requestServed(_ request: ServedRequest) { served(request) }
}

/// The parts of a conversation's last request, which `Agent` keeps across its turns so each request can be compared
/// with the one before it.
final class PreviousRequest: Sendable {
    /// How a request's parts compare with the last one's.
    struct Change: Equatable {
        /// Leading parts equal to the last request's.
        var shared: Int
        /// The index of the first part that differs; nil when every part of the last request leads this one too, or
        /// there was no last request.
        var first: Int?
        /// Whether there was a last request to compare with.
        var compared: Bool
    }

    /// The last request's parts; nil before the first.
    private let parts = Mutex<[Int]?>(nil)

    /// Creates an empty record.
    init() {}

    /// Compares `parts` with the last request's and keeps them as the last.
    ///
    /// - Parameter parts: This request's parts.
    /// - Returns: How they compare.
    func compare(_ parts: [Int]) -> Change {
        let last = self.parts.withLock { last in
            defer { last = parts }
            return last
        }
        guard let last else { return Change(shared: 0, first: nil, compared: false) }
        let shared = zip(last, parts).prefix { $0 == $1 }.count
        return Change(shared: shared, first: shared < last.count ? shared : nil, compared: true)
    }
}

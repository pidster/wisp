import Synchronization

/// The tool-output budget: the most bytes one tool result carries to the model, derived from the current
/// model's context window ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md)).
///
/// One budget for every tool of a conversation: an eighth of the window, as bytes at the composer's
/// bytes-per-token estimate, never below `floor` (4 KiB, what the on-device model's 8,192 tokens give) and
/// never above `ceiling` (64 KiB). It is read at each call, not at start-up, because the window becomes
/// known late for some backends (an overflow error, a runtime's metadata) and `/model` opens a new agent
/// whose window differs; the agent writes `window` whenever its `contextSize` changes. A window nobody knows
/// yet gives the floor.
///
/// A `final class` with a `Mutex`, since every operation is a short synchronous critical section, shared by
/// the thread's tools and its agent (`docs/design.md`, "Concurrency").
public final class ToolBudget: Sendable {
    /// The least a budget can be: the fixed bound every tool had before ADR 0050.
    public static let floor = 4096
    /// The most a budget can be, whatever the window.
    public static let ceiling = 65536
    /// The window is divided by this: an eighth.
    public static let share = 8

    /// The window and whether the conversation's model has `memory`.
    private let state: Mutex<(window: Int?, memory: Bool)>

    /// Creates a budget.
    ///
    /// - Parameters:
    ///   - window: The model's context window in tokens, when known.
    ///   - memory: Whether the conversation has the `memory` tool, so a marker on held-back output can name the
    ///     call that pages it.
    public init(window: Int? = nil, memory: Bool = false) {
        state = Mutex((window, memory))
    }

    /// The model's context window in tokens; nil until known. The agent sets it.
    public var window: Int? {
        get { state.withLock { $0.window } }
        set { state.withLock { $0.window = newValue } }
    }

    /// Whether the conversation has the `memory` tool, so markers tell the model to recall held-back output with
    /// it; without it a marker says the output is kept and is not to be produced again (ADR 0057).
    public var memory: Bool {
        get { state.withLock { $0.memory } }
        set { state.withLock { $0.memory = newValue } }
    }

    /// The budget now, in bytes.
    public var bytes: Int { Self.bytes(forWindow: window) }

    /// The budget for a window of `window` tokens: an eighth of it at four bytes a token, within the floor and the
    /// ceiling; the floor for an unknown window.
    ///
    /// - Parameter window: The window in tokens, or nil.
    /// - Returns: The bytes.
    public static func bytes(forWindow window: Int?) -> Int {
        guard let window, window > 0 else { return floor }
        return min(ceiling, max(floor, window / share * ContextComposer.bytesPerToken))
    }
}

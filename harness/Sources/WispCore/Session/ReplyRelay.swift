import Foundation
import FoundationModels
import Synchronization

/// One request's reply as a local runtime's executor relays it to the framework: thinking as reasoning events through
/// a `ThinkingStretch`, reply text, and tool calls with their arguments completed against the tool's schema
/// (`ChatMessage.completed`), each with the next id. The Ollama executor and the OpenAI-compatible one
/// ([ADR 0058](../../../../docs/decisions/0058-a-shared-http-executor.md)) feed it what their runtimes stream, in
/// their own shapes, and it does the rest the same way for both.
///
/// While the request offers tools and wants no schema reply, the reply's text is held back while it may yet be tool
/// calls written as text in Mistral's format (`TextToolCalls.mistral`), with any calls the runtime parsed meanwhile
/// waiting behind it so the calls keep the order the model wrote them in; it is sent as the reply once it plainly is
/// not, or read as calls at the end when it is exactly that.
struct ReplyRelay {
    /// The request, for its tools' schemas and its id.
    let request: LanguageModelExecutorGenerationRequest
    /// Where the events go.
    let channel: LanguageModelExecutorGenerationChannel
    /// Tool calls sent so far, for their ids.
    private(set) var calls = 0
    /// The thinking under way, and the request's thinking tokens.
    private(set) var thinking: ThinkingStretch
    /// The names of the tools the request offers.
    private let offered: Set<String>
    /// Whether text is still being held.
    private var holding: Bool
    /// The text held.
    private var heldText = ""
    /// Calls the runtime parsed while text was held.
    private var heldCalls: [ChatMessage.ToolCall] = []

    /// A relay for one request.
    ///
    /// - Parameters:
    ///   - request: The request.
    ///   - channel: Where events go.
    ///   - observer: The turn's reasoning observer, by default the one bound for the turn.
    init(
        request: LanguageModelExecutorGenerationRequest, channel: LanguageModelExecutorGenerationChannel,
        observer: ReasoningObserver? = ReasoningObserver.current
    ) {
        self.request = request
        self.channel = channel
        thinking = ThinkingStretch(observer: observer)
        offered = Set(request.enabledToolDefinitions.map(\.name))
        holding = !offered.isEmpty && request.schema == nil
    }

    /// Tokens of thinking in the whole request, as the chunks counted them.
    var thinkingTokens: Int { thinking.tokens }

    /// Relays a chunk of thinking.
    ///
    /// - Parameters:
    ///   - text: The thinking.
    ///   - tokens: Its tokens; a chunk is one by default, as the runtimes stream them.
    nonisolated(nonsending) mutating func think(_ text: String, tokens: Int = 1) async {
        guard !text.isEmpty else { return }
        thinking.think(text, tokens: tokens)
        await channel.send(.reasoning(action: .appendText(text, tokenCount: tokens)))
    }

    /// Relays a chunk of the reply's text, ending any thinking; held while it may be calls written as text.
    ///
    /// - Parameter text: The text.
    nonisolated(nonsending) mutating func reply(_ text: String) async {
        guard !text.isEmpty else { return }
        thinking.end()
        guard holding else {
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
            return
        }
        heldText += text
        guard !TextToolCalls.mayBeMistral(heldText, offered: offered) else { return }
        holding = false
        await channel.send(.response(action: .appendText(heldText, tokenCount: 1)))
        heldText = ""
        let waiting = heldCalls
        heldCalls = []
        for call in waiting { await send(call.name, call.arguments) }
    }

    /// Relays a tool call the runtime parsed, ending any thinking; behind held text it waits, so the calls keep the
    /// order the model wrote them in.
    ///
    /// - Parameters:
    ///   - name: The tool's name.
    ///   - arguments: The arguments as the model wrote them.
    nonisolated(nonsending) mutating func call(_ name: String, _ arguments: JSONValue) async {
        thinking.end()
        if holding && !heldText.isEmpty {
            heldCalls.append(ChatMessage.ToolCall(name: name, arguments: arguments))
        } else {
            await send(name, arguments)
        }
    }

    /// Ends the reply once the runtime said it is done: thinking ends, and held text is sent as calls when it is
    /// exactly calls in Mistral's format, else as the reply, followed by the calls that waited behind it.
    nonisolated(nonsending) mutating func finish() async {
        thinking.end()
        guard !heldText.isEmpty else { return }
        if let recovered = TextToolCalls.mistral(heldText, offered: offered) {
            for call in recovered { await send(call.name, call.arguments) }
        } else {
            await channel.send(.response(action: .appendText(heldText, tokenCount: 1)))
        }
        let waiting = heldCalls
        heldText = ""
        heldCalls = []
        for call in waiting { await send(call.name, call.arguments) }
    }

    /// Sends one tool call, its arguments completed against the tool's schema, with the next id.
    ///
    /// - Parameters:
    ///   - name: The tool's name.
    ///   - arguments: The arguments as the model wrote them.
    nonisolated(nonsending) private mutating func send(_ name: String, _ arguments: JSONValue) async {
        calls += 1
        let schema = request.enabledToolDefinitions.first { $0.name == name }.map { ChatMessage.json($0.parameters) }
        let completed = schema.map { ChatMessage.completed(arguments, schema: $0) } ?? arguments
        let encoded = (try? JSONEncoder().encode(completed)) ?? Data("{}".utf8)
        await channel.send(
            .toolCalls(
                action: .toolCall(
                    id: "\(request.id.uuidString.lowercased())-\(calls)", name: name,
                    action: .appendArguments(String(decoding: encoded, as: UTF8.self), tokenCount: 1))))
    }
}

/// How a request to a local server failed, by when it failed: the server went silent for the timeout, the stream was
/// cut short once it had begun (or the connection was lost), or no server answered at all. Each executor names the
/// runtime in its own failure.
enum ConnectionFailure: Equatable {
    /// Nothing came for the configured timeout.
    case timedOut
    /// The reply had begun, or the connection was lost.
    case interrupted(String)
    /// No server answered.
    case unreachable(String)

    /// The failure for what `URLSession` threw.
    ///
    /// - Parameters:
    ///   - error: The error.
    ///   - streaming: Whether the response had begun.
    init(_ error: any Error, streaming: Bool) {
        let code = (error as? URLError)?.code
        if code == .timedOut {
            self = .timedOut
        } else if streaming || code == .networkConnectionLost {
            self = .interrupted(error.localizedDescription)
        } else {
            self = .unreachable(error.localizedDescription)
        }
    }
}

extension ConnectionFailure {
    /// Whether `error` is the request being cancelled (the task's cancellation, which `URLSession` reports as
    /// `URLError.cancelled`), which is no failure of the server's: the executors rethrow it as `CancellationError`
    /// rather than tell the person no server answered.
    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// The text of a refused response's body, read a line at a time until `limit` bytes, and no further: a server
    /// that keeps sending is not read to its end.
    ///
    /// - Parameters:
    ///   - lines: The body's lines.
    ///   - limit: The most bytes to keep.
    /// - Returns: The text, at most about `limit` bytes.
    /// - Throws: What reading the body throws.
    static func boundedBody<Lines: AsyncSequence>(_ lines: Lines, limit: Int) async throws -> String
    where Lines.Element == String {
        var body = ""
        for try await line in lines {
            body += line
            if body.utf8.count >= limit { break }
        }
        return String(decoding: Data(body.utf8).prefix(limit), as: UTF8.self)
    }
}

/// Holds the last request's input token count behind a mutex, for a model whose executor reports it
/// (`UsageReporting`); a class so the value survives the model's copies.
final class LastInputTokens: Sendable {
    /// The count, or nil before any request reported one.
    let value = Mutex<Int?>(nil)
}

import Foundation
import FoundationModels

extension OpenAICompatibleModel {
    /// Talks to `/v1/chat/completions` for one generation request and streams the reply back
    /// ([ADR 0058](../../../../docs/decisions/0058-a-shared-http-executor.md)).
    ///
    /// The request carries the whole transcript each time, as Ollama's does, with tools, `response_format` for a
    /// schema reply, `stream_options.include_usage` so the last chunk reports usage, and, for a dialect that takes
    /// it, `chat_template_kwargs.enable_thinking`. The reply is read as server-sent events: `delta.content` is the
    /// reply, `delta.reasoning_content` (llama.cpp, and LM Studio's DeepSeek setting) or `delta.reasoning` (LM Studio
    /// since 0.3.23) the thinking, and `delta.tool_calls` fragments, gathered by `index` until the choice finishes,
    /// the calls. The reply is done when a choice finishes (`finish_reason`) or the server sends `[DONE]`; a stream
    /// that ends before either was cut short, and nothing of it is kept.
    public struct Executor: LanguageModelExecutor {
        /// What the executor needs: the runtime, the server, a per-request limit, and the key.
        public struct Configuration: Hashable, Sendable, CustomStringConvertible {
            /// The runtime.
            public var dialect: OpenAICompatibleDialect
            /// The server's base URL.
            public var baseURL: URL
            /// Seconds allowed while nothing arrives.
            public var timeoutSeconds: Int
            /// The bearer token, when the server wants one.
            public var apiKey: String?

            /// Creates a configuration.
            public init(dialect: OpenAICompatibleDialect, baseURL: URL, timeoutSeconds: Int, apiKey: String? = nil) {
                self.dialect = dialect
                self.baseURL = baseURL
                self.timeoutSeconds = timeoutSeconds
                self.apiKey = apiKey
            }

            /// The configuration with the key left out.
            public var description: String {
                "\(dialect.runtime) at \(baseURL.absoluteString), \(timeoutSeconds) s, API key "
                    + (apiKey == nil ? "unset" : "set")
            }
        }

        /// The model type this executor serves.
        public typealias Model = OpenAICompatibleModel

        /// The configuration.
        private let configuration: Configuration

        /// Creates an executor; the framework calls this with the model's `executorConfiguration`.
        public init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// A tool call's id in the request: `call` and five digits, nine letters and digits, as Mistral's chat
        /// templates require of every id; positional, so the same transcript always gets the same ids.
        ///
        /// - Parameter number: The call's place in the transcript, from 1.
        /// - Returns: The id.
        static func callID(_ number: Int) -> String { "call" + String(format: "%05d", number) }

        /// Maps the framework transcript onto chat messages in OpenAI's shape, through the mapping every local
        /// executor shares (`ChatMessage.messages(from:)`): an assistant message's calls carry ids and their
        /// arguments as JSON text, and each tool output names the call it answers by `tool_call_id`, the first
        /// unanswered call of that tool, else the first unanswered call.
        ///
        /// - Parameter transcript: The transcript.
        /// - Returns: The messages.
        static func messages(from transcript: Transcript) -> [JSONValue] {
            var unanswered: [(id: String, name: String)] = []
            var number = 0
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return ChatMessage.messages(from: transcript).map { message in
                if message.role == "assistant", !message.toolCalls.isEmpty {
                    unanswered = []
                    let calls: [JSONValue] = message.toolCalls.map { call in
                        number += 1
                        let id = callID(number)
                        unanswered.append((id, call.name))
                        let arguments = (try? encoder.encode(call.arguments)) ?? Data("{}".utf8)
                        return [
                            "id": .string(id), "type": "function",
                            "function": [
                                "name": .string(call.name),
                                "arguments": .string(String(decoding: arguments, as: UTF8.self)),
                            ],
                        ]
                    }
                    return [
                        "role": "assistant", "content": message.content.isEmpty ? .null : .string(message.content),
                        "tool_calls": .array(calls),
                    ]
                }
                if message.role == "tool" {
                    let index = unanswered.firstIndex { $0.name == message.toolName } ?? unanswered.indices.first
                    let id: String
                    if let index {
                        id = unanswered.remove(at: index).id
                    } else {
                        number += 1
                        id = callID(number)
                    }
                    return ["role": "tool", "tool_call_id": .string(id), "content": .string(message.content)]
                }
                return ["role": .string(message.role), "content": .string(message.content)]
            }
        }

        /// The request body for one generation.
        ///
        /// - Parameters:
        ///   - request: The framework's request.
        ///   - model: What the server calls the model.
        ///   - think: `enable_thinking` for the chat template, or nil to send none.
        /// - Returns: The body.
        static func body(
            for request: LanguageModelExecutorGenerationRequest, model: String, think: Bool? = nil
        ) -> JSONValue {
            var body: [String: JSONValue] = [
                "model": .string(model), "messages": .array(messages(from: request.transcript)), "stream": true,
                "stream_options": ["include_usage": true],
            ]
            let tools: [JSONValue] = request.enabledToolDefinitions.map { definition in
                [
                    "type": "function",
                    "function": [
                        "name": .string(definition.name), "description": .string(definition.description),
                        "parameters": ChatMessage.json(definition.parameters),
                    ],
                ]
            }
            if !tools.isEmpty { body["tools"] = .array(tools) }
            if let schema = request.schema {
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": ["name": "reply", "strict": true, "schema": ChatMessage.json(schema)],
                ]
            }
            if let temperature = request.generationOptions.temperature { body["temperature"] = .double(temperature) }
            if let tokens = request.generationOptions.maximumResponseTokens { body["max_tokens"] = .int(tokens) }
            if let think { body["chat_template_kwargs"] = ["enable_thinking": .bool(think)] }
            return .object(body)
        }

        /// Sends the request and streams the reply back as events.
        ///
        /// - Throws: `OpenAICompatibleModel.Failure`, or `LanguageModelError.contextSizeExceeded` when the server
        ///   says the request does not fit its window.
        nonisolated(nonsending) public func respond(
            to request: LanguageModelExecutorGenerationRequest, model: OpenAICompatibleModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let settings = OpenAICompatibleSettings(
                baseURL: configuration.baseURL, timeout: .seconds(configuration.timeoutSeconds),
                apiKey: configuration.apiKey)
            var http = OpenAICompatibleModel.request(
                "v1/chat/completions", settings: settings, timeout: TimeInterval(configuration.timeoutSeconds))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            http.httpBody = try encoder.encode(Self.body(for: request, model: model.serverID, think: model.think))
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: http)
            } catch {
                throw failure(error, streaming: false)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var body = ""
                for try await line in bytes.lines where body.count < 4096 { body += line }
                throw refusal(status: status, body: body, window: model.window)
            }
            var relay = ReplyRelay(request: request, channel: channel)
            var stream = StreamState()
            do {
                for try await line in bytes.lines {
                    try await hand(line, window: model.window, stream: &stream, relay: &relay)
                    if stream.ended { break }
                }
            } catch let failure as Failure {
                throw failure
            } catch let error as LanguageModelError {
                throw error
            } catch {
                throw failure(error, streaming: true)
            }
            // A stream that ends before a choice finished was cut short, however cleanly the connection closed:
            // what came is not the whole reply, so it must not be taken for one, and no call it began is made.
            guard stream.finished || stream.ended else {
                throw Failure.interrupted(
                    configuration.dialect, configuration.baseURL,
                    "the stream ended before \(configuration.dialect.runtime) finished the reply")
            }
            for call in stream.calls {
                await relay.call(call.name, try Self.arguments(call, dialect: configuration.dialect))
            }
            await relay.finish()
            await report(stream.usage, thought: relay.thinkingTokens, model: model, channel: channel)
        }

        /// Sends the request's usage: the server's counts, and, when it gives no count of the thinking, the chunks
        /// of thinking, one token each, within the output.
        ///
        /// - Parameters:
        ///   - usage: The usage the last chunk reported, if any.
        ///   - thought: The chunks of thinking.
        ///   - model: The model, which keeps the input count.
        ///   - channel: Where the event goes.
        nonisolated(nonsending) private func report(
            _ usage: Usage?, thought: Int, model: OpenAICompatibleModel,
            channel: LanguageModelExecutorGenerationChannel
        ) async {
            let input = usage?.prompt_tokens ?? 0
            let reasoning = usage?.completion_tokens_details?.reasoning_tokens ?? thought
            let output = max(usage?.completion_tokens ?? 0, reasoning)
            model.usage.value.withLock { $0 = usage?.prompt_tokens }
            await channel.send(
                .response(
                    action: .updateUsage(
                        input: .init(
                            totalTokenCount: input,
                            cachedTokenCount: usage?.prompt_tokens_details?.cached_tokens ?? 0),
                        output: .init(totalTokenCount: output, reasoningTokenCount: reasoning))))
        }

        /// What the stream has said so far beyond what the relay took.
        struct StreamState {
            /// Whether a choice finished (`finish_reason`).
            var finished = false
            /// Whether the server sent `[DONE]`.
            var ended = false
            /// The usage, from the chunk that carries it.
            var usage: Usage?
            /// The tool calls gathered from their fragments, in order.
            var calls: [PendingCall] = []
        }

        /// A tool call gathered from its fragments.
        struct PendingCall: Equatable {
            /// The fragment's `index`, when the server gives one.
            var index: Int?
            /// The call's id, when the server gives one.
            var id: String?
            /// The tool's name.
            var name = ""
            /// The arguments' JSON text so far.
            var arguments = ""
        }

        /// One streamed chunk.
        struct Chunk: Decodable {
            /// The choices; one, as wisp asks.
            var choices: [Choice]?
            /// The usage, on the last chunk when `include_usage` is honoured.
            var usage: Usage?
            /// An error the server streams instead of a chunk.
            var error: JSONValue?

            /// One choice's fragment.
            struct Choice: Decodable {
                /// What it adds.
                var delta: Delta?
                /// Why it finished, on its last fragment: `stop`, `tool_calls`, `length`.
                var finish_reason: String?
            }

            /// What a fragment adds.
            struct Delta: Decodable {
                /// Reply text.
                var content: String?
                /// Thinking, as llama.cpp and LM Studio's DeepSeek setting stream it.
                var reasoning_content: String?
                /// Thinking, as LM Studio streams it since 0.3.23.
                var reasoning: String?
                /// Tool-call fragments.
                var tool_calls: [ToolCallDelta]?
            }

            /// A tool-call fragment.
            struct ToolCallDelta: Decodable {
                /// Which call it belongs to.
                var index: Int?
                /// The call's id, on its first fragment.
                var id: String?
                /// The function's name and a piece of its arguments.
                var function: Function?

                /// The name and the arguments' text.
                struct Function: Decodable {
                    /// The name, on its first fragment.
                    var name: String?
                    /// A piece of the arguments' JSON text.
                    var arguments: String?
                }
            }
        }

        /// Token usage as OpenAI's API reports it.
        struct Usage: Decodable, Equatable {
            /// Input tokens.
            var prompt_tokens: Int?
            /// Output tokens.
            var completion_tokens: Int?
            /// The input's cached tokens.
            var prompt_tokens_details: PromptDetails?
            /// The output's reasoning tokens.
            var completion_tokens_details: CompletionDetails?

            /// The input's breakdown.
            struct PromptDetails: Decodable, Equatable {
                /// Tokens served from the server's cache.
                var cached_tokens: Int?
            }

            /// The output's breakdown.
            struct CompletionDetails: Decodable, Equatable {
                /// Tokens of thinking.
                var reasoning_tokens: Int?
            }
        }

        /// The payload of a server-sent event line: what follows `data:`; nil for a comment, another field, or a
        /// blank line. A bare JSON object, as a server may send an error, is taken as a payload too.
        ///
        /// - Parameter line: The line.
        /// - Returns: The payload.
        static func payload(of line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") { return trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            return trimmed.hasPrefix("{") ? trimmed : nil
        }

        /// Hands one line of the stream to the relay and the stream's state.
        ///
        /// - Parameters:
        ///   - line: The line.
        ///   - window: The model's window, for an overflow the server reports without one.
        ///   - stream: What the stream has said.
        ///   - relay: The reply's relay.
        /// - Throws: `Failure.badResponse` or `Failure.serverError`, or `LanguageModelError.contextSizeExceeded`.
        nonisolated(nonsending) private func hand(
            _ line: String, window: Int, stream: inout StreamState, relay: inout ReplyRelay
        ) async throws {
            guard let payload = Self.payload(of: line), !payload.isEmpty else { return }
            if payload == "[DONE]" {
                stream.ended = true
                return
            }
            let chunk: Chunk
            do {
                chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
            } catch {
                throw Failure.badResponse(configuration.dialect, String(payload.prefix(200)))
            }
            if let error = chunk.error { throw refusal(status: 200, body: Self.text(error), window: window) }
            if let usage = chunk.usage { stream.usage = usage }
            for choice in chunk.choices ?? [] {
                if let delta = choice.delta {
                    if let thought = delta.reasoning_content ?? delta.reasoning { await relay.think(thought) }
                    if let text = delta.content { await relay.reply(text) }
                    for fragment in delta.tool_calls ?? [] { Self.gather(fragment, into: &stream.calls) }
                }
                if choice.finish_reason != nil { stream.finished = true }
            }
        }

        /// Adds a tool-call fragment to the calls gathered: to the call with its `index`, or, without one, to a new
        /// call when it brings an id the last call lacks or a name the last call already has, else to the last.
        ///
        /// - Parameters:
        ///   - fragment: The fragment.
        ///   - calls: The calls so far.
        static func gather(_ fragment: Chunk.ToolCallDelta, into calls: inout [PendingCall]) {
            let position: Int
            if let index = fragment.index {
                position = calls.firstIndex { $0.index == index } ?? calls.count
            } else if let last = calls.indices.last,
                !(fragment.id != nil && fragment.id != calls[last].id)
                    && !(!(fragment.function?.name ?? "").isEmpty && !calls[last].name.isEmpty)
            {
                position = last
            } else {
                position = calls.count
            }
            if position == calls.count { calls.append(PendingCall(index: fragment.index, id: fragment.id)) }
            if let id = fragment.id, calls[position].id == nil { calls[position].id = id }
            // A name comes once; LM Studio before 0.3.16 sent an empty one after it, which must not replace it.
            if let name = fragment.function?.name, !name.isEmpty, calls[position].name.isEmpty {
                calls[position].name = name
            }
            calls[position].arguments += fragment.function?.arguments ?? ""
        }

        /// A gathered call's arguments as an object: empty text is no arguments.
        ///
        /// - Parameters:
        ///   - call: The call.
        ///   - dialect: The runtime, for the failure.
        /// - Returns: The arguments.
        /// - Throws: `Failure.badResponse` when the call has no name or its arguments are not JSON.
        static func arguments(_ call: PendingCall, dialect: OpenAICompatibleDialect) throws -> JSONValue {
            guard !call.name.isEmpty else { throw Failure.badResponse(dialect, "a tool call came without a name") }
            let text = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .object([:]) }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
                throw Failure.badResponse(
                    dialect, "the arguments of a call to \(call.name) are not JSON: \(String(text.prefix(200)))")
            }
            return value
        }

        /// The failure for an error from the connection.
        ///
        /// - Parameters:
        ///   - error: What `URLSession` threw.
        ///   - streaming: Whether the response had begun.
        /// - Returns: The failure.
        func failure(_ error: any Error, streaming: Bool) -> Failure {
            let (dialect, url) = (configuration.dialect, configuration.baseURL)
            return switch ConnectionFailure(error, streaming: streaming) {
            case .timedOut: .timedOut(dialect, url, seconds: configuration.timeoutSeconds)
            case .interrupted(let detail): .interrupted(dialect, url, detail)
            case .unreachable(let detail): .unreachable(dialect, url, detail)
            }
        }

        /// The error for a refusal: a key refused, the request too large for the server's window, which the agent
        /// recovers from by condensing as it does for every model that says so (llama.cpp reports
        /// `exceed_context_size_error` with `n_prompt_tokens` and `n_ctx`), or another server error.
        ///
        /// - Parameters:
        ///   - status: The HTTP status; 200 for an error streamed in place of a chunk.
        ///   - body: What the server said.
        ///   - window: The model's window, when the server does not say its own.
        /// - Returns: The error.
        func refusal(status: Int, body: String, window: Int) -> any Error {
            let dialect = configuration.dialect
            if status == 401 || status == 403 {
                return Failure.refused(
                    dialect, configuration.baseURL, status: status, keySet: configuration.apiKey != nil)
            }
            let json = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
            let error = json?.objectValue?["error"]?.objectValue ?? json?.objectValue ?? [:]
            let message = error["message"]?.stringValue ?? json?.objectValue?["error"]?.stringValue ?? body
            if Self.isOverflow(type: error["type"]?.stringValue, message: message) {
                let size = error["n_ctx"]?.intValue ?? window
                return LanguageModelError.contextSizeExceeded(
                    .init(
                        contextSize: size, tokenCount: error["n_prompt_tokens"]?.intValue ?? size + 1,
                        debugDescription: "\(dialect.runtime): \(message)", metadata: [:]))
            }
            return Failure.serverError(dialect, status: status, body: String(message.prefix(200)))
        }

        /// Whether an error says the request does not fit the window: llama.cpp's `exceed_context_size_error`, or a
        /// message that says the context's size or length was exceeded.
        ///
        /// - Parameters:
        ///   - type: The error's `type`.
        ///   - message: Its message.
        /// - Returns: Whether it is an overflow.
        static func isOverflow(type: String?, message: String) -> Bool {
            if type == "exceed_context_size_error" { return true }
            let text = message.lowercased()
            let names = ["context size", "context length", "context window", "context_length"]
            let verbs = ["exceed", "too long", "overflow", "larger than", "greater than"]
            return names.contains { text.contains($0) } && verbs.contains { text.contains($0) }
        }

        /// A streamed error as text: its message when it has one.
        ///
        /// - Parameter error: The error value.
        /// - Returns: JSON text for `refusal` to read.
        static func text(_ error: JSONValue) -> String {
            let wrapped: JSONValue = ["error": error]
            return (try? JSONEncoder().encode(wrapped)).map { String(decoding: $0, as: UTF8.self) } ?? "\(error)"
        }
    }
}

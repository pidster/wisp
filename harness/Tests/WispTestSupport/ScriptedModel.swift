import Foundation
import FoundationModels
import Synchronization
import WispCore

/// A `LanguageModel` that answers from a script, so the framework's real tool loop, streaming, and
/// transcript can be driven in tests with no model. Each executor request consumes the next step:
/// `.call` emits a tool call, `.say` emits text (with `{tool}` replaced by the last tool output) in
/// word-sized fragments. When the script runs out the model says "done". `overflowOnce` makes the
/// first request throw `contextSizeExceeded` after streaming `partialBeforeOverflow`, to exercise
/// recovery.
public struct ScriptedModel: LanguageModel {
    /// One thing the model does on one executor request.
    public enum Step: Sendable, Equatable {
        /// Call `name` with JSON `arguments`.
        case call(name: String, arguments: String)
        /// Reply with text; `{tool}` is replaced by the most recent tool output.
        case say(String)
        /// Think aloud, word by word as reasoning events through the turn's observer as an Ollama model's thinking
        /// is (ADR 0053), then perform the next step in the same request.
        case think(String)
    }

    /// Mutable script state, behind a Mutex in a class as the concurrency rules require.
    public final class Script: Sendable {
        /// Steps still to perform.
        public let steps: Mutex<[Step]>
        /// Every request the executor received, in order.
        public let requests = Mutex<[LanguageModelExecutorGenerationRequest]>([])
        /// Whether the next request throws context overflow.
        public let overflowOnce: Mutex<Bool>
        /// How many requests, after `overflowOnce`'s, throw context overflow too: 1 makes a retry overflow again.
        public let overflows = Mutex(0)
        /// The window and the request's size a scripted overflow reports.
        public let overflowSize = Mutex((contextSize: 10, tokenCount: 11))
        /// Text streamed before the scripted overflow, so a retry starts from a non-prefix.
        public let partialBeforeOverflow: String
        /// Input tokens the last request reported; the model plays a runtime that reports usage.
        public let lastInputTokens = Mutex<Int?>(nil)
        /// Whether requests report their input tokens; false plays the on-device model, which does not.
        public let reportsUsage: Bool

        init(steps: [Step], overflowOnce: Bool, partialBeforeOverflow: String, reportsUsage: Bool) {
            self.steps = Mutex(steps)
            self.overflowOnce = Mutex(overflowOnce)
            self.partialBeforeOverflow = partialBeforeOverflow
            self.reportsUsage = reportsUsage
        }
    }

    /// The executor the framework drives.
    public struct Executor: LanguageModelExecutor {
        /// Nothing to configure.
        public typealias Configuration = Int
        /// The model this executor serves.
        public typealias Model = ScriptedModel

        /// Required by the protocol; nothing to configure.
        public init(configuration: Int) throws {}

        /// The text of the last tool output in the transcript, if any.
        static func lastToolOutput(in transcript: Transcript) -> String? {
            for entry in transcript.reversed() {
                if case .toolOutput(let output) = entry {
                    return output.segments.compactMap { if case .text(let text) = $0 { text.content } else { nil } }
                        .joined()
                }
            }
            return nil
        }

        /// Performs the next scripted step.
        nonisolated(nonsending) public func respond(
            to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let script = model.script
            script.requests.withLock { $0.append(request) }
            let overflowing =
                script.overflowOnce.withLock {
                    let value = $0; $0 = false; return value
                }
                || script.overflows.withLock {
                    let value = $0 > 0; $0 = max(0, $0 - 1); return value
                }
            if overflowing {
                if !script.partialBeforeOverflow.isEmpty {
                    await channel.send(.response(action: .appendText(script.partialBeforeOverflow, tokenCount: 1)))
                }
                let size = script.overflowSize.withLock { $0 }
                throw LanguageModelError.contextSizeExceeded(
                    .init(
                        contextSize: size.contextSize, tokenCount: size.tokenCount,
                        debugDescription: "scripted overflow",
                        metadata: [:]))
            }
            var step = script.steps.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? .say("done")
            var thinking = ThinkingStretch()
            var thought = 0
            while case .think(let text) = step {
                for (index, word) in text.split(separator: " ").enumerated() {
                    let fragment = index == 0 ? String(word) : " " + word
                    thinking.think(fragment)
                    thought += 1
                    await channel.send(.reasoning(action: .appendText(fragment, tokenCount: 1)))
                }
                step = script.steps.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? .say("done")
            }
            thinking.end()
            switch step {
            case .think:
                break
            case .call(let name, let arguments):
                await channel.send(
                    .toolCalls(
                        action: .toolCall(
                            id: "call-\(UUID().uuidString.prefix(4))", name: name,
                            action: .appendArguments(arguments, tokenCount: 1))))
            case .say(let text):
                let output = Self.lastToolOutput(in: request.transcript) ?? ""
                let words = text.replacingOccurrences(of: "{tool}", with: output).split(
                    separator: " ", omittingEmptySubsequences: false)
                for (index, word) in words.enumerated() {
                    let fragment = index == 0 ? String(word) : " " + word
                    await channel.send(.response(action: .appendText(fragment, tokenCount: 1)))
                }
                if script.reportsUsage { script.lastInputTokens.withLock { $0 = 40 } }
                await channel.send(
                    .response(
                        action: .updateUsage(
                            input: .init(totalTokenCount: 40, cachedTokenCount: 0),
                            output: .init(totalTokenCount: words.count + thought, reasoningTokenCount: thought))))
            }
        }
    }

    /// The script this model plays.
    public let script: Script

    /// What this model declares; tool calling and guided generation by default, so every framework
    /// path is open. Pass fewer to test capability gating.
    public let capabilities: LanguageModelCapabilities

    /// Creates a model that first asks for `current_date` in Asia/Tokyo, then reports it.
    public init(
        steps: [Step] = [
            .call(name: "current_date", arguments: #"{"timeZone":"Asia/Tokyo"}"#), .say("The date is {tool}"),
        ],
        overflowOnce: Bool = false, partialBeforeOverflow: String = "",
        capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling, .guidedGeneration],
        reportsUsage: Bool = true
    ) {
        script = Script(
            steps: steps, overflowOnce: overflowOnce, partialBeforeOverflow: partialBeforeOverflow,
            reportsUsage: reportsUsage)
        self.capabilities = LanguageModelCapabilities(capabilities)
    }
    /// Nothing to configure.
    public var executorConfiguration: Int { 0 }
}

extension ScriptedModel: UsageReporting {
    /// 40 after any request that produced text; nil before.
    public var lastInputTokens: Int? { script.lastInputTokens.withLock { $0 } }
}

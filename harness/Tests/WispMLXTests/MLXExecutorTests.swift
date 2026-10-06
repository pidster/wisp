import Foundation
import FoundationModels
import Synchronization
import Testing
import WispCore

@testable import WispMLX

/// A tokenizer that renders a prompt as words: each message's role marker and words, each tool call's and
/// tool's name, and a closing assistant marker as the generation prompt. Prefixes behave as a chat template's
/// do: a conversation's rendering starts with the rendering of every conversation it extends.
struct WordTokenizer: PromptTokenizer {
    /// What the end of any rendered prompt reads as, for the thinking split's primed check.
    var tail = "<assistant>"

    func text(of tokens: [Int]) -> String { tail }

    func tokens(of text: String) -> [Int] { text.split(whereSeparator: \.isWhitespace).map { Self.id(String($0)) } }

    func tokens(for prompt: MLXPrompt) throws -> [Int] {
        var words: [String] = []
        for tool in prompt.tools {
            words.append("tool:" + (tool.objectValue?["function"]?.objectValue?["name"]?.stringValue ?? "?"))
        }
        for message in prompt.messages {
            words.append("<\(message.role)>")
            words += message.content.split(separator: " ").map(String.init)
            words += message.toolCalls.map { "call:\($0.name)" }
        }
        words.append("<assistant>")
        return words.map(Self.id)
    }

    /// A word's token.
    static func id(_ word: String) -> Int {
        word.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFF_FFFF }
    }
}

/// A cache as a list of tokens.
final class WordCache {
    var tokens: [Int] = []
    let trimmable: Bool
    init(trimmable: Bool) { self.trimmable = trimmable }
}

/// What the fake runtime saw and what it is to say, shared with the test.
final class RuntimeLog: Sendable {
    /// One generation: the tokens the cache held when it began, and the tokens processed onto it.
    struct Generation: Equatable {
        var cached: Int
        var suffix: Int
    }

    let generations = Mutex<[Generation]>([])
    let guided = Mutex<[String]>([])
    /// The prompt tokens each guided generation began from.
    let guidedPrompts = Mutex<[[Int]]>([])
    /// The chunks a free thinking phase streams, and how many of them were taken before it was stopped.
    let thinking: Mutex<[String]>
    let thought = Mutex<[Int]>([])
    /// Every prompt generated from, in order.
    let prompts = Mutex<[MLXPrompt]>([])
    let steps: Mutex<[[EngineEvent]]>

    init(steps: [[EngineEvent]] = [], thinking: [String] = []) {
        self.steps = Mutex(steps)
        self.thinking = Mutex(thinking)
    }

    var last: Generation? { generations.withLock { $0.last } }
}

/// A runtime that processes tokens onto a `WordCache` and replies from a script. Each generation leaves
/// `extra` generated tokens in the cache, as a real one leaves all but the last.
struct WordRuntime: PromptRuntime {
    let log: RuntimeLog
    var trimmable = true
    var extra = 2

    func makeCache() -> WordCache { WordCache(trimmable: trimmable) }
    func processed(_ cache: WordCache) -> Int { cache.tokens.count }
    func canTrim(_ cache: WordCache) -> Bool { cache.trimmable }

    func trim(_ cache: WordCache, by count: Int) -> Bool {
        guard cache.trimmable, count <= cache.tokens.count else { return false }
        cache.tokens.removeLast(count)
        return true
    }

    nonisolated(nonsending) func generate(
        suffix: [Int], cache: WordCache, prompt: MLXPrompt, maxTokens: Int, temperature: Double?,
        emit: @escaping @Sendable (EngineEvent) async -> Void
    ) async throws -> Int {
        log.generations.withLock { $0.append(.init(cached: cache.tokens.count, suffix: suffix.count)) }
        log.prompts.withLock { $0.append(prompt) }
        cache.tokens += suffix
        let events = log.steps.withLock { $0.isEmpty ? [.text("done")] : $0.removeFirst() }
        for event in events { await emit(event) }
        cache.tokens += Array(repeating: 1, count: extra)
        return extra + 1
    }

    /// Streams the scripted thinking chunks, a token each, until `emit` stops it or they run out.
    nonisolated(nonsending) func think(
        prompt: [Int], maxTokens: Int, temperature: Double?, emit: @escaping @Sendable (String) async -> Bool
    ) async throws -> [Int] {
        let chunks = log.thinking.withLock { $0 }
        var generated: [Int] = []
        for chunk in chunks.prefix(maxTokens) {
            generated.append(WordTokenizer.id(chunk))
            if await !emit(chunk) { break }
        }
        log.thought.withLock { $0.append(generated.count) }
        return generated
    }

    nonisolated(nonsending) func guided(
        prompt: [Int], schema: String, maxTokens: Int
    ) async throws -> (
        text: String, generated: Int
    ) {
        log.guided.withLock { $0.append(schema) }
        log.guidedPrompts.withLock { $0.append(prompt) }
        return (#"{"answer":"yes"}"#, 5)
    }
}

/// wisp's MLX executor without MLX: the framework's real session and tool loop over `MLXModel`, with
/// `PrefixEngine` driving a fake runtime (ADR 0052).
@Suite struct MLXExecutorTests {
    static func engine(
        _ log: RuntimeLog, trimmable: Bool = true, extra: Int = 2, tail: String = "<assistant>"
    ) -> PrefixEngine<WordRuntime> {
        PrefixEngine<WordRuntime>(
            loadTokenizer: { WordTokenizer(tail: tail) },
            loadRuntime: { WordRuntime(log: log, trimmable: trimmable, extra: extra) })
    }

    static func request(_ messages: [ChatMessage], window: Int = 4096, schema: String? = nil) -> EngineRequest {
        EngineRequest(prompt: MLXPrompt(messages: messages), schema: schema, window: window)
    }

    @Test func aReplyStreamsUsageIsReportedAndTheNextRequestReusesThePrefix() async throws {
        let log = RuntimeLog(steps: [[.text("Hello"), .text(" there")], [.text("Again")]])
        let engine = Self.engine(log)
        let model = MLXModel(engine: engine, window: 4096, capabilities: [])
        let session = LanguageModelSession(model: model, instructions: "be brief")
        #expect(try await session.respond(to: "hi").content == "Hello there")
        let first = try WordTokenizer().tokens(
            for: MLXPrompt(messages: [.init(role: "system", content: "be brief"), .init(role: "user", content: "hi")]))
        #expect(model.lastInputTokens == first.count)
        #expect(log.last == .init(cached: 0, suffix: first.count))
        #expect(try await session.respond(to: "more").content == "Again")
        // The slot kept exactly the first prompt, so the second request processed only what followed it.
        let second = try #require(model.lastInputTokens)
        #expect(log.last == .init(cached: first.count, suffix: second - first.count))
        // The framework's running totals carry the reported input, and the reused prefix as cached tokens.
        #expect(session.usage.input.totalTokenCount == first.count + second)
        #expect(session.usage.input.cachedTokenCount == first.count)
    }

    @Test func theToolLoopRunsAndEachRoundReusesTheLastPrompt() async throws {
        let log = RuntimeLog(steps: [
            [.toolCall(name: "current_date", arguments: ["timeZone": "Asia/Tokyo"])], [.text("It is today.")],
        ])
        let engine = Self.engine(log)
        let resolved = MLXBackend.resolved(
            selection: .local(backend: "mlx", name: "words"), engine: engine, capabilities: [.toolCalling],
            declared: true, sizing: .init(window: 4096, reason: "configured as mlx.contextLength"), asset: "/m")
        #expect(resolved.contextSize == 4096 && resolved.contextNote == "configured as mlx.contextLength")
        #expect(resolved.capabilityNames == ["toolCalling"] && resolved.capabilitySource == .configuration)
        let agent = Agent(instructions: "Use the tool.", tools: [CurrentDateTool()], model: resolved)
        let reply = try await agent.respond(to: "What is the date in Tokyo?")
        #expect(reply.text == "It is today.")
        #expect(agent.transcript.contains { if case .toolOutput = $0 { true } else { false } })
        let rounds = log.generations.withLock { $0 }
        #expect(rounds.count == 2)
        #expect(rounds[1].cached == rounds[0].suffix && rounds[1].suffix > 0)
        #expect(agent.lastInputTokens == rounds[1].cached + rounds[1].suffix)
        // Exact counts come from the tokenizer: the composed transcript, tools included.
        let counted = try #require(try await agent.contextTokens())
        #expect(counted > 0)
    }

    @Test func aPromptThatDoesNotFitIsAnOverflow() async throws {
        let log = RuntimeLog()
        let model = MLXModel(engine: Self.engine(log), window: 4, capabilities: [])
        let session = LanguageModelSession(model: model, instructions: "a long set of instructions")
        do {
            _ = try await session.respond(to: "hello")
            Issue.record("an oversized prompt was generated from")
        } catch LanguageModelError.contextSizeExceeded(let details) {
            #expect(details.contextSize == 4 && details.tokenCount > 4)
        }
        #expect(log.generations.withLock { $0.isEmpty })
    }

    @Test func aDivergentPromptTrimsBackToTheCommonPrefixOrRebuilds() async throws {
        let base: [ChatMessage] = [.init(role: "system", content: "s"), .init(role: "user", content: "one two")]
        let changed: [ChatMessage] = [.init(role: "system", content: "s"), .init(role: "user", content: "one three")]
        let log = RuntimeLog()
        let engine = Self.engine(log)
        let slot = UUID()
        _ = try await engine.respond(Self.request(base), slot: slot) { _ in }
        let usage = try await engine.respond(Self.request(changed), slot: slot) { _ in }
        // <system> s <user> one: four tokens in common.
        #expect(usage.reused == 4 && log.last == .init(cached: 4, suffix: usage.prompt - 4))
        let expected = try WordTokenizer().tokens(for: MLXPrompt(messages: changed))
        #expect(await engine.slotTokens[slot] == expected)

        // A cache that cannot drop tokens keeps a prompt it extends, and rebuilds for one that diverges.
        let fixed = RuntimeLog()
        let untrimmable = Self.engine(fixed, trimmable: false, extra: 0)
        _ = try await untrimmable.respond(Self.request(base), slot: slot) { _ in }
        let extended = try await untrimmable.respond(
            Self.request(base + [.init(role: "assistant", content: "ok"), .init(role: "user", content: "more")]),
            slot: slot
        ) { _ in }
        #expect(extended.reused > 0)
        let diverged = try await untrimmable.respond(Self.request(changed), slot: slot) { _ in }
        #expect(diverged.reused == 0 && fixed.last?.cached == 0)
    }

    @Test func slotsAreSeparateAndAReleasedSlotIsForgotten() async throws {
        let log = RuntimeLog()
        let engine = Self.engine(log)
        let messages: [ChatMessage] = [.init(role: "user", content: "hello world")]
        do {
            let first = MLXModel.Slot(engine: engine)
            let second = MLXModel.Slot(engine: engine)
            _ = try await engine.respond(Self.request(messages), slot: first.id) { _ in }
            let other = try await engine.respond(Self.request(messages), slot: second.id) { _ in }
            #expect(other.reused == 0)
            #expect(await engine.slotTokens.count == 2)
        }
        // Both slots went out of scope; their release runs on a task of its own.
        for _ in 0..<100 {
            if await engine.slotTokens.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.slotTokens.isEmpty)
        #expect(engine.isLoaded)
    }

    @Test func aSchemaReplyIsGuidedOnACacheOfItsOwn() async throws {
        let log = RuntimeLog()
        let engine = Self.engine(log)
        let slot = UUID()
        let collected = Mutex<[EngineEvent]>([])
        let usage = try await engine.respond(
            Self.request([.init(role: "user", content: "answer")], schema: #"{"type":"object"}"#), slot: slot
        ) { event in collected.withLock { $0.append(event) } }
        #expect(collected.withLock { $0 } == [.text(#"{"answer":"yes"}"#)])
        #expect(usage.generated == 5 && usage.reused == 0)
        #expect(log.guided.withLock { $0 } == [#"{"type":"object"}"#])
        #expect(await engine.slotTokens.isEmpty && log.generations.withLock { $0.isEmpty })
    }

    @Generable struct Verdict {
        @Guide(description: "yes or no") var answer: String
    }

    @Test func aGuidedRequestThroughTheSessionCarriesTheSchema() async throws {
        let log = RuntimeLog()
        let model = MLXModel(engine: Self.engine(log), window: 4096, capabilities: [.guidedGeneration])
        let session = LanguageModelSession(model: model)
        let verdict = try await session.respond(to: "Is it?", generating: Verdict.self).content
        #expect(verdict.answer == "yes")
        let schema = try #require(log.guided.withLock { $0.first })
        #expect(schema.contains("answer"))
    }

    /// The capability check over wisp's MLX executor with the fake runtime (ADR 0056, refined 2026-10-04): each
    /// question resolves the model with the capability it tries declared, as `Session.checkModels` resolves it
    /// through `MLXBackend.declaring`. The fake answers a plain reply, then calls `record_word` with `heron` and
    /// replies; its schema reply is `{"answer":"yes"}`, which is not the question's schema, so that check fails.
    @Test func theCapabilityCheckRunsOverTheExecutor() async throws {
        let log = RuntimeLog(steps: [
            [.text("Hello")], [.toolCall(name: "record_word", arguments: ["word": "heron"])], [.text("Recorded.")],
        ])
        let engine = Self.engine(log)
        let lines = Mutex<[String]>([])
        let results = await ModelVerification.run(
            limits: .init(first: .seconds(10), each: .seconds(10)),
            progress: { result in lines.withLock { $0.append(result.line) } }
        ) { capabilities in
            let config = MLXBackend().declaring(
                .init(capabilities: capabilities.map(\.rawValue)), for: "words", in: Config().resolved)
            let (declared, _) = try MLXBackend.declaredCapabilities(for: "words", config: config)
            return MLXBackend.resolved(
                selection: .local(backend: "mlx", name: "words"), engine: engine, capabilities: declared,
                declared: true, sizing: .init(window: 4096, reason: "configured as mlx.contextLength"), asset: "/m")
        }
        #expect(results.map(\.probe) == [.reply, .toolCalling, .guidedGeneration])
        #expect(results.map(\.passed) == [true, true, false])
        #expect(results[1].detail == "record_word(word: heron)")
        #expect(log.guided.withLock { $0.count } == 1)
        #expect(lines.withLock { $0.count } == 3)
        let decision = try #require(ModelVerification.decide(results, existing: nil, date: "2026-10-04"))
        #expect(decision.capabilities == ["toolCalling"] && decision.check.failed == ["guidedGeneration"])
    }

    @Test func countsUseTheToolsTheInstructionsDeclare() async throws {
        let model = MLXModel(engine: Self.engine(RuntimeLog()), window: 4096, capabilities: [.toolCalling])
        let withTool = LanguageModelSession(model: model, tools: [CurrentDateTool()], instructions: "x").transcript
        let without = LanguageModelSession(model: model, instructions: "x").transcript
        #expect(try await model.tokenCount(for: withTool) == model.tokenCount(for: without) + 1)
    }

    @Test func thePlanKeepsTheLongestCommonPrefixAndProcessesAtLeastOneToken() {
        #expect(PrefixPlan.plan(cached: [], prompt: [1, 2], trimmable: true) == .rebuild)
        #expect(PrefixPlan.plan(cached: [9], prompt: [1, 2], trimmable: true) == .rebuild)
        #expect(
            PrefixPlan.plan(cached: [1, 2], prompt: [1, 2, 3], trimmable: false)
                == .init(reused: 2, trimmed: 0, rebuild: false))
        #expect(
            PrefixPlan.plan(cached: [1, 2, 3], prompt: [1, 2, 4], trimmable: true)
                == .init(reused: 2, trimmed: 1, rebuild: false))
        #expect(PrefixPlan.plan(cached: [1, 2, 3], prompt: [1, 2, 4], trimmable: false) == .rebuild)
        // The same prompt again keeps all but its last token, which is processed for the next one.
        #expect(
            PrefixPlan.plan(cached: [1, 2, 3], prompt: [1, 2, 3], trimmable: true)
                == .init(reused: 2, trimmed: 1, rebuild: false))
    }

    @Test func thePoolHoldsAtMostOneWindowDroppingTheLeastRecentlyUsed() {
        var pool = PromptCachePool<Int>()
        let (a, b, c) = (UUID(), UUID(), UUID())
        pool.put(a, tokens: [1, 2, 3, 4], cache: 0, capacity: 10)
        pool.put(b, tokens: [1, 2, 3], cache: 0, capacity: 10)
        #expect(pool.heldTokens == 7)
        let dropped = pool.put(c, tokens: [1, 2, 3, 4, 5], cache: 0, capacity: 10)
        #expect(dropped == [a] && pool.heldTokens == 8)
        // A slot longer than the window on its own is not kept.
        pool.put(b, tokens: Array(0..<11), cache: 0, capacity: 10)
        #expect(pool.slots[b] == nil && pool.slots[c] != nil)
        #expect(pool.take(c)?.tokens == [1, 2, 3, 4, 5] && pool.slots.isEmpty)
    }
}

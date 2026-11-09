import Foundation
import FoundationModels
import Synchronization
import Testing
import WispCore

@testable import WispCoreAI

/// Text pieces as tokens: each distinct piece gets the next id, and a token's text is its piece's.
final class Vocabulary: Sendable {
    /// The pieces, by id.
    private let pieces = Mutex<[String]>([])

    /// A piece's token, made on first use.
    func id(_ piece: String) -> Int {
        pieces.withLock { pieces in
            if let index = pieces.firstIndex(of: piece) { return index }
            pieces.append(piece)
            return pieces.count - 1
        }
    }

    /// Tokens' text, joined.
    func text(_ tokens: [Int]) -> String {
        pieces.withLock { pieces in tokens.map { pieces[$0] }.joined() }
    }
}

/// A tokenizer that renders each message as a role marker and its content, each tool as its name, and `tail` as the
/// generation prompt, so a test sets what the prompt ends with.
struct PieceTokenizer: CoreAITokenizing {
    let vocabulary: Vocabulary
    var tail = "<assistant>"
    var stopTokens: Set<Int32> { [Int32(vocabulary.id("<eos>")), Int32(vocabulary.id("<|eot|>"))] }

    func tokens(for prompt: CoreAIPrompt) throws -> [Int] {
        var pieces: [String] = []
        for tool in prompt.tools ?? [] {
            let function = tool["function"] as? [String: any Sendable]
            pieces.append("tool:\(function?["name"] as? String ?? "?")")
        }
        for message in prompt.messages {
            pieces.append("<\(message["role"] as? String ?? "?")>")
            pieces.append(message["content"] as? String ?? "")
        }
        if let enabled = prompt.context?["enable_thinking"] as? Bool { pieces.append("enable_thinking=\(enabled)") }
        pieces.append(tail)
        return pieces.map(vocabulary.id)
    }

    func text(of tokens: [Int]) -> String { vocabulary.text(tokens) }
}

/// What the fake generator is to say, and what it saw.
final class GeneratorLog: Sendable {
    /// One script of pieces per generation.
    let scripts: Mutex<[[String]]>
    /// The prompts generated from.
    let prompts = Mutex<[[Int]]>([])
    /// The same prompts as text.
    let promptTexts = Mutex<[String]>([])
    /// Pieces generated per generation, stop tokens excluded.
    let generated = Mutex<[Int]>([])
    /// Guided generations' schemas.
    let guided = Mutex<[String]>([])
    /// Shutdowns.
    let shutdowns = Mutex(0)
    /// Loads.
    let loads = Mutex(0)

    init(_ scripts: [[String]]) { self.scripts = Mutex(scripts) }
}

/// A generator that streams a script, stopping at a stop token, the budget, or when told to.
struct ScriptGenerator: CoreAIGenerating {
    let vocabulary: Vocabulary
    let log: GeneratorLog
    var reused = 0

    func generate(
        prompt: [Int], maxTokens: Int, temperature: Double?, stopTokens: Set<Int32>,
        emit: @Sendable (Int32) async -> Bool
    ) async throws -> (generated: Int, reused: Int) {
        log.prompts.withLock { $0.append(prompt) }
        log.promptTexts.withLock { $0.append(vocabulary.text(prompt)) }
        let script = log.scripts.withLock { $0.isEmpty ? ["done", "<eos>"] : $0.removeFirst() }
        var generated = 0
        for piece in script {
            let token = Int32(vocabulary.id(piece))
            if stopTokens.contains(token) || generated == maxTokens { break }
            generated += 1
            guard await emit(token) else { break }
        }
        log.generated.withLock { $0.append(generated) }
        return (generated, reused)
    }

    func guided(
        prompt: [Int], schema: String, maxTokens: Int, temperature: Double?
    ) async throws -> (
        text: String, generated: Int
    ) {
        log.guided.withLock { $0.append(schema) }
        return (#"{"answer": "yes"}"#, 5)
    }

    func shutdown() async { log.shutdowns.withLock { $0 += 1 } }
}

/// A reply with a schema.
@Generable struct Verdict {
    /// The answer.
    @Guide(description: "yes or no") var answer: String
}

/// wisp's Core AI executor without a model: the framework's real session and tool loop over a script.
@Suite struct CoreAIExecutorTests {
    /// The `<think>` tags.
    static let think = ThinkingFormat(open: "<think>", close: "</think>", toggle: false)

    /// An engine over a script, and its log.
    static func engine(
        _ scripts: [[String]], tail: String = "<assistant>", reused: Int = 0
    ) -> (CoreAIEngine, GeneratorLog) {
        let vocabulary = Vocabulary()
        let log = GeneratorLog(scripts)
        let engine = CoreAIEngine(
            loadTokenizer: { PieceTokenizer(vocabulary: vocabulary, tail: tail) },
            loadGenerator: {
                log.loads.withLock { $0 += 1 }
                return ScriptGenerator(vocabulary: vocabulary, log: log, reused: reused)
            })
        return (engine, log)
    }

    /// A resolved model over an engine.
    static func resolved(_ engine: CoreAIEngine, format: ReplyFormat, window: Int = 4096) -> ResolvedModel {
        let model = CoreAIModel(
            engine: engine, window: window, capabilities: [.toolCalling, .reasoning, .guidedGeneration],
            replyFormat: format)
        return ResolvedModel(
            selection: .local(backend: "coreai", name: "script"), custom: model, asset: "/b", contextSize: window,
            countTokens: { try await model.tokenCount(for: $0) })
    }

    @Test func thinkingTheTemplateOpenedIsSplitOffAndAnXMLCallRunsTheTool() async throws {
        // Nemotron and Qwen3.5 as they ran on 2026-10-05: the prompt ends inside `<think>`, the model closes it, then
        // writes a call in the XML form, which the bridge dropped.
        let (engine, log) = Self.engine(
            [
                [
                    "Let's call ", "the tool.", "\n</think>\n\n", "<tool_call>\n<function=current_date>\n",
                    "<parameter=timeZone>\nAsia/Tokyo\n</parameter>\n</function>\n</tool_call>", "<eos>",
                ],
                ["The date is known.", "\n</think>\n\n", "It is today.", "<eos>"],
            ], tail: "<assistant>\n<think>\n")
        let agent = Agent(
            instructions: "Use the tool.", tools: [CurrentDateTool()],
            model: Self.resolved(engine, format: .tagged(Self.think)))
        let reply = try await agent.respond(to: "What is the date in Tokyo?")
        #expect(reply.text == "It is today.")
        let calls = agent.transcript.compactMap { entry -> [Transcript.ToolCall]? in
            if case .toolCalls(let calls) = entry { return Array(calls) }
            return nil
        }.flatMap { $0 }
        #expect(calls.map(\.toolName) == ["current_date"])
        #expect(calls.first?.arguments.jsonString.contains("Asia/Tokyo") == true)
        #expect(log.prompts.withLock { $0.count } == 2)
    }

    @Test func anAnswerLeftInsideTheOpenedBlockIsTheReply() async throws {
        // Nemotron after a tool result (probed 2026-10-08): it answers without closing the block the prompt opened.
        let (engine, _) = Self.engine([["Today is ", "October 8.", "<eos>"]], tail: "<assistant>\n<think>\n")
        let session = LanguageModelSession(
            model: CoreAIModel(
                engine: engine, window: 4096, capabilities: [.reasoning], replyFormat: .tagged(Self.think)))
        #expect(try await session.respond(to: "Date?").content == "Today is October 8.")
    }

    @Test func aFrameThatIsNoCallStaysInTheReply() async throws {
        let (engine, _) = Self.engine([["Here: ", "<tool_call>not a call</tool_call>", "<eos>"]])
        let session = LanguageModelSession(
            model: CoreAIModel(engine: engine, window: 4096, capabilities: [.toolCalling], replyFormat: .tagged(nil)),
            tools: [CurrentDateTool()])
        #expect(try await session.respond(to: "x").content == "Here: <tool_call>not a call</tool_call>")
    }

    @Test func routedMessagesAreThinkingCallsAndTheReply() async throws {
        // Muse Glimmer as it ran on 2026-10-08: messages routed to self, to a tool in ATEM, then to the user.
        let (engine, log) = Self.engine([
            [
                " to=self<|message|>", "Need the date.", "<|eom|>", "<|start|>assistant to=current_date<|message|>",
                "<atem:function_calls>\n<atem:invoke name=\"current_date\">\n</atem:invoke>\n</atem:function_calls>",
                "<|eom|>", "<|start|>tool current_date<|message|>made up", "<|eot|>",
            ],
            [
                " to=self<|message|>", "Got it.", "<|eom|>", "<|start|>assistant to=user<|message|>", "It is today.",
                "<|eot|>",
            ],
        ])
        let agent = Agent(
            instructions: "Use the tool.", tools: [CurrentDateTool()], model: Self.resolved(engine, format: .channels))
        let reply = try await agent.respond(to: "What is the date?")
        #expect(reply.text == "It is today.")
        #expect(agent.transcript.contains { if case .toolOutput = $0 { true } else { false } })
        // Generation stopped once the tool message ended: what the model would have made up for the tool never came.
        #expect(log.generated.withLock { $0 } == [6, 5])
    }

    @Test func aPromptThatDoesNotFitIsAnOverflow() async throws {
        let (engine, log) = Self.engine([])
        let session = LanguageModelSession(
            model: CoreAIModel(engine: engine, window: 3, capabilities: [], replyFormat: .tagged(nil)),
            instructions: "these instructions take tokens")
        await #expect(throws: LanguageModelError.self) { _ = try await session.respond(to: "hello") }
        #expect(log.loads.withLock { $0 } == 0)
    }

    @Test func usageReportsWhatCoreAIReused() async throws {
        let (engine, _) = Self.engine([["Hi", "<eos>"]], reused: 2)
        let model = CoreAIModel(engine: engine, window: 4096, capabilities: [], replyFormat: .tagged(nil))
        let session = LanguageModelSession(model: model)
        _ = try await session.respond(to: "hello")
        #expect(session.usage.input.cachedTokenCount == 2)
        #expect(model.lastInputTokens == session.usage.input.totalTokenCount)
        #expect(try await model.tokenCount(for: session.transcript) > 0)
    }

    @Test func aSchemaReplyIsConstrainedByTheEngine() async throws {
        let (engine, log) = Self.engine([])
        let session = LanguageModelSession(
            model: CoreAIModel(
                engine: engine, window: 4096, capabilities: [.guidedGeneration], replyFormat: .tagged(nil)))
        #expect(try await session.respond(to: "Is it?", generating: Verdict.self).content.answer == "yes")
        #expect(log.guided.withLock { $0.count } == 1)
    }

    @Test func shutdownWaitsForTheGeneratorAndLetsTheWeightsGo() async throws {
        let (engine, log) = Self.engine([["Hi", "<eos>"]])
        let session = LanguageModelSession(
            model: CoreAIModel(engine: engine, window: 4096, capabilities: [], replyFormat: .tagged(nil)))
        _ = try await session.respond(to: "hello")
        #expect(await engine.isLoaded)
        await engine.shutdown()
        #expect(log.shutdowns.withLock { $0 } == 1)
        #expect(await !engine.isLoaded)
        // The process registry forgets what it shut down.
        let bundle = URL(filePath: "/tmp/wisp-coreai-registry-\(UUID().uuidString)")
        let first = CoreAIEngines.engine(for: bundle) { engine }
        #expect(CoreAIEngines.engine(for: bundle) { Self.engine([]).0 } === first)
        await CoreAIEngines.shutdown()
        #expect(CoreAIEngines.engine(for: bundle) { Self.engine([]).0 } !== first)
    }
}

/// What wisp's Core AI executor takes from the turn under way: the thinking a request's scope asks (ADR 0053, amended
/// 2026-10-11) and the person's stop (ADR 0049, amended 2026-10-11), as MLX's executor does.
@Suite struct CoreAIExecutorScopeTests {
    @Test func aRequestsThinkingReachesOnlyATemplateThatTakesIt() {
        let (engine, _) = CoreAIExecutorTests.engine([])
        let toggled = CoreAIModel(
            engine: engine, window: 64, capabilities: [.reasoning],
            replyFormat: .tagged(ThinkingFormat(open: "<think>", close: "</think>", toggle: true)))
        #expect(toggled.thinkSent(nil) == nil, "nothing asked: the template's own default")
        #expect(toggled.thinkSent(.off) == .off && toggled.thinkSent(.level("high")) == .on)
        let fixed = CoreAIModel(
            engine: engine, window: 64, capabilities: [.reasoning], replyFormat: .tagged(CoreAIExecutorTests.think))
        #expect(fixed.thinkSent(.off) == nil)
        #expect(
            CoreAIModel(engine: engine, window: 64, capabilities: [], replyFormat: .channels).thinkSent(.off) == nil)
    }

    @Test func aSideCallRendersTheTemplateWithoutThinking() async throws {
        let (engine, log) = CoreAIExecutorTests.engine([["Yes", "<eos>"], ["No", "<eos>"]])
        let model = CoreAIModel(
            engine: engine, window: 4096, capabilities: [.reasoning],
            replyFormat: .tagged(ThinkingFormat(open: "<think>", close: "</think>", toggle: true)))
        _ = try await LanguageModelSession(model: model).respond(to: "a turn")
        _ = try await RequestThinking.sideCall { try await LanguageModelSession(model: model).respond(to: "a verdict") }
        let texts = log.promptTexts.withLock { $0 }
        #expect(texts.count == 2)
        #expect(!texts[0].contains("enable_thinking"))
        #expect(texts[1].contains("enable_thinking=false"))
    }

    @Test func aStoppableTurnGeneratesUntilItIsStopped() async throws {
        let (engine, log) = CoreAIExecutorTests.engine([["Fine.", "<eos>"]])
        let model = CoreAIModel(engine: engine, window: 4096, capabilities: [], replyFormat: .tagged(nil))
        let agent = Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
        let reply = try await agent.stream("hi", stop: TurnStop()) { _ in }
        #expect(reply.text == "Fine.")
        let stopped = TurnStop()
        stopped.request()
        await #expect(throws: TurnStop.Failure.stopped) { try await agent.stream("again", stop: stopped) { _ in } }
        #expect(log.prompts.withLock { $0.count } == 1, "nothing generated once stopped")
    }
}

/// The readers the executor streams a reply through, chunk by chunk.
@Suite struct ReplyReadingTests {
    @Test func theChannelSplitterHoldsMarkersSplitAcrossChunks() {
        var splitter = ChannelSplitter()
        var pieces: [ChannelSplitter.Piece] = []
        for chunk in [
            " to=se", "lf<|mess", "age|>hmm", " ok<|e", "om|><|start|>assistant to=user<|message|>Hi", "<|eot|>",
        ] {
            pieces += splitter.feed(chunk)
        }
        pieces += splitter.finish()
        #expect(
            pieces == [
                .body(target: "self", text: "hmm"), .body(target: "self", text: " ok"), .end(target: "self"),
                .body(target: "user", text: "Hi"), .end(target: "user"),
            ])
    }

    @Test func textWithNoHeaderIsTheReply() {
        var splitter = ChannelSplitter()
        #expect(splitter.feed("Just an answer") == [])
        #expect(splitter.finish() == [.body(target: "user", text: "Just an answer"), .end(target: "user")])
    }

    @Test func thinkingCutOffByTheBudgetStaysThinking() {
        let reader = ReplyReader(
            format: .tagged(CoreAIExecutorTests.think), primed: true, tools: [:])
        #expect(reader.feed("still thinking") == [.reasoning("still thinking")])
        #expect(reader.finish(stopped: false) == [])
        let stopped = ReplyReader(format: .tagged(CoreAIExecutorTests.think), primed: true, tools: [:])
        _ = stopped.feed("the answer")
        #expect(stopped.finish(stopped: true) == [.text("the answer")])
    }

    @Test func theFormatIsReadFromTheTemplate() {
        #expect(ReplyFormat.read(template: nil) == .tagged(nil))
        #expect(ReplyFormat.read(template: "{{ '<think>' }}{{ '</think>' }}") == .tagged(CoreAIExecutorTests.think))
        #expect(ReplyFormat.read(template: "'<|start|>assistant to=self<|message|>' ~ x ~ '<|eom|>'") == .channels)
    }

    @Test func theIncrementalDecoderHoldsBackIncompleteCharacters() {
        let pieces = ["caf", "\u{FFFD}", "é!"]
        var decoder = IncrementalDecoder()
        // Token 1's bytes are incomplete on their own; with token 2 they decode.
        let decode: ([Int]) -> String = { tokens in
            if tokens == [1] || tokens == [0, 1] { return tokens.map { pieces[$0] }.joined() }
            if tokens.contains(1) && tokens.contains(2) { return tokens.filter { $0 != 1 }.map { pieces[$0] }.joined() }
            return tokens.map { pieces[$0] }.joined()
        }
        #expect(decoder.add(0, decode: decode) == "caf")
        #expect(decoder.add(1, decode: decode) == "")
        #expect(decoder.add(2, decode: decode) == "é!")
    }
}

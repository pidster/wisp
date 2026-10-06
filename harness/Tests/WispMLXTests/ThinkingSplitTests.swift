import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import WispCore
@testable import WispMLX

/// The thinking split of wisp's MLX executor (ADR 0053, refined 2026-10-06): the template's tags read from it, the
/// stream split as it arrives, and the thinking taken through the same path as Ollama's.
@Suite struct ThinkingSplitTests {
    /// Qwen3's tags and its toggle, as its template (mlx-community/Qwen3-1.7B-4bit) writes them.
    static let qwen3 = """
        {%- if reasoning_content %}{{- '<|im_start|>' + message.role + '\\n<think>\\n' + reasoning_content.strip('\\n') + '\\n</think>\\n\\n' }}{%- endif %}
        {%- if add_generation_prompt %}{{- '<|im_start|>assistant\\n' }}
        {%- if enable_thinking is defined and enable_thinking is false %}{{- '<think>\\n\\n</think>\\n\\n' }}{%- endif %}
        {%- endif %}
        """

    static let think = ThinkingFormat(open: "<think>", close: "</think>", toggle: true)

    /// Every piece a stream of chunks splits into, merged where neighbours are of a kind.
    static func split(_ chunks: [String], primed: Bool = false) -> [ThinkingSplitter.Piece] {
        var splitter = ThinkingSplitter(format: think, primed: primed)
        var pieces: [ThinkingSplitter.Piece] = []
        for piece in chunks.flatMap({ splitter.feed($0) }) + splitter.finish() {
            switch (pieces.last, piece) {
            case (.thought(let a), .thought(let b)): pieces[pieces.count - 1] = .thought(a + b)
            case (.reply(let a), .reply(let b)): pieces[pieces.count - 1] = .reply(a + b)
            default: pieces.append(piece)
            }
        }
        return pieces
    }

    @Test func theTagsAndTheToggleAreReadFromTheTemplate() {
        #expect(ThinkingFormat.read(template: Self.qwen3) == Self.think)
        #expect(
            ThinkingFormat.read(template: "{{ '<thinking>' }}{{ x }}{{ '</thinking>' }}")
                == ThinkingFormat(open: "<thinking>", close: "</thinking>", toggle: false))
        // No thinking block, an opening tag alone, or no template: nothing is split.
        #expect(ThinkingFormat.read(template: "<|im_start|>{{ m.content }}<|im_end|>") == nil)
        #expect(ThinkingFormat.read(template: "{{ '<think>' }}") == nil)
        #expect(ThinkingFormat.read(template: nil) == nil)
    }

    @Test func aPromptEndsInsideABlockOnlyWhenItsLastOpeningTagIsUnclosed() {
        #expect(Self.think.promptEndsInside("<|im_start|>assistant\n<think>\n"))
        #expect(!Self.think.promptEndsInside("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        #expect(!Self.think.promptEndsInside("<|im_start|>assistant\n"))
    }

    @Test func aBlockIsSplitFromTheReplyWithTheTemplatesWhitespace() {
        #expect(
            Self.split(["<think>\nIs 91 7 times 13?\n</think>\n\nNo."])
                == [.thought("Is 91 7 times 13?"), .reply("No.")])
    }

    @Test func tagsSplitAcrossChunksAreHeldUntilWhole() {
        let text = "<think>\nIs 91 7 times 13?\n</think>\n\nNo, it is not."
        let expected: [ThinkingSplitter.Piece] = [.thought("Is 91 7 times 13?"), .reply("No, it is not.")]
        // One character a chunk, and the tokens a tokenizer would stream.
        #expect(Self.split(text.map { String($0) }) == expected)
        #expect(
            Self.split(["<th", "ink>", "\n", "Is 91", " 7 times 13?", "\n</", "think", ">\n\n", "No", ", it is not."])
                == expected)
    }

    @Test func thinkingThatIsNeverClosedStaysThinking() {
        #expect(Self.split(["<think>\n", "Let me", " count", "\n"]) == [.thought("Let me count")])
    }

    @Test func aReplyWithoutABlockIsLeftAsItIs() {
        #expect(Self.split(["Hello", " there", "\n"]) == [.reply("Hello there\n")])
        // Text that only begins like a tag is the reply's, once it is plainly not one.
        #expect(Self.split(["a <th", "is> b <"]) == [.reply("a <this> b <")])
        // An empty block, as a template writes when thinking is off, leaves nothing to show.
        #expect(Self.split(["<think>\n\n</think>\n\n", "Yes."]) == [.reply("Yes.")])
    }

    @Test func aPrimedPromptStartsInsideTheBlock() {
        #expect(Self.split(["Hmm.\n", "</think>\n\nOK"], primed: true) == [.thought("Hmm."), .reply("OK")])
    }

    @Test func aToolCallEndsTheThinkingUnderWay() {
        let split = ThinkingSplit(format: Self.think, primed: false)
        #expect(split.route(.text("<think>plan")) == [.reasoning("plan")])
        let call = EngineEvent.toolCall(name: "current_date", arguments: [:])
        #expect(split.route(call) == [call])
        #expect(split.route(.text("done")) == [.text("done")])
    }

    /// The executor end to end with the fake runtime: a Qwen3 that was not declared `reasoning` but asked to think
    /// by `mlx.think`, its thinking streamed in pieces that split the tags.
    @Test func thinkingIsCountedAuditedKeptAsReasoningAndNeverSentBack() async throws {
        let log = RuntimeLog(steps: [
            [.text("<think>\nIs 91"), .text(" 7 times"), .text(" 13?\n</th"), .text("ink>\n\nNo"), .text(".")],
            [.text("Yes.")],
        ])
        let engine = MLXExecutorTests.engine(log)
        let resolved = MLXBackend.resolved(
            selection: .local(backend: "mlx", name: "words"), engine: engine, capabilities: [], declared: false,
            sizing: .init(window: 4096, reason: "configured as mlx.contextLength"), asset: "/m",
            thinkingFormat: Self.think, think: true)
        let sink = MemoryAuditSink()
        let trail = ToolEventTrail()
        let agent = Agent(
            instructions: "x", tools: [], model: resolved,
            audit: AuditLog(session: "s", sink: sink).alsoRecording(to: trail))
        agent.toolEvents = trail
        let reply = try await agent.stream("Is 91 prime? One word.") { _ in }
        #expect(reply.text == "No.")
        // `mlx.think` reached the template.
        #expect(log.prompts.withLock { $0.first?.thinking } == true)
        // One token a chunk of thinking, within the generated total.
        #expect(agent.session.usage.output.reasoningTokenCount == 3)
        let thoughts = sink.events.filter { $0.kind == .modelReasoning }
        #expect(thoughts.map { $0.details["phase"] } == ["start", "end"])
        #expect(thoughts.last?.details["text"] == "Is 91 7 times 13?" && thoughts.last?.details["tokens"] == 3)
        let entry = try #require(agent.store.entries.first { $0.kind == .reasoning })
        #expect(entry.sources.first?.event == thoughts.last?.id)
        _ = try await agent.respond(to: "and 97?")
        let second = try #require(log.prompts.withLock { $0.last })
        let sent = second.messages.map(\.content).joined(separator: "\n")
        #expect(!sent.contains("7 times") && !sent.contains("<think>") && sent.contains("and 97?"), "\(sent)")
    }

    @Test func aPrimedPromptIsSplitFromTheFirstToken() async throws {
        let log = RuntimeLog(steps: [[.text("Counting"), .text(".\n</think>\n\n"), .text("Four.")]])
        let engine = MLXExecutorTests.engine(log, tail: "<|im_start|>assistant\n<think>\n")
        let model = MLXModel(
            engine: engine, window: 4096, capabilities: [.reasoning], thinkingFormat: Self.think)
        #expect(model.thinking)
        let session = LanguageModelSession(model: model)
        #expect(try await session.respond(to: "2+2?").content == "Four.")
        #expect(session.usage.output.reasoningTokenCount == 2)
    }

    @Test func mlxThinkDecidesOverTheDeclaredReasoning() {
        let engine = MLXExecutorTests.engine(RuntimeLog())
        #expect(!MLXModel(engine: engine, window: 64, capabilities: []).thinking)
        #expect(MLXModel(engine: engine, window: 64, capabilities: [.reasoning]).thinking)
        #expect(!MLXModel(engine: engine, window: 64, capabilities: [.reasoning], think: false).thinking)
        #expect(MLXModel(engine: engine, window: 64, capabilities: [], think: true).thinking)
        #expect(Config(mlx: .init(think: false)).resolved.mlxThink == false)
        #expect(Config().resolved.mlxThink == nil)
    }

    @Test func aModelWithoutTagsSendsItsTextAsTheReply() async throws {
        let log = RuntimeLog(steps: [[.text("<think>kept</think> as text")]])
        let model = MLXModel(engine: MLXExecutorTests.engine(log), window: 4096, capabilities: [])
        let session = LanguageModelSession(model: model)
        #expect(try await session.respond(to: "hi").content == "<think>kept</think> as text")
        #expect(session.usage.output.reasoningTokenCount == 0)
    }
}

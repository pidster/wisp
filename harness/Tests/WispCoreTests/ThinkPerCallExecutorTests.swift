import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A schema with one string, `answer`.
private func answerSchema() throws -> OutputSchema {
    try OutputSchema(
        json: .object(["type": "object", "properties": ["answer": ["type": "string"]], "required": ["answer"]]))
}

/// The executors' request bodies (ADR 0053, amended 2026-10-11): what each sends as its thinking switch for a turn,
/// for wisp's own calls, and for a model that cannot think. In the serialized suites that own the fake servers.
extension OllamaExecutorTests {
    /// The last `/api/chat` body.
    private var lastChat: String { FakeOllama.bodies(for: "/api/chat").last ?? "" }

    /// One reply chunk saying `content`, done.
    private func chunk(_ content: String) throws -> String {
        let message: JSONValue = ["message": ["role": "assistant", "content": .string(content)], "done": true]
        return String(decoding: try JSONEncoder().encode(message), as: UTF8.self) + "\n"
    }

    @Test func aModelsOwnThinkComesAheadOfTheRuntimesInTheBody() async throws {
        FakeOllama.serve(
            "/api/tags", body: #"{"models":[{"name":"q:latest","size":10},{"name":"r:latest","size":10}]}"#)
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion","tools","thinking"]}"#)
        FakeOllama.serve("/api/chat", body: try chunk("ok"))
        // Thinking on for every Ollama model, off for this one: its own setting wins.
        let config = Config(
            ollama: .init(
                baseURL: "http://fake.ollama:1", timeoutSeconds: 5, think: .on, models: ["q": .init(think: .off)])
        ).resolved
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: try ModelSelection.ollama("q").resolve(config: config),
            audit: AuditLog(session: "s", sink: sink))
        _ = try await agent.respond(to: "hi")
        #expect(lastChat.contains(#""think":false"#), "\(lastChat)")
        // The prompt's event records what the turn's requests send.
        let prompt = try #require(sink.events.last { $0.kind == .prompt })
        #expect(prompt.details["think"] == "false")
        #expect(Set(prompt.details.keys).isSubset(of: AuditEvent.fields(for: .prompt)))
        // Another model takes the runtime's.
        _ = try await Agent(instructions: "x", tools: [], model: try ModelSelection.ollama("r").resolve(config: config))
            .respond(to: "hi")
        #expect(lastChat.contains(#""think":true"#), "\(lastChat)")
    }

    @Test func sideCallsSendThinkFalseAndTurnsTheDefault() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion","tools","thinking"]}"#)
        let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 5, think: .on)).resolved
        let model = try ModelSelection.ollama("q").resolve(config: config)
        let agent = Agent(instructions: "x", tools: [], model: model)
        FakeOllama.serve("/api/chat", body: try chunk("ok"))
        _ = try await agent.respond(to: "an open question")
        #expect(lastChat.contains(#""think":true"#), "a turn keeps the model's default: \(lastChat)")
        // A schema reply asks for none; a change draft keeps the default.
        FakeOllama.serve("/api/chat", body: try chunk(#"{"answer":"a"}"#))
        _ = try await agent.respond(to: "shaped", schema: try answerSchema())
        #expect(lastChat.contains(#""think":false"#) && lastChat.contains(#""format""#), "\(lastChat)")
        _ = try await agent.respond(to: "a draft", schema: try answerSchema(), keepsThinking: true)
        #expect(lastChat.contains(#""think":true"#), "\(lastChat)")
        // The classifier's verdict asks for none, and records it.
        FakeOllama.serve("/api/chat", body: try chunk(#"{"risk":"safe","reason":"reads"}"#))
        let verdict = await ModelRiskClassifier(model: model).classify(command: "ls", workingDirectory: "/tmp")
        #expect(verdict.level == .safe && verdict.metadata["think"] == "false")
        #expect(lastChat.contains(#""think":false"#), "\(lastChat)")
        // A model that cannot think is sent nothing, a side call's choice included.
        FakeOllama.serve("/api/show", body: #"{"capabilities":["completion","tools"]}"#)
        let plain = try ModelSelection.ollama("q").resolve(config: config)
        _ = await ModelRiskClassifier(model: plain).classify(command: "ls", workingDirectory: "/tmp")
        #expect(!lastChat.contains(#""think""#), "\(lastChat)")
    }
}

extension OpenAICompatibleExecutorTests {
    @Test func llamaCppSendsEnableThinkingFalseForSideCallsToAModelThatThinks() async throws {
        FakeChatServer.serve(Self.llama, Self.chat, Self.reply([#"{"answer":"a"}"#]))
        func body(_ section: Config.OpenAICompatibleConfig, schema: OutputSchema?) async throws -> String {
            let model = try ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M").resolve(
                config: Config(llamacpp: section).resolved)
            let agent = Agent(instructions: "x", tools: [], model: model)
            if let schema {
                _ = try await agent.respond(to: "hi", schema: schema)
            } else {
                _ = try await agent.respond(to: "hi")
            }
            return FakeChatServer.bodies(Self.llama, Self.chat).last ?? ""
        }
        let off = #""chat_template_kwargs":{"enable_thinking":false}"#
        // Declared to think: a schema reply asks it not to; a turn sends nothing, leaving the template's default.
        let thinking = Config.OpenAICompatibleConfig(
            baseURL: "http://\(Self.llama):1", models: ["Qwen3-8B-Q4_K_M": .init(capabilities: ["reasoning"])])
        #expect(try await body(thinking, schema: try answerSchema()).contains(off))
        #expect(!(try await body(thinking, schema: nil).contains("chat_template_kwargs")))
        // The model's own setting comes ahead of the runtime's.
        let own = Config.OpenAICompatibleConfig(
            baseURL: "http://\(Self.llama):1", think: .on, models: ["Qwen3-8B-Q4_K_M": .init(think: .off)])
        #expect(try await body(own, schema: nil).contains(off))
        // Not known to think and nothing configured: nothing is sent, not even for a side call.
        let unknown = Config.OpenAICompatibleConfig(baseURL: "http://\(Self.llama):1")
        #expect(!(try await body(unknown, schema: try answerSchema()).contains("chat_template_kwargs")))
    }
}

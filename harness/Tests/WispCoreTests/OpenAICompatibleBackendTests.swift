import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The two backends over the fake server: listings, windows, capabilities, an unavailable or silent server, a stream
/// cut short, the key, overflow, the settings, the doctor's finding, and wisp's check of a llama.cpp model. In
/// `OpenAICompatibleExecutorTests`' suite, which is serialized, because they share `FakeChatServer`.
extension OpenAICompatibleExecutorTests {
    // MARK: - Listing and resolving

    @Test func llamaCppListsItsModelByFileNameAndReportsTheSlotsWindow() async throws {
        let backend = OpenAICompatibleBackend(.llamaCpp)
        let installed = try await backend.installed(config: Self.llamaConfig, home: Home.resolve())
        #expect(installed.map(\.selection.description) == ["llamacpp:Qwen3-8B-Q4_K_M"])
        #expect(installed.first?.parameters == "8.2B" && installed.first?.bytes == 5_027_783_488)
        let model = try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M")
        #expect(model.contextSize == 16_384)
        #expect(model.contextNote?.hasPrefix("reported by llama.cpp") == true, "\(model.contextNote ?? "")")
        #expect(model.asset == "http://\(Self.llama):1 /models/Qwen3-8B-Q4_K_M.gguf")
        // The server says nothing about tools: schema replies only, the rest undeclared until checked.
        #expect(model.capabilityNames == ["guidedGeneration"] && model.capabilitySource == .undeclared)
        #expect(throws: ModelSelection.Failure.self) { try model.check(tools: [PathTool()]) }
        // The id itself names it too.
        #expect(try Self.resolved(.llamaCpp, "/models/Qwen3-8B-Q4_K_M.gguf").contextSize == 16_384)
        // A chat template that reports tool calls declares them, by the runtime.
        FakeChatServer.serve(
            Self.llama, "/props",
            #"{"default_generation_settings":{"n_ctx":8192},"chat_template_caps":{"supports_tool_calls":true}}"#)
        let capable = try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M")
        #expect(capable.capabilityNames == ["toolCalling", "guidedGeneration"] && capable.capabilitySource == .runtime)
        // No window reported: the floor, saying why.
        FakeChatServer.serve(Self.llama, "/props", #"{"total_slots":1}"#)
        let floor = try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M")
        #expect(floor.contextSize == 8192 && floor.contextNote?.contains("the default: llama.cpp") == true)
    }

    @Test func aLlamaCppRouterNamesTheModelInProps() throws {
        FakeChatServer.serve(
            Self.llama, "/v1/models",
            #"{"data":[{"id":"gemma","status":{"value":"loaded"}},{"id":"qwen","status":{"value":"unloaded"}}]}"#)
        _ = try Self.resolved(.llamaCpp, "qwen")
        #expect(FakeChatServer.received(Self.llama, "/props").last?.query == "model=qwen")
        #expect(
            throws: ModelSelection.Failure.unavailable(
                model: "llamacpp:mistral", reason: "llama.cpp serves no model 'mistral'; it serves: gemma, qwen")
        ) { try Self.resolved(.llamaCpp, "mistral") }
    }

    @Test func lmStudioListsEveryModelWithWhatItReportsAndTheLoadedWindow() async throws {
        let backend = OpenAICompatibleBackend(.lmStudio)
        let installed = try await backend.installed(config: Self.studioConfig, home: Home.resolve())
        #expect(
            installed.map(\.selection.description) == [
                "lmstudio:qwen/qwen3-8b", "lmstudio:google/gemma-3-1b", "lmstudio:text-embedding-nomic",
            ])
        #expect(installed.first?.format == "qwen3 Q4_K_M" && installed.first?.parameters == "8B")
        let loaded = try Self.resolved(.lmStudio, "qwen/qwen3-8b")
        #expect(loaded.capabilityNames == ["toolCalling", "guidedGeneration", "reasoning"])
        #expect(loaded.capabilitySource == .runtime)
        #expect(
            loaded.contextSize == 32_768 && loaded.contextNote == "reported by LM Studio: loaded at 32,768 of 40,960")
        // Not loaded: the floor, since LM Studio loads it at its own default.
        let unloaded = try Self.resolved(.lmStudio, "google/gemma-3-1b")
        #expect(unloaded.contextSize == 8192 && unloaded.contextNote?.contains("has not loaded it") == true)
        #expect(unloaded.capabilityNames == ["guidedGeneration"])
        // An embedding model cannot hold a conversation.
        #expect(
            throws: ModelSelection.Failure.unavailable(
                model: "lmstudio:text-embedding-nomic",
                reason:
                    "LM Studio reports 'text-embedding-nomic' is an embedding model, which cannot hold a conversation")
        ) { try Self.resolved(.lmStudio, "text-embedding-nomic") }
        // A server before 0.4.0 has only the OpenAI listing: the names, and nothing reported.
        FakeChatServer.serve(Self.studio, "/api/v1/models", status: 404, "")
        FakeChatServer.serve(Self.studio, "/v1/models", #"{"data":[{"id":"old-model","object":"model"}]}"#)
        let old = try Self.resolved(.lmStudio, "old-model")
        #expect(old.capabilityNames == ["guidedGeneration"] && old.contextSize == 8192)
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func anUnavailableServerFailsFastNamingTheRuntimeAndHowToStartIt(_ dialect: OpenAICompatibleDialect) async {
        // Nothing listens at this host: the fake answers it as a refused connection.
        let config = Config(
            llamacpp: .init(baseURL: "http://down.fakeserver:1"), lmstudio: .init(baseURL: "http://down.fakeserver:1")
        ).resolved
        let started = ContinuousClock.now
        do {
            _ = try ModelSelection.local(backend: dialect.scheme, name: "m").resolve(config: config)
            Issue.record("a model resolved with no server")
        } catch {
            #expect("\(error)".contains("no \(dialect.runtime) server at http://down.fakeserver:1"), "\(error)")
            #expect("\(error)".contains(dialect.scheme + ".baseURL"), "\(error)")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        await #expect(throws: OpenAICompatibleModel.Failure.self) {
            _ = try await OpenAICompatibleBackend(dialect).installed(config: config, home: Home.resolve())
        }
        // Chat's fallback note says what to start.
        let note = ModelFallback(model: .local(backend: dialect.scheme, name: "m"), reason: "down").message
        #expect(
            note.hasSuffix(dialect == .llamaCpp ? "once llama-server is running" : "once LM Studio's server is running")
        )
    }

    @Test func theListingNamesTheRuntimeAndAServersWindow() {
        let entry = ModelListing.Entry(
            selection: .local(backend: "llamacpp", name: "m"), contextSize: 16_384,
            contextNote: OpenAICompatibleModel.window(llamaServer: 16_384, problem: nil).reason)
        #expect(entry.runtime == "llama.cpp" && entry.contextFrom == "server")
        let studio = ModelListing.Entry(
            selection: .local(backend: "lmstudio", name: "m"), contextSize: 8192,
            contextNote: OpenAICompatibleModel.window(lmStudio: .init(id: "m")).reason)
        #expect(studio.runtime == "LM Studio" && studio.contextFrom == "default")
        #expect(ModelBackends.schemes.contains("llamacpp") && ModelBackends.schemes.contains("lmstudio"))
    }

    // MARK: - A turn cut short

    /// A session on `scheme:name` at the fake server, recording to `sink`, with the timeout `timeout` seconds.
    static func session(
        _ dialect: OpenAICompatibleDialect, home: Home, sink: MemoryAuditSink, timeout: Int = 5, key: String? = nil
    ) throws -> Session {
        try home.ensure()
        let section: JSONValue = [
            "baseURL": .string("http://\(host(dialect)):1"), "timeoutSeconds": .int(timeout),
            "apiKey": key.map { .string($0) } ?? .null,
        ]
        let file: JSONValue = [
            "model": .string("\(dialect.scheme):\(toolModel(dialect))"), .init(stringLiteral: dialect.scheme): section,
        ]
        try JSONEncoder().encode(file).write(to: home.configFile)
        return try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
    }

    /// A temporary home, removed by the caller.
    static func temporaryHome() -> Home {
        Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-openai-\(UUID().uuidString)"))
    }

    /// Runs a turn that must fail, returning its error's text.
    static func failedTurn(_ agent: Agent, _ prompt: String) async -> String? {
        do {
            _ = try await agent.stream(prompt) { _ in }
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// The turn after an interruption: the server works again, and the request carries nothing of the cut reply.
    static func nextTurnSucceeds(_ agent: Agent, host: String, without partial: String) async throws {
        FakeChatServer.interruptions.withLock { $0 = [:] }
        FakeChatServer.serve(host, chat, reply(["ok"]))
        #expect(try await agent.stream("again") { _ in }.text == "ok")
        let last = FakeChatServer.bodies(host, chat).last ?? ""
        #expect(!last.contains(partial), "the interrupted reply was sent back as if it were complete")
    }

    @Test(arguments: OpenAICompatibleDialect.all)
    func aStreamThatEndsBeforeTheReplyFinishedIsAnErrorAndTheThreadGoesOn(
        _ dialect: OpenAICompatibleDialect
    ) async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(dialect, home: home, sink: sink)
        let agent = try session.thread(id: "t", approver: DenyingApprover(reason: "x"), tools: ToolSelection.none)
            .openAgent()
        // Closed cleanly, but no choice finished and no [DONE].
        FakeChatServer.serve(
            Self.host(dialect), Self.chat, Self.chunk(["content": "The answer "]) + Self.chunk(["content": "PARTIAL"]))
        let error = await Self.failedTurn(agent, "question")
        #expect(error?.contains("\(dialect.runtime) at") == true, "\(error ?? "no error")")
        #expect(error?.contains("stopped before the reply was done") == true, "\(error ?? "no error")")
        #expect(!sink.events.contains { $0.kind == .response })
        try await Self.nextTurnSucceeds(agent, host: Self.host(dialect), without: "PARTIAL")
    }

    @Test func aToolCallCutShortIsNotRunAndALostConnectionIsAnInterruption() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(.lmStudio, home: home, sink: sink)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        FakeChatServer.serve(
            Self.studio, Self.chat, body: Self.call("current_date", #"{"timeZone":"UTC"}"#), then: .drop)
        let error = await Self.failedTurn(agent, "what is the date?")
        #expect(error?.contains("LM Studio at") == true, "\(error ?? "no error")")
        #expect(!sink.events.contains { $0.kind == .toolCall || $0.kind == .toolResult })
        #expect(!sink.events.contains { $0.kind == .response })
        try await Self.nextTurnSucceeds(agent, host: Self.studio, without: "current_date\\\",\\\"arguments")
    }

    @Test func aSilentServerTimesOutWithAnErrorNamingTheSetting() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(.llamaCpp, home: home, sink: sink, timeout: 1)
        let agent = try session.thread(id: "t", approver: DenyingApprover(reason: "x"), tools: ToolSelection.none)
            .openAgent()
        FakeChatServer.serve(Self.llama, Self.chat, body: "", then: .hold)
        let started = ContinuousClock.now
        let error = await Self.failedTurn(agent, "question")
        #expect(
            error?.contains("llama.cpp at http://\(Self.llama):1 sent nothing for 1 s (llamacpp.timeoutSeconds)")
                == true, "\(error ?? "no error")")
        #expect(ContinuousClock.now - started < .seconds(15))
        try await Self.nextTurnSucceeds(agent, host: Self.llama, without: "PARTIAL")
    }

    @Test func anErrorInPlaceOfAChunkAndAnOverflowAreTyped() async throws {
        let agent = Agent(instructions: "x", tools: [], model: try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M"))
        FakeChatServer.serve(
            Self.llama, Self.chat, #"data: {"error":{"message":"model busy","type":"server_error"}}"# + "\n\n")
        await #expect(throws: OpenAICompatibleModel.Failure.serverError(.llamaCpp, status: 200, body: "model busy")) {
            _ = try await agent.respond(to: "hi")
        }
        FakeChatServer.serve(Self.llama, Self.chat, "data: {not json\n\n")
        await #expect(throws: OpenAICompatibleModel.Failure.badResponse(.llamaCpp, "{not json")) {
            _ = try await agent.respond(to: "hi")
        }
        // llama.cpp's refusal of a request larger than its slot is the framework's overflow, with its numbers.
        let executor = try OpenAICompatibleModel.Executor(
            configuration: .init(dialect: .llamaCpp, baseURL: URL(string: "http://x.fakeserver")!, timeoutSeconds: 1))
        let overflow = executor.refusal(
            status: 400,
            body:
                #"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":9000,"n_ctx":8192}}"#,
            window: 16_384)
        #expect(Agent.overflow(in: overflow).map { [$0.contextSize, $0.tokenCount] } == [8192, 9000])
        let worded = executor.refusal(
            status: 400, body: #"{"error":"Context length of 4096 was exceeded"}"#, window: 4096)
        #expect(Agent.overflow(in: worded)?.contextSize == 4096)
        guard
            case OpenAICompatibleModel.Failure.serverError(_, 500, "boom") = executor.refusal(
                status: 500, body: #"{"error":{"message":"boom"}}"#, window: 1)
        else {
            Issue.record("a server error was not typed")
            return
        }
    }

    // MARK: - The key

    @Test func theKeyIsSentAsABearerTokenAndNeverLoggedOrShown() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let secret = "sk-fake-9f8e7d6c"
        let session = try Self.session(.llamaCpp, home: home, sink: sink, key: secret)
        let agent = try session.thread(id: "t", approver: DenyingApprover(reason: "x"), tools: ToolSelection.none)
            .openAgent()
        FakeChatServer.serve(Self.llama, Self.chat, Self.reply(["ok"]))
        #expect(try await agent.respond(to: "hi").text == "ok")
        for path in ["/v1/models", "/props", Self.chat] {
            #expect(FakeChatServer.received(Self.llama, path).last?.headers["Authorization"] == "Bearer \(secret)")
        }
        // Nothing records or shows it: the audit, the settings `wisp config` and `inspect` show, the descriptions.
        let audit = String(decoding: try JSONEncoder().encode(sink.events), as: UTF8.self)
        #expect(!audit.contains(secret))
        let config = try Config.load(from: home.configFile).resolved
        let settings = OpenAICompatibleBackend(.llamaCpp).settings(in: config, home: home)
        #expect(settings.objectValue?["apiKey"] == "set (config.json)")
        #expect(!"\(settings)".contains(secret) && !"\(config.llamacpp)".contains(secret))
        #expect(!String(reflecting: config.llamacpp).contains(secret))
        #expect(
            !"\(OpenAICompatibleModel(dialect: .llamaCpp, name: "m", settings: config.llamacpp).executorConfiguration)"
                .contains(secret))
        // A refusal says what to set, not the key.
        FakeChatServer.serve(Self.llama, "/v1/models", status: 401, #"{"error":{"message":"Invalid API Key"}}"#)
        do {
            _ = try ModelSelection.local(backend: "llamacpp", name: "m").resolve(config: config)
            Issue.record("a refused key resolved")
        } catch {
            #expect(
                "\(error)".contains("refused the request (HTTP 401)") && "\(error)".contains("WISP_LLAMACPP_API_KEY"))
            #expect(!"\(error)".contains(secret))
        }
    }

    @Test func theEnvironmentsKeyWinsOverTheFilesAndAnEmptyOneIsNone() {
        let section = Config.OpenAICompatibleConfig(apiKey: "from-file")
        let fromEnvironment = OpenAICompatibleSettings.resolve(
            section, dialect: .lmStudio, environment: ["WISP_LMSTUDIO_API_KEY": "from-env"])
        #expect(fromEnvironment.apiKey == "from-env" && fromEnvironment.apiKeyState == "set (WISP_LMSTUDIO_API_KEY)")
        let fromFile = OpenAICompatibleSettings.resolve(
            section, dialect: .lmStudio, environment: ["WISP_LMSTUDIO_API_KEY": ""])
        #expect(fromFile.apiKey == "from-file" && fromFile.apiKeyState == "set (config.json)")
        let none = OpenAICompatibleSettings.resolve(nil, dialect: .llamaCpp, environment: [:])
        #expect(none.apiKey == nil && none.apiKeyState == "unset")
        #expect(none.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(OpenAICompatibleSettings.defaults(for: .lmStudio).baseURL.absoluteString == "http://127.0.0.1:1234")
        // LM Studio takes neither `think` nor declarations.
        let studio = OpenAICompatibleSettings.resolve(
            .init(think: true, models: ["m": .init(capabilities: ["toolCalling"])]), dialect: .lmStudio,
            environment: [:])
        #expect(studio.think == nil && studio.declared.isEmpty)
    }

    // MARK: - The session, the doctor, and the check

    @Test func aSessionOpensAgentsAndRecordsTheModelResolved() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(.lmStudio, home: home, sink: sink)
        #expect(session.notes.isEmpty)  // local: no egress note
        FakeChatServer.serve(Self.studio, Self.chat, Self.reply(["ok"]))
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        #expect(try await agent.respond(to: "hi").text == "ok")
        let resolved = sink.events.first { $0.kind == .modelResolved }
        #expect(resolved?.details["backend"] == "lmstudio")
        #expect(resolved?.details["capabilitySource"] == "runtime")
        #expect(resolved?.details["asset"]?.stringValue == "http://\(Self.studio):1 qwen/qwen3-8b")
        // The doctor's configured-model check resolves the same way, and names the server when it is down.
        let down = Config(lmstudio: .init(baseURL: "http://down.fakeserver:1")).resolved
        let problem = Doctor.Probes.live.configuredModel(.local(backend: "lmstudio", name: "m"), down, home)
        #expect(problem?.contains("no LM Studio server at") == true, "\(problem ?? "")")
        #expect(Doctor.Probes.live.configuredModel(session.config.model, session.config, home) == nil)
    }

    @Test func checkingALlamaCppModelRecordsWhatPassesUnderItsSection() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(.llamaCpp, home: home, sink: sink)
        #expect(OpenAICompatibleBackend(.llamaCpp).declarationKeys(for: "m") == ["llamacpp", "models", "m"])
        #expect(OpenAICompatibleBackend(.lmStudio).declarationKeys(for: "m") == nil)
        // The three questions in order: a reply, a call of record_word and the reply after it, a schema reply.
        FakeChatServer.serve(
            Self.llama, Self.chat, Self.reply(["Hello."]),
            Self.call("record_word", #"{"word":"heron"}"#) + Self.chunk([:], finish: "tool_calls") + Self.done,
            Self.reply(["Recorded."]), Self.reply([#"{"colour":"blue","number":3}"#]))
        let lines = try await session.checkModels(
            ["llamacpp:Qwen3-8B-Q4_K_M"], force: true, source: "cli", progress: { _ in })
        #expect(lines.first?.contains("tools, structured replies") == true, "\(lines)")
        let declared = try Config.load(from: home.configFile).resolved.llamacpp.declared["Qwen3-8B-Q4_K_M"]
        #expect(declared?.capabilities == ["toolCalling", "guidedGeneration"])
        #expect(declared?.verified?.passed == ["toolCalling", "guidedGeneration"])
        // Declared, the model resolves with them, from the configuration.
        let model = try ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M")
            .resolve(config: try Config.load(from: home.configFile).resolved)
        #expect(model.capabilitySource == .configuration && model.capabilityNames.contains("toolCalling"))
    }
}

import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// What the two backends make of a server that answers wrongly: a listing refused, missing, or malformed, `/props`
/// missing or malformed, a key refused mid-conversation, and the doctor's reading of each. In
/// `OpenAICompatibleExecutorTests`' suite, which is serialized, because they share `FakeChatServer`.
extension OpenAICompatibleExecutorTests {
    /// The host these tests' server answers on.
    static let edge = "edge.fakeserver"

    /// llama.cpp's settings at the edge host, under `server`.
    static func edgeSettings(_ server: LlamaCppServer = .off) -> OpenAICompatibleSettings {
        Config(llamacpp: .init(baseURL: "http://\(edge):1", timeoutSeconds: 5, server: server)).resolved.llamacpp
    }

    /// The failure listing the models at `settings` throws, if any.
    static func listingFailure(
        _ dialect: OpenAICompatibleDialect, _ settings: OpenAICompatibleSettings
    ) async -> OpenAICompatibleModel.Failure? {
        do {
            _ = try await OpenAICompatibleModel.served(by: dialect, at: settings)
            return nil
        } catch {
            return error as? OpenAICompatibleModel.Failure
        }
    }

    @Test func aListingRefusedMissingOrMalformedIsTyped() async throws {
        let settings = Self.edgeSettings()
        FakeChatServer.serve(Self.edge, "/v1/models", status: 500, "boom")
        #expect(await Self.listingFailure(.llamaCpp, settings) == .serverError(.llamaCpp, status: 500, body: "boom"))
        FakeChatServer.serve(Self.edge, "/v1/models", status: 404, "")
        #expect(
            await Self.listingFailure(.llamaCpp, settings)
                == .serverError(.llamaCpp, status: 404, body: "no /v1/models"))
        // Not a list of objects, or an entry with no id.
        for body in [#"{"object":"list"}"#, #"{"data":[1]}"#, #"{"data":[{"id":""}]}"#, "not json"] {
            FakeChatServer.serve(Self.edge, "/v1/models", body)
            #expect(await Self.listingFailure(.llamaCpp, settings) == .badResponse(.llamaCpp, body), "\(body)")
        }
        // LM Studio with neither its own listing nor OpenAI's.
        FakeChatServer.serve(Self.edge, "/api/v1/models", status: 404, "")
        FakeChatServer.serve(Self.edge, "/v1/models", status: 404, "")
        let studio = Config(lmstudio: .init(baseURL: "http://\(Self.edge):1", timeoutSeconds: 5)).resolved.lmstudio
        #expect(
            await Self.listingFailure(.lmStudio, studio)
                == .serverError(.lmStudio, status: 404, body: "no /api/v1/models or /v1/models"))
        // The doctor, under Llama.app, says the server's error.
        let app = Self.edgeSettings(.llamaApp)
        FakeChatServer.serve(Self.edge, "/v1/models", status: 500, "boom")
        let answer = await Doctor.askLlamaCppServer(app)
        #expect(answer == .failed("\(OpenAICompatibleModel.Failure.serverError(.llamaCpp, status: 500, body: "boom"))"))
    }

    @Test func propsMissingOrMalformedLeaveTheFloorSayingWhy() throws {
        FakeChatServer.serve(Self.edge, "/v1/models", Self.llamaModels)
        let config = Config(llamacpp: .init(baseURL: "http://\(Self.edge):1", timeoutSeconds: 5)).resolved
        func note() throws -> String {
            let model = try ModelSelection.local(backend: "llamacpp", name: "Qwen3-8B-Q4_K_M").resolve(config: config)
            #expect(model.contextSize == ContextSizing.floor)
            return model.contextNote ?? ""
        }
        FakeChatServer.serve(Self.edge, "/props", status: 404, "")
        #expect(
            try note().contains(
                "/props could not be read (\(OpenAICompatibleModel.Failure.serverError(.llamaCpp, status: 404, body: "no /props")))"
            ))
        FakeChatServer.serve(Self.edge, "/props", "<html>")
        #expect(
            try note().contains(
                "/props could not be read (\(OpenAICompatibleModel.Failure.badResponse(.llamaCpp, "<html>")))"))
        // LM Studio's `reasoning` as an object it does not otherwise describe says it thinks.
        #expect(Catalogs.reasons(["mode": "auto"]))
    }

    @Test func aKeyRefusedMidConversationSaysWhatToSet() async throws {
        let agent = Agent(instructions: "x", tools: [], model: try Self.resolved(.llamaCpp, "Qwen3-8B-Q4_K_M"))
        FakeChatServer.serve(Self.llama, Self.chat, status: 401, #"{"error":{"message":"Invalid API Key"}}"#)
        let failure = try #require(await Self.failedTurn(agent, "hi"))
        #expect(failure.contains("refused the request (HTTP 401)"), "\(failure)")
        #expect(failure.contains("WISP_LLAMACPP_API_KEY"), "\(failure)")
    }

    @Test func aToolOutputWithNoCallItAnswersGetsAnIdOfItsOwn() throws {
        let transcript = Transcript(entries: [
            .toolOutput(
                Transcript.ToolOutput(id: "x", toolName: "read_file", segments: [.text(.init(content: "contents"))]))
        ])
        let messages = OpenAICompatibleModel.Executor.messages(from: transcript)
        let tool = try #require(messages.last?.objectValue)
        #expect(tool["role"] == "tool" && tool["content"] == "contents")
        #expect(tool["tool_call_id"] == .string(OpenAICompatibleModel.Executor.callID(1)))
        // A server's error as a bare object in place of an event is read as a payload; other fields are not.
        #expect(OpenAICompatibleModel.Executor.payload(of: #" {"error":"x"} "#) == #"{"error":"x"}"#)
        #expect(OpenAICompatibleModel.Executor.payload(of: "event: ping") == nil)
    }
}

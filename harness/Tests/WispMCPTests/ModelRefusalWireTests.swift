import Foundation
import MCP
import Testing
import WispCore
import WispTestSupport

@testable import WispMCP

/// `respond`'s `model` over MCP: a disabled model is refused by name, and an unavailable one fails clearly rather
/// than falling back to another, as chat does (ADR 0056); the calling agent chooses its own fallback.
@Suite struct ModelRefusalWireTests {
    /// The text of a tool result.
    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _)? = result.content.first else { return "" }
        return text
    }

    @Test func aDisabledModelIsRefusedWithHowToEnableIt() async throws {
        let server = WispServer(
            session: try scratchSession(config: #"{"models":{"disabled":["ollama:granite4.1:8b"]}}"#))
        let result = try await server.call(
            .init(
                name: "respond",
                arguments: [
                    "prompt": .string("hi"), "thread_id": .string("git"), "model": .string("ollama:granite4.1:8b"),
                ]))
        #expect(result.isError == true)
        #expect(text(result).contains("model 'ollama:granite4.1:8b' is disabled"))
        #expect(text(result).contains("wisp models enable ollama:granite4.1:8b"))
    }

    @Test func anUnavailableModelFailsAndIsNotSwappedForAnother() async throws {
        // Nothing listens on port 9, so Ollama is unavailable on any Mac.
        let server = WispServer(session: try scratchSession(config: #"{"ollama":{"baseURL":"http://127.0.0.1:9"}}"#))
        let result = try await server.call(
            .init(
                name: "respond",
                arguments: [
                    "prompt": .string("hi"), "thread_id": .string("git"), "model": .string("ollama:granite4.1:8b"),
                ]))
        #expect(result.isError == true)
        #expect(text(result).contains("model 'ollama:granite4.1:8b' is unavailable: no Ollama server"))
        #expect(!text(result).contains("using system"))
    }
}

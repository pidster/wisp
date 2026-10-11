import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Ctrl-C during a model's turn reaches the request itself (ADR 0049, amended 2026-10-11): a connection still
/// streaming is cancelled, so the turn ends at once rather than at the runtime's idle timeout.
extension OllamaExecutorTests {
    @Test func aStopCancelsAnOllamaRequestThatIsStillStreaming() async throws {
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        // A reply that has begun, and then nothing more: the connection is held open.
        FakeOllama.serve(
            "/api/chat", body: #"{"message":{"role":"assistant","content":"Thinking"},"done":false}"# + "\n",
            then: .hold)
        let config = Config(ollama: .init(baseURL: "http://fake.ollama:1", timeoutSeconds: 30)).resolved
        let sink = MemoryAuditSink()
        let agent = Agent(
            instructions: "x", tools: [], model: try ModelSelection.ollama("q").resolve(config: config),
            audit: AuditLog(session: "s", sink: sink))
        let stop = TurnStop()
        let pressed = Task {
            for _ in 0..<500 where FakeOllama.bodies(for: "/api/chat").isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(100))
            stop.request()
        }
        let started = ContinuousClock.now
        await #expect(throws: TurnStop.Failure.stopped) { try await agent.stream("hi", stop: stop) { _ in } }
        await pressed.value
        // Well before the 30 s the server would have had to stay silent.
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(sink.events.contains { $0.kind == .turnStopped })
        // A turn after it is answered as usual.
        FakeOllama.reset()
        FakeOllama.serve("/api/chat", body: #"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n")
        #expect(try await agent.respond(to: "again").text == "ok")
    }
}

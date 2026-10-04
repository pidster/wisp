import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Ollama stopping in the middle of a turn: the connection lost after some chunks, a stream that ends before
/// Ollama says it is done, and a server that accepts the request and then says nothing. In `OllamaExecutorTests`'
/// suite, which is serialized, because they share `FakeOllama`.
extension OllamaExecutorTests {
    /// The reply chunks a dropped stream sends before the connection goes.
    static let partialReply =
        [
            #"{"message":{"role":"assistant","content":"The answer "},"done":false}"#,
            #"{"message":{"role":"assistant","content":"is PARTIAL"},"done":false}"#,
        ].joined(separator: "\n") + "\n"

    /// A whole reply, for the turn after the interruption.
    static let wholeReply = #"{"message":{"role":"assistant","content":"ok"},"done":true,"prompt_eval_count":9}"# + "\n"

    /// A session on `ollama:q` at the fake server, recording to `sink`, with Ollama's timeout `timeout` seconds.
    static func session(home: Home, sink: MemoryAuditSink, timeout: Int = 5) throws -> Session {
        try home.ensure()
        try Data(
            #"{"model":"ollama:q","ollama":{"baseURL":"http://fake.ollama:1","timeoutSeconds":\#(timeout)}}"#.utf8
        )
        .write(to: home.configFile)
        FakeOllama.serve("/api/tags", body: Self.tags)
        FakeOllama.serve("/api/show", body: Self.shown)
        return try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
    }

    /// A temporary home, removed by the caller.
    static func temporaryHome() -> Home {
        Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-ollama-stop-\(UUID().uuidString)"))
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

    /// The turn after an interruption: Ollama works again, the reply comes back whole, and the request it sent
    /// carries nothing of the interrupted reply.
    static func nextTurnSucceeds(_ agent: Agent, without partial: String) async throws {
        FakeOllama.interruptions.withLock { $0 = [:] }
        FakeOllama.serve("/api/chat", body: Self.wholeReply)
        let reply = try await agent.stream("again") { _ in }
        #expect(reply.text == "ok")
        let last = FakeOllama.bodies(for: "/api/chat").last ?? ""
        #expect(!last.contains(partial), "the interrupted reply was sent back as if it were complete")
        #expect(last.contains("again"))
    }

    @Test func aConnectionLostMidReplyEndsTheTurnWithAnErrorNamingOllamaAndTheThreadGoesOn() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(home: home, sink: sink)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        FakeOllama.serve("/api/chat", body: Self.partialReply, then: .drop)
        let error = await Self.failedTurn(agent, "question")
        #expect(error?.contains("Ollama") == true, "\(error ?? "no error")")
        #expect(error?.contains("stopped before the reply was done") == true, "\(error ?? "no error")")
        // Nothing of it is a reply: no response event, the failure audited against the turn.
        #expect(!sink.events.contains { $0.kind == .response })
        let failure = sink.events.last { $0.kind == .error }
        #expect(failure?.details["context"] == "turn")
        #expect(failure?.details["message"]?.stringValue?.contains("Ollama") == true)
        try await Self.nextTurnSucceeds(agent, without: "PARTIAL")
        #expect(sink.events.filter { $0.kind == .response }.count == 1)
    }

    /// Under a `URLProtocol`, `URLSession.bytes(for:)` hands the body over only once the load ends (probed: a loss
    /// 0.5 s after the chunks failed `bytes(for:)` itself, with nothing streamed), so a loss while the stream is being
    /// read is checked here, on the mapping, rather than over the fake.
    @Test func aConnectionErrorIsNamedForWhenItCame() {
        let configuration = OllamaModel.Executor.Configuration(baseURL: Self.settings.baseURL, timeoutSeconds: 7)
        func failure(_ code: URLError.Code, streaming: Bool) -> OllamaModel.Failure {
            OllamaModel.Executor.failure(URLError(code), configuration: configuration, streaming: streaming)
        }
        #expect(failure(.timedOut, streaming: false) == .timedOut(Self.settings.baseURL, seconds: 7))
        #expect(failure(.timedOut, streaming: true) == .timedOut(Self.settings.baseURL, seconds: 7))
        guard case .unreachable = failure(.cannotConnectToHost, streaming: false) else {
            Issue.record("a refused connection is not an unreachable server")
            return
        }
        for (code, streaming) in [
            (URLError.Code.networkConnectionLost, false), (.networkConnectionLost, true),
            (.cannotConnectToHost, true), (.badServerResponse, true),
        ] {
            guard case .interrupted(let url, _) = failure(code, streaming: streaming) else {
                Issue.record("\(code) while streaming \(streaming) is not an interruption")
                continue
            }
            #expect(url == Self.settings.baseURL)
        }
        #expect(
            "\(OllamaModel.Failure.timedOut(Self.settings.baseURL, seconds: 7))"
                == "Ollama at http://fake.ollama:1 sent nothing for 7 s (ollama.timeoutSeconds); the request was abandoned"
        )
        #expect(
            "\(OllamaModel.Failure.interrupted(Self.settings.baseURL, "lost"))"
                == "Ollama at http://fake.ollama:1 stopped before the reply was done (lost); nothing of it was kept")
    }

    @Test func aStreamThatEndsBeforeOllamaIsDoneIsAnErrorNotAShortReply() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(home: home, sink: sink)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        // The server closes the connection cleanly, but no chunk said `done`.
        FakeOllama.serve("/api/chat", body: Self.partialReply)
        let error = await Self.failedTurn(agent, "question")
        #expect(error?.contains("Ollama") == true, "\(error ?? "no error")")
        #expect(error?.contains("ended before Ollama said it was done") == true, "\(error ?? "no error")")
        #expect(!sink.events.contains { $0.kind == .response })
        try await Self.nextTurnSucceeds(agent, without: "PARTIAL")
    }

    @Test func aToolCallCutShortIsNotRun() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(home: home, sink: sink)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        let call =
            #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"current_date","arguments":{"timeZone":"UTC"}}}]},"done":false}"#
        FakeOllama.serve("/api/chat", body: call + "\n", then: .drop)
        let error = await Self.failedTurn(agent, "what is the date?")
        #expect(error?.contains("Ollama") == true, "\(error ?? "no error")")
        #expect(!sink.events.contains { $0.kind == .toolCall || $0.kind == .toolResult })
        #expect(!sink.events.contains { $0.kind == .response })
        try await Self.nextTurnSucceeds(agent, without: "current_date\",\"arguments")
    }

    @Test func thinkingCutShortEndsTheTurnAndIsNotAReply() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(home: home, sink: sink)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        let thinking =
            [
                #"{"message":{"role":"assistant","content":"","thinking":"Let me think about PARTIAL"},"done":false}"#,
                #"{"message":{"role":"assistant","content":"","thinking":" things"},"done":false}"#,
            ].joined(separator: "\n") + "\n"
        FakeOllama.serve("/api/chat", body: thinking, then: .drop)
        let error = await Self.failedTurn(agent, "question")
        #expect(error?.contains("Ollama") == true, "\(error ?? "no error")")
        #expect(!sink.events.contains { $0.kind == .response })
        #expect(sink.events.last { $0.kind == .error }?.details["context"] == "turn")
        try await Self.nextTurnSucceeds(agent, without: "PARTIAL")
    }

    @Test func aServerThatStopsRespondingTimesOutWithAnErrorNamingOllama() async throws {
        let home = Self.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try Self.session(home: home, sink: sink, timeout: 1)
        let agent = try session.openAgent(approver: DenyingApprover(reason: "x"))
        // Headers, then nothing, with the connection held.
        FakeOllama.serve("/api/chat", body: "", then: .hold)
        let started = ContinuousClock.now
        let error = await Self.failedTurn(agent, "question")
        let waited = ContinuousClock.now - started
        #expect(error?.contains("Ollama") == true, "\(error ?? "no error")")
        #expect(error?.contains("sent nothing for 1 s") == true, "\(error ?? "no error")")
        #expect(waited < .seconds(15), "the turn waited \(waited) on a silent server")
        #expect(!sink.events.contains { $0.kind == .response })
        #expect(sink.events.last { $0.kind == .error }?.details["message"]?.stringValue?.contains("Ollama") == true)
        try await Self.nextTurnSucceeds(agent, without: "PARTIAL")
    }
}

import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct ChatProtocolTests {
    @Test func parsesInboundLinesLeniently() {
        #expect(ChatProtocol.Inbound(line: "hello there") == .message("hello there"))
        #expect(ChatProtocol.Inbound(line: #"{"type":"message","text":"/help"}"#) == .message("/help"))
        #expect(
            ChatProtocol.Inbound(line: #"{"type":"answer","id":"a1","decision":"session"}"#)
                == .answer(id: "a1", decision: "session"))
        #expect(ChatProtocol.Inbound(line: #"{"type":"answer"}"#) == .answer(id: "", decision: "no"))
        #expect(ChatProtocol.Inbound(line: #"{"type":"other"}"#) == .message(""))
        #expect(ChatProtocol.Inbound(line: #"["not","an","object"]"#) == .message(#"["not","an","object"]"#))
    }

    @Test func encodesOutboundLinesWithTheirType() throws {
        let line = ChatProtocol.encode("delta", ["text": "hi"])
        #expect(line == #"{"text":"hi","type":"delta"}"#)
        #expect(ChatProtocol.encode("exit") == #"{"type":"exit"}"#)
        let status = ChatStatus(
            model: "system", directory: "~/x", branch: "main", dirty: true, approval: "--yes", contextUsed: 0.5)
        let encoded = ChatProtocol.encode("status", ChatProtocol.status(status))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)).objectValue
        #expect(decoded?["branch"] == "main" && decoded?["dirty"] == true && decoded?["contextUsed"] == .double(0.5))
        let bare = ChatProtocol.status(ChatStatus(model: "m", directory: "/", approval: "never asks"))
        #expect(bare["branch"] == .null && bare["contextUsed"] == .null)
        let event = AuditEvent(session: "s", kind: .toolCall, turn: 2, call: "c1", details: ["tool": "read_file"])
        let fields = ChatProtocol.event(event)
        #expect(fields["kind"] == "tool.call" && fields["call"] == "c1" && fields["turn"] == 2)
        #expect(fields["details"]?.objectValue?["tool"] == "read_file")
        #expect(fields["text"] == "⚙ read_file ")
        let unshown = ChatProtocol.event(AuditEvent(session: "s", kind: .prompt, turn: 2, details: [:]))
        #expect(unshown["text"] == .null)
        #expect(ChatProtocol.turn(.start(turn: 3)) == ["phase": "start", "turn": 3])
        #expect(
            ChatProtocol.turn(.end(turn: 3, seconds: 1.5, failed: false))
                == ["phase": "end", "turn": 3, "seconds": .double(1.5), "outcome": "ok"])
        #expect(ChatProtocol.turn(.end(turn: 4, seconds: 0, failed: true))["outcome"] == "error")
        let request = ApprovalRequest(
            command: "git push", line: "git add && git push", pattern: "git push *", workingDirectory: "/r",
            assessment: RiskAssessment(level: .dangerous, reasons: ["changes repository state"], sources: ["rules"]))
        let approval = ChatProtocol.approval(id: "a9", request)
        #expect(approval["id"] == "a9" && approval["level"] == "dangerous" && approval["pattern"] == "git push *")
        #expect(approval["reasons"] == ["changes repository state"])
    }

    @Test func routerQueuesMessagesAndMatchesAnswersInEitherOrder() async {
        let router = LineRouter()
        router.receive("first")
        router.receive(#"{"type":"answer","id":"early","decision":"always"}"#)
        #expect(router.nextMessage() == "first")
        // An answer that arrived before anyone waited is kept.
        #expect(await router.answer(for: "early") == "always")
        // A waiter is resumed when its answer arrives.
        let waited = Task { await router.answer(for: "late") }
        try? await Task.sleep(for: .milliseconds(20))
        router.receive(#"{"type":"answer","id":"late","decision":"no"}"#)
        #expect(await waited.value == "no")
        // Closing drains the queue then reports end of input.
        router.receive("last")
        router.close()
        #expect(router.nextMessage() == "last")
        #expect(router.nextMessage() == nil)
    }

    @Test func aChoiceIsAskedThroughTheProtocolAndAnsweredByID() async throws {
        let router = LineRouter()
        let lines = Mutex<[String]>([])
        let choice = ChatChoice(title: "pick", options: [.init(value: "a", detail: "first")], current: "a")
        let send: @Sendable (String) -> Void = { line in
            lines.withLock { $0.append(line) }
            let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue?["id"]?.stringValue
            router.receive(#"{"type":"choose","id":"\#(id ?? "")","value":"a"}"#)
        }
        #expect(await ChatProtocol.ask(choice, router: router, timeout: .seconds(5), send: send) == "a")
        let sent = try #require(lines.withLock { $0.first })
        let fields = try JSONDecoder().decode(JSONValue.self, from: Data(sent.utf8)).objectValue
        #expect(fields?["type"] == "choice" && fields?["title"] == "pick" && fields?["current"] == "a")
        #expect(fields?["options"]?.arrayValue?.first?.objectValue?["detail"] == "first")
        // An empty value, or no answer in time, is no answer.
        let empty: @Sendable (String) -> Void = { line in
            let id = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue?["id"]?.stringValue
            router.receive(#"{"type":"choose","id":"\#(id ?? "")"}"#)
        }
        #expect(await ChatProtocol.ask(choice, router: router, timeout: .seconds(5), send: empty) == nil)
        #expect(await ChatProtocol.ask(choice, router: router, timeout: .milliseconds(20), send: { _ in }) == nil)
    }

    @Test func approverAsksThroughTheProtocolAndHonoursTheTimeout() async {
        let router = LineRouter()
        let sent = Mutex<[String]>([])
        let approver = JSONApprover(router: router, timeout: .seconds(5)) { line in sent.withLock { $0.append(line) } }
        let request = ApprovalRequest(
            command: "ls", line: "ls", pattern: "ls *", workingDirectory: "/",
            assessment: RiskAssessment(level: .moderate, reasons: [], sources: []))
        let deciding = Task { await approver.decide(request) }
        while sent.withLock({ $0.isEmpty }) { try? await Task.sleep(for: .milliseconds(5)) }
        let line = sent.withLock { $0[0] }
        #expect(line.contains(#""type":"approval""#) && line.contains(#""command":"ls""#))
        let id =
            (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))?.objectValue?["id"]?.stringValue ?? ""
        router.receive(ChatProtocol.encode("answer", ["id": .string(id), "decision": "project"]))
        #expect(await deciding.value == .approved(.project))
        let silent = JSONApprover(router: router, timeout: .milliseconds(50)) { _ in }
        #expect(await silent.decide(request) == .unanswered(.milliseconds(50)))
    }

    @Test func theLoopSpeaksTheProtocolEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = LineRouter()
        let lines = Mutex<[String]>([])
        let send: @Sendable (String) -> Void = { line in lines.withLock { $0.append(line) } }
        let tap = ChatEvents.Tap()
        let audit = AuditLog(session: "j", sink: tap)
        let agent = Agent(
            instructions: "x", tools: [AuditedTool(CurrentDateTool(), audit: audit)],
            model: ResolvedModel(selection: .system, custom: ScriptedModel()), audit: audit)
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, tap: tap,
            context: .init(directory: "/r", approval: "--yes", banner: "wisp test"),
            io: .init(
                readLine: { router.nextMessage() },
                print: { send(ChatProtocol.encode("output", ["text": .string($0)])) },
                write: { send(ChatProtocol.encode("delta", ["text": .string($0)])) },
                note: { send(ChatProtocol.encode("note", ["text": .string($0)])) },
                prompt: { send(ChatProtocol.encode("status", ChatProtocol.status($0))) },
                turn: { send(ChatProtocol.encode("turn", ChatProtocol.turn($0))) }))
        tap.onEvent { event in send(ChatProtocol.encode("event", ChatProtocol.event(event))) }
        router.receive(#"{"type":"message","text":"date?"}"#)
        router.receive("/quit")
        try await loop.run()
        let types = lines.withLock { $0 }.compactMap {
            (try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)))?.objectValue?["type"]?.stringValue
        }
        #expect(types.first == "note")  // the banner
        #expect(types.contains("status") && types.contains("delta") && types.contains("event"))
        let events = lines.withLock { $0 }.filter { $0.contains(#""type":"event""#) }
        #expect(events.contains { $0.contains(#""kind":"tool.call""#) })
        #expect(events.contains { $0.contains(#""kind":"tool.result""#) })
        #expect(events.contains { $0.contains(#""text":"⚙ current_date"#) })
        // The turn's edges bracket its reply and events, numbered as the events are.
        let turns = lines.withLock { $0 }.enumerated().filter { $0.element.contains(#""type":"turn""#) }
        #expect(turns.count == 2)
        #expect(turns.first?.element.contains(#""phase":"start","turn":1"#) == true)
        #expect(
            turns.last.map { $0.element.contains(#""outcome":"ok""#) && $0.element.contains(#""phase":"end""#) } == true
        )
        let deltas = lines.withLock { $0 }.enumerated().filter { $0.element.contains(#""type":"delta""#) }
        #expect(deltas.allSatisfy { $0.offset > turns[0].offset && $0.offset < turns[1].offset })
        #expect(events.allSatisfy { $0.contains(#""turn":1"#) })
        #expect(lines.withLock { $0 }.last?.contains(#""type":"output""#) == true || types.last == "status")
    }
}

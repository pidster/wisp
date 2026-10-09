import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// `hello` and `notify` on the `wisp chat --json` protocol (ADR 0044), and the model's `notify` reaching the
/// front end through the session's host.
@Suite struct ChatHelloTests {
    private let request = ApprovalRequest(
        command: "ls", line: "ls", pattern: "ls *", workingDirectory: "/",
        assessment: RiskAssessment(level: .moderate, reasons: [], sources: []))

    @Test func helloIsParsedAndRecorded() {
        #expect(
            ChatProtocol.Inbound(
                line: #"{"type":"hello","effects":["approve","notify"],"client":"wisp-tui","version":"1"}"#)
                == .hello(.init(effects: ["approve", "notify"], client: "wisp-tui", version: "1")))
        #expect(ChatProtocol.Inbound(line: #"{"type":"hello"}"#) == .hello(.init(effects: [])))
        let router = LineRouter()
        let heard = Mutex<[ChatProtocol.Hello]>([])
        router.onHello { hello in heard.withLock { $0.append(hello) } }
        #expect(router.hello == nil && !router.declares("notify"))
        router.receive(#"{"type":"hello","effects":["approve","notify","future"]}"#)
        #expect(router.declares("notify") && router.declares("approve") && !router.declares("show"))
        #expect(heard.withLock { $0 }.map(\.effects) == [["approve", "notify", "future"]])
        // A hello is not a message.
        router.close()
        #expect(router.nextMessage() == nil)
        let details = AuditEvent.Details.hostHello(.init(effects: ["approve"], client: "wisp-tui", version: "0.15.0"))
        #expect(details == ["effects": .array(["approve"]), "client": "wisp-tui", "version": "0.15.0"])
        #expect(Set(details.keys) == AuditEvent.fields(for: .hostHello))
        #expect(AuditEvent.Kind(rawValue: "host.hello") == .hostHello)
    }

    @Test func theNotifyLineCarriesTheBoundedMessage() throws {
        let line = ChatProtocol.encode(
            "notify", ChatProtocol.notify(.init(title: "Build", body: "done", subtitle: nil, sound: true)))
        #expect(line == #"{"body":"done","sound":true,"subtitle":null,"title":"Build","type":"notify"}"#)
        let sent = Mutex<[String]>([])
        let router = LineRouter()
        let routes = NotificationRoutes(
            face: .frontEnd(
                .init(
                    declared: { router.declares("notify") },
                    send: { message in
                        sent.withLock { $0.append(ChatProtocol.encode("notify", ChatProtocol.notify(message))) }
                    })),
            environment: ["TERM_PROGRAM": "ghostty"],
            writeTerminal: { _ in
                Issue.record("wrote to the terminal"); return nil
            })
        let recorded = Mutex(0)
        let notifier = Notifier(run: { _ in
            recorded.withLock { $0 += 1 }; return 0
        })
        // No hello yet: posted by wisp's process, as before.
        #expect(
            notifier.post(.init(title: "a\nb", body: "one"), source: .model, audit: nil, routes: routes)
                == .posted(.osascript))
        router.receive(#"{"type":"hello","effects":["approve","notify"]}"#)
        #expect(
            notifier.post(.init(title: "a\nb", body: "two"), source: .model, audit: nil, routes: routes)
                == .posted(.host))
        #expect(
            sent.withLock { $0 } == [#"{"body":"two","sound":false,"subtitle":null,"title":"a b","type":"notify"}"#])
        #expect(recorded.withLock { $0 } == 1)
    }

    @Test func aHelloWithoutApproveDeniesWithoutAsking() async {
        let router = LineRouter()
        let sent = Mutex<[String]>([])
        let approver = JSONApprover(router: router, timeout: .milliseconds(50)) { line in
            sent.withLock { $0.append(line) }
        }
        router.receive(#"{"type":"hello","effects":["notify"]}"#)
        #expect(await approver.decide(request) == .denied("the front end declared no approve effect in its hello"))
        #expect(sent.withLock { $0.isEmpty })
        // Declaring approve asks as before.
        router.receive(#"{"type":"hello","effects":["approve"]}"#)
        #expect(await approver.decide(request) == .unanswered(.milliseconds(50)))
        // The approval, and its withdrawal once the wait lapsed.
        #expect(sent.withLock { $0.count } == 2)
    }

    @Test func theModelsNotifyReachesTheFrontEndThroughTheHost() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-hello-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .chat), home: home, dependencies: .testing(sink: sink))
        let sent = Mutex<[Notifier.Message]>([])
        let host = session.host(
            approver: DenyingApprover(reason: "x"),
            face: .frontEnd(.init(declared: { true }, send: { message in sent.withLock { $0.append(message) } })))
        let thread = try session.thread(id: "n", host: host, tools: ToolSelection(["notify"]))
        let agent = try thread.openAgent(
            on: ResolvedModel(
                selection: .system,
                custom: ScriptedModel(steps: [
                    .call(name: "notify", arguments: #"{"title":"Done","message":"Tests pass."}"#), .say("{tool}"),
                ])))
        let reply = try await agent.respond(to: "tell me when done")
        #expect(reply.text.contains("notification posted via host"))
        #expect(sent.withLock { $0 } == [.init(title: "Done", body: "Tests pass.")])
        let event = try #require(sink.events.first { $0.kind == .notification })
        #expect(event.details["route"] == "host" && event.details["source"] == "model")
    }
}

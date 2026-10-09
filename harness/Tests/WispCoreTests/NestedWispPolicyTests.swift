import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The model cannot start a wisp of its own (ADR 0054): `wisp respond`, `chat`, `mcp`, and the bare prompt form are
/// denied by the default policy, by any path and with options before them, while wisp's other subcommands stay
/// allowed. The person's typed `!` commands follow the same lists.
@Suite struct NestedWispPolicyTests {
    @Test func everyFormThatStartsAnAgentIsDenied() {
        let policy = CommandPolicy()
        for line in [
            "wisp respond \"Execute the self-test script functionality-self-test.wisp.\"",
            "wisp respond --yes 'hi'", "wisp chat", "wisp chat --plain", "wisp chat --json", "wisp mcp",
            "wisp \"Execute the self-test script\"", "wisp 'hi'", "wisp --yes \"hi\"",
            "wisp -m system \"hi\"", "wisp --model ollama:granite4.1:8b respond x", "  wisp mcp",
            "/usr/local/bin/wisp respond x", "harness/.build/debug/wisp respond x", "./wisp chat",
            "harness/.build/release/wisp mcp", "env WISP_HOME=/tmp/x wisp respond x", "WISP_LOG=debug wisp 'x'",
            "exec wisp mcp", "nohup wisp respond x",
        ] {
            #expect(policy.check(line) != .allowed, "\(line)")
        }
    }

    /// Wrappers, keywords, other whitespace, and a quoted program name do not hide a nested wisp or the person's
    /// own answers (the 2026-10-09 review). Checked against the policy only; nothing runs.
    @Test func wrappersQuotesAndKeywordsDoNotHideIt() {
        let policy = CommandPolicy()
        for line in [
            "nice wisp chat", "nice -n 10 wisp respond x", "time wisp mcp", "command wisp chat", "builtin wisp chat",
            "timeout 5 wisp chat", "timeout 5s wisp mcp", "caffeinate -i wisp chat", "env -i wisp mcp",
            "env -i PATH=/usr/bin wisp mcp", "nohup nice wisp mcp", "{ wisp chat", "then wisp chat", "do wisp mcp",
            "xargs wisp respond", "\"wisp\" chat", "'wisp' respond x", "wisp\tchat", "wisp  \t mcp",
            "\"/opt/homebrew/bin/wisp\" mcp", "wisp \"chat\"",
            "\"wisp\" approvals approve abc", "wisp 'approvals' approve abc", "wisp\tapprovals\tdeny abc",
            "'wisp' facts keep c1", "\\wisp approvals approve abc", "{ wisp facts drop c1",
        ] {
            #expect(policy.check(line) != .allowed, "\(line)")
        }
        // Each segment of a compound line is checked alone, as `CommandRunner` does.
        let compound = "if true; then wisp chat; fi"
        #expect(CommandSplitter.split(compound).map(\.text).contains { policy.check($0) != .allowed })
        for line in ["\"wisp\" approvals pending", "nice wisp doctor", "time wisp --version", "echo 'wisp' chat"] {
            #expect(policy.check(line) == .allowed, "\(line)")
        }
    }

    @Test func wispsOtherSubcommandsAndMentionsOfItStayAllowed() {
        let policy = CommandPolicy()
        for line in [
            "wisp --version", "wisp --help", "wisp help", "wisp doctor", "wisp logs --last 20", "wisp logs --json",
            "wisp tools", "wisp tools --markdown", "wisp models", "wisp config", "wisp config get model",
            "wisp approvals pending", "wisp facts", "harness/.build/debug/wisp doctor", "wisp", "wisp-tui --version",
            "wisp config set systemPromptExtension \"be brief\"", "grep wisp README.md", "echo \"wisp chat\"",
            "ls ~/.wisp", "cat docs/wisp.md", "git log -- wisp",
        ] {
            #expect(policy.check(line) == .allowed, "\(line)")
        }
    }

    @Test func aNestedWispInsideALineIsCaughtByItsSegment() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let runner = CommandRunner(options: .init(writableRoot: dir.path), audit: AuditLog(session: "s", sink: sink))
        for line in ["cd /tmp && wisp respond hi", "true; wisp chat", "echo $(wisp 'hi')", "ls | wisp mcp"] {
            await #expect(throws: CommandRunner.Failure.self, "\(line)") {
                _ = try await runner.run(line, in: dir.path)
            }
        }
        // Nothing ran: every one was refused before launch, and audited as denied.
        #expect(!sink.events.contains { $0.kind == .commandOutcome })
        #expect(sink.events.filter { $0.kind == .policyDecision }.allSatisfy { $0.details["verdict"] == "denied" })
        // The person's typed command is held to the same list.
        await #expect(throws: CommandRunner.Failure.self) {
            _ = try await runner.run("wisp respond hi", in: dir.path, origin: .person)
        }
        // A subcommand that starts no agent runs as before (here, a stand-in on PATH-free ground: echo).
        #expect(try await runner.run("echo wisp respond", in: dir.path).exitStatus == 0)
    }

    @Test func theConfigurationViewTurnsCompactRatherThanLoseItsLastKeys() {
        let small: JSONValue = ["a": 1, "version": "x"]
        #expect(InspectTool.fitted(small) == Introspection.render(small))
        let large: JSONValue = .object(["deny": .array((1...400).map { .string("pattern \($0)") }), "version": "x"])
        let fitted = InspectTool.fitted(large)
        #expect(!fitted.contains("\n") && fitted.hasSuffix(#""version":"x"}"#))
    }
}

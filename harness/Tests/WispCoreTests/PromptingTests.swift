import Foundation
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct PromptingTests {
    @Test func rendersTheLayersInOrderUnderHeadings() {
        let all = Prompting(systemPromptExtension: " Prefer British spelling. ", instructions: "Answer in French.")
        let expected =
            Prompting.systemPrompt(memory: false)
            + "\n\nGuidance for this Mac:\nPrefer British spelling.\n\nInstructions for this conversation:\nAnswer in French."
        #expect(all.rendered == expected)
    }

    @Test func aConversationWithoutToolsIsToldSo() {
        let text = Prompting(instructions: "x").rendered(toolsAvailable: false)
        #expect(text.contains("This conversation has no tools"))
        #expect(text.hasSuffix("Instructions for this conversation:\nx"))
        #expect(!Prompting().rendered.contains("no tools"))
    }

    @Test func emptyLayersAreOmittedAndTheSystemPromptCannotBe() {
        let base = Prompting.systemPrompt(memory: false)
        #expect(Prompting().rendered == base)
        #expect(Prompting(systemPromptExtension: "  \n", instructions: "").rendered == base)
        #expect(Prompting(instructions: "x").rendered == base + "\n\nInstructions for this conversation:\nx")
        #expect(Prompting.systemPrompt.contains("Wisp"))
        #expect(Prompting.systemPrompt.utf8.count < 900, "keep layer 1 small for an 8k window")
    }

    /// The sandbox note (ADR 0076) says where commands may write, whether the network is on, and what a refusal looks
    /// like, from the runner's settings; or that there is no sandbox, or another one decides.
    @Test func theSandboxNoteSaysWhatTheSettingsAre() {
        func note(enabled: Bool = true, nested: Bool = false, network: Bool = true, outside: Bool = true) -> String {
            CommandRunner.sandboxNote(
                enabled: enabled, nested: nested, root: "/Users/me/src/wisp", writablePaths: ["~/Library/Caches"],
                network: network, outside: outside, home: "/Users/me")
        }
        #expect(
            note() == "Commands run in a sandbox: they can read any file, but write only under ~/src/wisp, the "
                + "temporary folder, and ~/Library/Caches; the network is on. A write elsewhere fails with "
                + "\"Operation not permitted\": say so, or ask to run it with outsideSandbox, which the person approves."
        )
        #expect(note(network: false).contains("the network is off."))
        #expect(note(outside: false).hasSuffix("\"Operation not permitted\": say so."))
        #expect(note(enabled: false) == "Commands run without a sandbox: they can change anything this account can.")
        #expect(note(nested: true).hasPrefix("Commands run inside the sandbox wisp itself was started in"))
        #expect(note().utf8.count < 300, "keep the note small for an 8k window")
        // It follows wisp's own prompt, and only in a conversation with tools.
        let rendered = Prompting(instructions: "x").rendered(toolsAvailable: true, sandbox: note())
        #expect(rendered.hasPrefix(Prompting.systemPrompt(memory: false) + "\n" + note() + "\n\nInstructions"))
        #expect(!Prompting().rendered(toolsAvailable: false, sandbox: note()).contains("sandbox"))
    }

    /// A thread with `run_command` is told its runner's sandbox; one without it is not.
    @Test func aThreadWithRunCommandIsToldTheSandbox() async throws {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-sandbox-\(UUID().uuidString)"))
        try home.ensure()
        defer { try? FileManager.default.removeItem(at: home.root) }
        func instructions(_ tools: ToolSelection) async throws -> String {
            let session = try Session.begin(
                .init(entryPoint: .chat, tools: tools), home: home, dependencies: .testing())
            defer { session.end() }
            let thread = try session.thread(id: "t", approver: DenyingApprover(reason: "not in tests"))
            let model = ScriptedModel(steps: [.say("hi")])
            let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
            _ = try await agent.respond(to: "hello")
            let request = try #require(model.script.requests.withLock { $0 }.last)
            return AssessmentTests.instructions(request.transcript)
        }
        let withRun = try await instructions(ToolSelection(["run_command"]))
        #expect(withRun.contains("Commands run "), "\(withRun)")
        #expect(try await !instructions(ToolSelection(["current_date"])).contains("Commands run "))
    }

    /// The embedded text is the resource file, so editing the file is editing the prompt.
    @Test func systemPromptIsTheResourceFile() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WispCore/Resources/system-prompt.md")
        let onDisk = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Prompting.systemPrompt == onDisk)
    }
}

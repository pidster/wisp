import Testing

@testable import WispCore

@Suite struct ChatInputTests {
    @Test func parsesModelCommands() {
        #expect(ChatInput(line: "/models") == .models)
        #expect(ChatInput(line: "/model") == .model(nil))
        #expect(ChatInput(line: "/model ollama:qwen3-coder") == .model("ollama:qwen3-coder"))
        #expect(ChatInput.helpText.contains("/models") && ChatInput.helpText.contains("/model [name]"))
    }

    @Test func parsesAuditWithASessionOrTheSessionList() {
        #expect(ChatInput(line: "/audit") == .inspect("audit"))
        #expect(ChatInput(line: "/audit sessions") == .inspect("audit sessions"))
        #expect(ChatInput(line: "/audit  git ") == .inspect("audit git"))
        #expect(
            ChatCompletion.complete("/audit s", sessionIDs: ["scan-1", "git"]).candidates == ["scan-1", "sessions"])
        #expect(ChatCompletion.complete("/audit ", sessionIDs: ["git"]).candidates == ["git", "sessions"])
    }

    @Test func parsesStatsAndHistory() {
        #expect(ChatInput(line: "/stats") == .stats)
        #expect(ChatInput(line: " /history ") == .history)
        #expect(ChatInput.helpText.contains("/stats") && ChatInput.helpText.contains("/history"))
    }

    @Test func parsesCommandsAndMessages() {
        #expect(ChatInput(line: "/quit") == .quit)
        #expect(ChatInput(line: " /exit ") == .quit)
        #expect(ChatInput(line: "exit") == .quit)
        #expect(ChatInput(line: " Quit ") == .quit)
        #expect(ChatInput(line: "q") == .quit)
        #expect(ChatInput(line: "exit now") == .message("exit now"))
        #expect(ChatInput(line: "/help") == .help)
        #expect(ChatInput(line: "/?") == .help)
        #expect(ChatInput(line: "/tools") == .tools)
        #expect(ChatInput(line: "/tokens") == .tokens)
        #expect(ChatInput(line: "/new") == .new)
        #expect(ChatInput(line: "/save") == .save(nil))
        #expect(ChatInput(line: "/save  my-chat ") == .save("my-chat"))
        #expect(ChatInput(line: "/frobnicate now") == .unknown("frobnicate"))
        #expect(ChatInput(line: "  hello there ") == .message("hello there"))
        #expect(ChatInput(line: "") == .message(""))
    }
}

import Foundation
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct ChatInputTests {
    @Test func parsesModelCommands() {
        #expect(ChatInput(line: "/models") == .models(.list))
        #expect(ChatInput(line: "/models list") == .models(.list))
        #expect(ChatInput(line: "/models enable ollama:a  mlx:b") == .models(.enable(["ollama:a", "mlx:b"])))
        #expect(ChatInput(line: "/models disable private-cloud") == .models(.disable(["private-cloud"])))
        #expect(ChatInput(line: "/models disable") == .models(.unknown("disable")))
        #expect(ChatInput(line: "/models frob") == .models(.unknown("frob")))
        #expect(ChatInput.helpText.contains("/models enable|disable NAME…"))
        #expect(ChatInput(line: "/models check mlx:b") == .models(.check(["mlx:b"])))
        #expect(ChatInput(line: "/models check") == .models(.unknown("check")))
        #expect(ChatInput.helpText.contains("/models check NAME…"))
        #expect(ChatCompletion.complete("/models ").candidates == ["check", "disable", "enable"])
        #expect(
            ChatCompletion.complete("/models check ", options: { _ in ["mlx:b"] }).candidates == ["mlx:b"])
        #expect(
            ChatCompletion.complete("/models enable o", disabledModels: ["ollama:a", "mlx:b"]).candidates == [
                "ollama:a"
            ])
        #expect(
            ChatCompletion.complete("/models disable ", options: { _ in ["system", "ollama:a"] }).candidates == [
                "ollama:a", "system",
            ])
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

    @Test func everyCommandTheParserAcceptsIsInTheHelpAndCompletion() {
        let listed = Set(ChatInput.helpEntries.flatMap(\.names))
        // Every listed word parses as a command, and its usage is in the text.
        for entry in ChatInput.helpEntries {
            #expect(ChatInput.helpText.contains(entry.usage), "\(entry.usage)")
            for name in entry.names {
                #expect(ChatInput(line: "/\(name)") != .unknown(name), "/\(name)")
            }
        }
        // Every word completion offers is listed, and every listed word longer than one character completes, so
        // a command added to one is in the other.
        for command in ChatCompletion.commands {
            #expect(listed.contains(String(command.dropFirst())), "\(command)")
        }
        for name in listed where name.count > 1 {
            #expect(ChatCompletion.commands.contains("/" + name), "/\(name)")
        }
        // The forms under /inspect, and the aliases, are listed too.
        for view in ChatCompletion.views {
            #expect(ChatInput(line: "/inspect \(view)") != .unknown("inspect"), "\(view)")
            #expect(ChatInput.helpText.contains(view), "\(view)")
        }
        for alias in ["/?", "/q", "/exit", "help", "?", "exit", "quit"] {
            let parsed = ChatInput(line: alias)
            #expect(parsed == .help || parsed == .quit, "\(alias)")
        }
        #expect(
            ChatInput.helpText.contains("a bare help or ?") && ChatInput.helpText.contains("a bare exit, quit, or q"))
    }

    @Test func theHelpsTableIsTheParser() {
        // Every command word in the table parses to a command, with and without an argument.
        let words = ChatInput.helpEntries.flatMap(\.names)
        #expect(!words.isEmpty && Set(words).count == words.count, "a word is listed twice")
        for entry in ChatInput.helpEntries {
            // A line has parser words exactly when it names a command.
            #expect(entry.names.isEmpty == (entry.command == nil), "\(entry.usage)")
            for name in entry.names {
                #expect(ChatInput(line: "/\(name)") != .unknown(name), "/\(name)")
                #expect(ChatInput(line: "/\(name) x") != .unknown(name), "/\(name) x")
            }
        }
        // A word that is not in the table is not a command, whatever it is spelled like.
        for word in ["nope", "Help", "inspectx", "fac"] {
            #expect(ChatInput(line: "/\(word)") == .unknown(word), "/\(word)")
            #expect(ChatInput(line: "/\(word) with an argument") == .unknown(word), "/\(word)")
        }
        #expect(ChatInput(line: "/") == .unknown(""))
        // What a word produces comes from its entry: aliases share one, and arguments reach the closure.
        #expect(ChatInput(line: "/q") == .quit && ChatInput(line: "/exit") == .quit && ChatInput(line: "/?") == .help)
        #expect(ChatInput(line: "/save  notes ") == .save("notes") && ChatInput(line: "/save") == .save(nil))
        #expect(ChatInput(line: "/inspect") == .inspect("status") && ChatInput(line: "/status") == .inspect("status"))
        #expect(ChatInput(line: "/inspect Context") == .context)
        #expect(ChatInput(line: "/inspect context  next ") == .view("next"))
        #expect(ChatInput(line: "/inspect facts all") == .facts(all: true))
        #expect(ChatInput(line: "/inspect facts") == .facts(all: false))
        #expect(ChatInput(line: "/inspect config") == .inspect("config"))
        #expect(ChatInput(line: "/audit git") == .inspect("audit git") && ChatInput(line: "/last") == .last)
        #expect(ChatInput(line: "/show 4") == .show("4") && ChatInput(line: "/task do it") == .task("do it"))
        #expect(ChatInput(line: "/config set a b") == .config(.set(path: "a", value: "b")))
        #expect(ChatInput(line: "/approvals revoke 3") == .approvals(.revoke("3")))
    }

    @Test func helpIsAColumnWithLongUsagesOverTheirDescription() {
        let lines = ChatInput.helpText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let column = 28
        for entry in ChatInput.helpEntries {
            let at = lines.firstIndex { $0.hasPrefix(entry.usage) }
            #expect(at != nil, "\(entry.usage)")
            guard let at else { continue }
            if entry.usage.count < column {
                #expect(lines[at] == entry.usage.padding(toLength: column, withPad: " ", startingAt: 0) + entry.about)
            } else {
                #expect(
                    lines[at] == entry.usage && lines[at + 1] == String(repeating: " ", count: column) + entry.about)
            }
        }
        #expect(!ChatInput.helpText.contains("wisp-tui"))
        #expect(
            ChatInput.helpText(frontEnd: true).contains("Ctrl-O")
                && ChatInput.helpText(frontEnd: true).contains("Ctrl-T"))
        #expect(ChatInput.helpText(frontEnd: true).hasPrefix(ChatInput.helpText))
    }

    @Test func theFrontEndsKeysAreListedOnlyUnderAFrontEnd() async throws {
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])))
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = ChatLoopTests.Capture(lines: ["/help", "/quit"])
        var plainLoop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context,
            io: plain.io)
        try await plainLoop.run()
        #expect(plain.output.contains(ChatInput.helpText) && !plain.output.contains("In wisp-tui:"))
        let front = ChatLoopTests.Capture(lines: ["/help", "/quit"])
        var io = front.io
        io.view = { _ in }
        var frontLoop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir), saveName: nil, context: ChatLoopTests.context, io: io)
        try await frontLoop.run()
        #expect(front.output.contains(ChatInput.helpText(frontEnd: true)))
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

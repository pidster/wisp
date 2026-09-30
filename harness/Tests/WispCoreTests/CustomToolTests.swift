import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

@Suite struct CustomToolTests {
    typealias Definition = CustomTool.Definition
    typealias Argument = CustomTool.Argument

    static let count = Definition(
        name: "word_count", description: "Counts the words in a file.",
        arguments: ["path": Argument(type: "string", description: "The file")], command: "wc -w {path}")

    static func invalid(_ definition: Definition) -> String? {
        do {
            try CustomTool.validate(definition)
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func definitionsAreCheckedAgainstTheRules() {
        #expect(Self.invalid(Self.count) == nil)
        var bad = Self.count
        bad.name = "WordCount"
        #expect(Self.invalid(bad)?.contains("snake_case") == true)
        bad = Self.count
        bad.description = " "
        #expect(Self.invalid(bad)?.contains("description") == true)
        bad = Self.count
        bad.command = "wc -w {file}"
        #expect(Self.invalid(bad)?.contains("{file}, which is not a declared argument") == true)
        bad = Self.count
        bad.command = "wc -w README.md"
        #expect(Self.invalid(bad)?.contains("'path' is not used") == true)
        bad = Self.count
        bad.arguments = ["path": Argument(type: "file")]
        #expect(Self.invalid(bad)?.contains("type 'file'") == true)
        bad.arguments = ["path": Argument(type: "integer", enum: ["a"])]
        #expect(Self.invalid(bad)?.contains("enum") == true)
        bad.arguments = ["path": Argument(type: "integer", default: "five")]
        #expect(Self.invalid(bad)?.contains("default") == true)
        bad = Self.count
        bad.command = "  "
        #expect(Self.invalid(bad)?.contains("the command is empty") == true)
        bad = Self.count
        bad.arguments = ["Path": Argument(type: "string")]
        bad.command = "wc -w {Path}"
        #expect(Self.invalid(bad) != nil)
        bad = Self.count
        bad.timeoutSeconds = 0
        #expect(Self.invalid(bad)?.contains("timeoutSeconds") == true)
        // Names are unique among the built-ins and each other.
        #expect(throws: CustomTool.Failure.self) {
            try CustomTool.validate([Self.count, Self.count], reserved: [])
        }
        var builtIn = Self.count
        builtIn.name = "run_command"
        #expect(throws: CustomTool.Failure.invalid(tool: "run_command", reason: "is a built-in tool's name")) {
            try CustomTool.validate([builtIn], reserved: Set(ToolRegistry.builtInNames))
        }
    }

    @Test func valuesAreRenderedForTheShellAndDefaultsFillIn() throws {
        let text = Argument(type: "string")
        #expect(CustomTool.render("it's here; rm -rf ~", as: text) == #"'it'\''s here; rm -rf ~'"#)
        #expect(CustomTool.render(.int(3), as: text) == nil)
        #expect(CustomTool.render(.int(3), as: Argument(type: "integer")) == "3")
        #expect(CustomTool.render(.double(4), as: Argument(type: "integer")) == "4")
        #expect(CustomTool.render(.double(4.5), as: Argument(type: "integer")) == nil)
        #expect(CustomTool.render(.double(2.5), as: Argument(type: "number")) == "2.5")
        #expect(CustomTool.render(.bool(true), as: Argument(type: "boolean")) == "true")
        let mode = Argument(type: "string", enum: ["fast", "full"])
        #expect(CustomTool.render("fast", as: mode) == "'fast'" && CustomTool.render("other", as: mode) == nil)
        let head = Definition(
            name: "line_head", description: "First lines.",
            arguments: ["path": Argument(type: "string"), "lines": Argument(type: "integer", default: 5)],
            command: "head -n {lines} {path}")
        #expect(try CustomTool.commandLine(head, values: ["path": "a b.txt"]) == "head -n 5 'a b.txt'")
        #expect(try CustomTool.commandLine(head, values: ["path": "x", "lines": 2]) == "head -n 2 'x'")
        #expect(throws: CustomTool.Failure.self) { try CustomTool.commandLine(head, values: [:]) }
        #expect(throws: CustomTool.Failure.self) { try CustomTool.commandLine(head, values: ["path": .int(1)]) }
        #expect(CustomTool.placeholders(in: "a {x} {y_2} {Z} {x}") == ["x", "y_2", "x"])
    }

    @Test func theToolDescribesItselfAndBuildsItsSchema() throws {
        let tool = try CustomTool(Self.count, runner: CommandRunner())
        #expect(tool.name == "word_count" && tool.description == "Counts the words in a file.")
        #expect(tool.examplePrompt == "Use word_count with path <string>.")
        #expect(tool.limits.hasPrefix("Runs `wc -w {path}` under run_command's policy"))
        #expect("\(tool.parameters)".contains("path"))
        let bare = try CustomTool(
            Definition(name: "uptime_now", description: "Uptime.", command: "uptime"), runner: CommandRunner())
        #expect(bare.examplePrompt == "Use uptime_now.")
        #expect(throws: CustomTool.Failure.self) {
            try CustomTool(Definition(name: "x", description: "", command: "true"), runner: CommandRunner())
        }
    }

    @Test func aCallRunsTheSubstitutedLineThroughTheRunner() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-custom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("one two three\n".utf8).write(to: dir.appending(path: "note's.txt"))
        var definition = Self.count
        definition.workingDirectory = dir.path
        let sink = MemoryAuditSink()
        let runner = CommandRunner(options: .init(writableRoot: dir.path), audit: AuditLog(session: "t", sink: sink))
        let tool = try CustomTool(definition, runner: runner)
        let output = await tool.call(arguments: GeneratedContent(properties: ["path": "note's.txt"]))
        #expect(output.hasPrefix("exit status: 0") && output.contains("3 note's.txt"), "\(output)")
        #expect(
            sink.events.contains { $0.kind == .commandOutcome && $0.details["command"] == #"wc -w 'note'\''s.txt'"# })
        let missing = await tool.call(arguments: GeneratedContent(properties: [:]))
        #expect(missing.hasPrefix("error: custom tool 'word_count': the argument 'path' is required"))
    }

    @Test func theRegistryDropsDisabledBuiltInsAndAppendsCustomTools() {
        #expect(ToolRegistry().all.map(\.name) == ToolRegistry.builtInNames)
        let registry = ToolRegistry(disabled: ["notify", "system_info"], custom: [Self.count])
        #expect(
            registry.all.map(\.name) == [
                "current_date", "run_command", "read_file", "edit_file", "inspect", "memory", "word_count",
            ])
        #expect(registry.descriptions.contains { $0.name == "word_count" })
    }

    @Test func theConfigValidatesItsToolsSection() throws {
        let good = Config.ToolsConfig(disabled: ["notify"], custom: [Self.count])
        try good.validate()
        #expect(throws: CustomTool.Failure.self) { try Config.ToolsConfig(disabled: ["nope"]).validate() }
        let json =
            #"{"tools":{"disabled":["notify"],"custom":[{"name":"word_count","description":"Counts.","arguments":{"path":{"type":"string"}},"command":"wc -w {path}"}]}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(
            config.resolved.disabledTools == ["notify"] && config.resolved.customTools.map(\.name) == ["word_count"])
    }

    @Test func theModelDrivesACustomToolThroughTheGateAndTheAudit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-custom-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a b\n".utf8).write(to: dir.appending(path: "f.txt"))
        var definition = Self.count
        definition.workingDirectory = dir.path
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "loop", sink: sink)
        let gate = ApprovalGate(
            classifier: RuleRiskClassifier.standard, approver: DenyingApprover(reason: "no"),
            threshold: .level(.moderate), audit: audit)
        let tools = ToolRegistry(
            runner: .init(writableRoot: dir.path), audit: audit, approval: gate, custom: [definition]
        )
        .select(["word_count"]).tools
        let agent = Agent(
            instructions: "x", tools: tools,
            model: ResolvedModel(
                selection: .system,
                custom: ScriptedModel(steps: [
                    .call(name: "word_count", arguments: #"{"path":"f.txt"}"#), .say("Result: {tool}"),
                ])),
            audit: audit)
        let reply = try await agent.respond(to: "count")
        #expect(reply.text.contains("2 f.txt"), "\(reply.text)")
        #expect(sink.events.contains { $0.kind == .classifierVerdict && $0.details["command"] == "wc -w 'f.txt'" })
        #expect(sink.events.contains { $0.kind == .toolCall && $0.details["tool"] == "word_count" })
    }
}

import Foundation
import Testing

@testable import WispCore

@Suite struct ToolDescriptionsTests {
    @Test func everyRegisteredToolIsDescribed() {
        let registry = ToolRegistry()
        let descriptions = registry.descriptions
        #expect(descriptions.map(\.name) == registry.all.map(\.name))
        for tool in descriptions {
            #expect(!tool.description.isEmpty, "\(tool.name)")
            #expect(!tool.limits.isEmpty, "\(tool.name) has no limits text")
            #expect(tool.examplePrompt.contains(tool.name), "\(tool.name) example does not name the tool")
            guard case .object(let schema) = tool.parameters else { Issue.record("\(tool.name) schema"); return }
            #expect(schema["type"] == "object")
            #expect(schema["properties"] != nil)
        }
    }

    @Test func readFileSchemaCarriesGuideText() {
        let readFile = ToolRegistry().descriptions.first { $0.name == "read_file" }
        guard case .object(let schema)? = readFile?.parameters, case .object(let properties)? = schema["properties"],
            case .object(let path)? = properties["path"]
        else { Issue.record("schema shape"); return }
        #expect(path["type"] == "string")
        #expect(path["description"]?.stringValue?.contains("Path") == true)
        #expect(schema["required"] == .array(["path"]))
    }

    @Test func limitsComeFromTheLiveOptions() {
        let registry = ToolRegistry(
            runner: .init(timeout: .seconds(5), maxOutputBytes: 999), reader: FileReader(maxBytes: 777),
            budget: ToolBudget(window: 65536))
        let limits = Dictionary(uniqueKeysWithValues: registry.descriptions.map { ($0.name, $0.limits) })
        #expect(limits["run_command"]?.contains("Timeout 5 s") == true)
        #expect(limits["run_command"]?.contains("999 bytes") == true)
        #expect(limits["read_file"]?.contains("32768 bytes") == true)
        var unsandboxed = CommandRunner.Options()
        unsandboxed.policy.sandbox.enabled = false
        #expect(
            ToolRegistry(runner: unsandboxed).descriptions.first { $0.name == "run_command" }?.limits.contains(
                "no sandbox") == true)
    }

    @Test func rendersJSONAndMarkdown() {
        let registry = ToolRegistry()
        #expect(registry.descriptionsJSON.contains("\"name\" : \"run_command\""))
        let markdown = registry.descriptionsMarkdown
        #expect(markdown.hasPrefix("# wisp tools"))
        for tool in registry.all {
            #expect(markdown.contains("## \(tool.name)"))
        }
        #expect(markdown.contains("- `path` (string, required)"))
        #expect(markdown.contains("Example prompt: Use read_file"))
        #expect(!registry.descriptionsMarkdown(measurements: []).contains("Measured:"))
        #expect(markdown.contains("Measured:") == !Measurements.embedded.isEmpty)
    }

    @Test func markdownAndJSONCarryMeasurements() throws {
        let registry = ToolRegistry()
        let measured = Measurement(
            task: "edit_file.replace", tool: "edit_file", model: "system", passed: 4, total: 5, notes: "exact")
        let described = registry.descriptions(measurements: [measured])
        let json = String(decoding: try JSONEncoder().encode(described), as: UTF8.self)
        #expect(json.contains("\"task\":\"edit_file.replace\""))
        let markdown = registry.descriptionsMarkdown(measurements: [measured])
        #expect(markdown.contains("Measured: edit_file.replace 4/5 (80%) on system, \(measured.date): exact\n"))
        #expect(markdown.components(separatedBy: "Measured:").count == 2)
    }
}

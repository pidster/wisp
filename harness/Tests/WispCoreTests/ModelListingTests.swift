import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A backend with one model of each kind: tool-capable, text-only, and one that will not resolve.
private struct ListingBackend: ModelBackend {
    let scheme = "listing"

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let selection = ModelSelection.local(backend: scheme, name: name)
        switch name {
        case "tools":
            return ResolvedModel(selection: selection, custom: ScriptedModel(steps: []), capabilitySource: .runtime)
        case "text":
            return ResolvedModel(
                selection: selection, custom: ScriptedModel(steps: [], capabilities: []), capabilitySource: .runtime)
        default:
            throw ModelSelection.Failure.unavailable(model: "listing:\(name)", reason: "cannot hold a conversation")
        }
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        ["tools", "text", "embed"].map {
            InstalledModel(selection: .local(backend: scheme, name: $0), detail: "\($0) detail")
        }
    }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { [:] }
}

@Suite(.serialized) struct ModelListingTests {
    init() { ModelBackends.register(ListingBackend()) }

    /// Ollama pointed at a port nothing listens on, so its line is the unreachable one on any Mac.
    private let config = Config(ollama: .init(baseURL: "http://127.0.0.1:1", timeoutSeconds: 1)).resolved
    private let home = Home(
        root: FileManager.default.temporaryDirectory.appending(path: "wisp-listing-\(UUID().uuidString)"))

    @Test func listsOnlyWhatCanServeTheConversation() async {
        let tools: [any Tool] = [CurrentDateTool()]
        let current = ModelSelection.local(backend: "listing", name: "tools")
        let lines = await ModelListing.lines(config: config, home: home, current: current, tools: tools)
        #expect(lines.contains("* listing:tools\ttools detail; toolCalling, guidedGeneration"))
        // A text-only model is not offered to a conversation with tools; a non-conversational one never is.
        #expect(!lines.contains { $0.contains("listing:text") } && !lines.contains { $0.contains("listing:embed") })
        #expect(!lines.contains { $0.contains("private-cloud") })  // no entitlement in a test binary
        #expect(lines.contains { $0.hasPrefix("  (ollama: ") })
        // With no tools the text-only model is usable too.
        let plain = await ModelListing.lines(config: config, home: home, current: .system, tools: [])
        #expect(plain.contains("  listing:text\ttext detail"))
        #expect(!plain.contains { $0.contains("listing:embed") })
    }

    @Test func chatShowsATableOfTheUsableModels() async {
        let current = ModelSelection.local(backend: "listing", name: "tools")
        let lines = await ModelListing.table(config: config, home: home, current: current, tools: [CurrentDateTool()])
        #expect(lines.first?.hasPrefix("  MODEL") == true && lines.first?.contains("CAPABILITIES") == true)
        let row = lines.first { $0.contains("listing:tools") } ?? ""
        #expect(row.hasPrefix("* listing:tools"))
        #expect(!lines.contains { $0.contains("\t") })
        // Every row's capabilities start in the header's column.
        let column = lines.first?.range(of: "CAPABILITIES").map {
            lines[0].distance(from: lines[0].startIndex, to: $0.lowerBound)
        }
        let capabilities = row.range(of: "toolCalling").map { row.distance(from: row.startIndex, to: $0.lowerBound) }
        #expect(column != nil && column == capabilities)
        #expect(lines.contains { $0.hasPrefix("  (ollama: ") })
        #expect(
            ModelListing.table([], unreachable: ["x: down"], current: .system) == [
                "no usable model; wisp models --all shows why", "  (x: down)",
            ])
    }

    @Test func allAddsTheExcludedWithTheirReasons() async {
        let lines = await ModelListing.lines(
            config: config, home: home, current: .system, tools: [CurrentDateTool()], all: true)
        #expect(lines.contains { $0.hasPrefix("  listing:text\tnot usable: ") && $0.contains("tool calling") })
        #expect(
            lines.contains {
                $0.hasPrefix("  listing:embed\tnot usable: ") && $0.contains("cannot hold a conversation")
            })
        #expect(lines.contains { $0.hasPrefix("  private-cloud\tnot usable: ") })
        let entries = await ModelListing.entries(config: config, home: home, tools: [])
        #expect(entries.entries.first { $0.selection == .local(backend: "listing", name: "text") }?.problem == nil)
        #expect(entries.unreachable.contains { $0.hasPrefix("ollama: ") })
    }

    @Test func aTerminalGetsAlignedColumnsAndPipedKeepsTabs() async {
        let current = ModelSelection.local(backend: "listing", name: "tools")
        let tools: [any Tool] = [CurrentDateTool()]
        let piped = await ModelListing.lines(config: config, home: home, current: current, tools: tools, width: nil)
        #expect(piped == (await ModelListing.lines(config: config, home: home, current: current, tools: tools)))
        #expect(piped.contains("* listing:tools\ttools detail; toolCalling, guidedGeneration"))
        let lines = await ModelListing.lines(config: config, home: home, current: current, tools: tools, width: 100)
        #expect(lines.first?.hasPrefix("  MODEL") == true && lines.first?.contains("CAPABILITIES") == true)
        #expect(!lines.contains { $0.contains("\t") })
        #expect(lines.contains { $0.hasPrefix("* listing:tools") && $0.hasSuffix("toolCalling, guidedGeneration") })
        #expect(lines.contains { $0.hasPrefix("  (ollama: ") })
        #expect(!lines.contains { $0.contains("listing:text") })
    }

    @Test func theTerminalTableSplitsDetailAndWrapsReasons() {
        let tool = ModelSelection.local(backend: "x", name: "big")
        let embed = ModelSelection.local(backend: "x", name: "embed")
        let entries = [
            ModelListing.Entry(selection: .system, detail: "", capabilities: ["toolCalling", "vision"], problem: nil),
            ModelListing.Entry(
                selection: tool, detail: "27.3B 17.74 GB", capabilities: ["toolCalling"], problem: nil),
            ModelListing.Entry(
                selection: embed, detail: "274.3 MB", capabilities: [],
                problem: "it cannot hold a conversation and has no other use at all here"),
        ]
        let usable = ModelListing.terminal(entries, unreachable: [], current: tool, all: false, width: 80)
        #expect(
            usable == [
                "  MODEL   PARAMS  SIZE      CAPABILITIES",
                "  system                    toolCalling, vision",
                "* x:big   27.3B   17.74 GB  toolCalling",
            ])
        let all = ModelListing.terminal(
            entries, unreachable: ["ollama: down"], current: tool, all: true, width: 60)
        #expect(all.first == "  MODEL    PARAMS  SIZE      CAPABILITIES")
        // The reason sits on its own lines under the model, indented four and wrapped to the full width.
        #expect(
            all.suffix(4) == [
                "  x:embed          274.3 MB",
                "    not usable: it cannot hold a conversation and has no",
                "    other use at all here",
                "  (ollama: down)",
            ])
        #expect(all.allSatisfy { $0.count <= 58 })
        #expect(all.last == "  (ollama: down)")
        #expect(
            ModelListing.terminal([], unreachable: [], current: .system, all: false, width: 80)
                == ["no usable model; wisp models --all shows why"])
    }
}

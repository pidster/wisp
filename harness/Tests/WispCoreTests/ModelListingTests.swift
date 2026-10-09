import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A backend with one model of each kind: tool-capable, text-only, and one that will not resolve; and a cached
/// model that enabling would link.
private struct ListingBackend: ModelBackend {
    let scheme = "listing"

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let selection = ModelSelection.local(backend: scheme, name: name)
        switch name {
        case "tools":
            return ResolvedModel(
                selection: selection, custom: ScriptedModel(steps: []), capabilitySource: .runtime, contextSize: 32_768,
                contextNote: "32,768 of 131,072: 9.1 GiB of a 24.0 GiB budget")
        case "text":
            return ResolvedModel(
                selection: selection, custom: ScriptedModel(steps: [], capabilities: []), capabilitySource: .runtime)
        default:
            throw ModelSelection.Failure.unavailable(model: "listing:\(name)", reason: "cannot hold a conversation")
        }
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        [
            InstalledModel(
                selection: .local(backend: scheme, name: "tools"), detail: "tools detail", parameters: "3B",
                bytes: 2_000_000_000, format: "fake Q4_K_M"),
            InstalledModel(selection: .local(backend: scheme, name: "text"), detail: "text detail"),
            InstalledModel(selection: .local(backend: scheme, name: "embed"), detail: "embed detail"),
        ]
    }

    func unlinked(config: Config.Resolved, home: Home) -> [InstalledModel] {
        [
            InstalledModel(
                selection: .local(backend: scheme, name: "cached"), detail: "cached", bytes: 1_000_000_000,
                format: "qwen3 4-bit", location: .hubCacheNotLinked)
        ]
    }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { [:] }
}

@Suite(.serialized) struct ModelListingTests {
    init() { ModelBackends.register(ListingBackend()) }

    /// Ollama pointed at a port nothing listens on, so its line is the unreachable one on any Mac.
    private let config = Config(ollama: .init(baseURL: "http://127.0.0.1:1", timeoutSeconds: 1)).resolved
    private let home = Home(
        root: FileManager.default.temporaryDirectory.appending(path: "wisp-listing-\(UUID().uuidString)"))
    private let tools = ModelSelection.local(backend: "listing", name: "tools")

    @Test func listsWhatCanServeTheConversationAndWhatCanBeTurnedOn() async {
        let lines = await ModelListing.lines(config: config, home: home, current: tools, tools: [CurrentDateTool()])
        // Piped: every column, tab-separated, in the table's order, empty where nothing is known.
        #expect(
            lines.contains(
                "* listing:tools\tlisting\t3B\t2 GB\tfake Q4_K_M\t32,768\tmemory\t\tyes\ttools, structured replies"))
        // A text-only model is not offered to a conversation with tools; a non-conversational one never is.
        #expect(!lines.contains { $0.contains("listing:text") } && !lines.contains { $0.contains("listing:embed") })
        #expect(!lines.contains { $0.contains("private-cloud") })  // no entitlement in a test binary
        #expect(lines.contains { $0.hasPrefix("  (ollama: ") })
        // The cached model enabling would link is listed, off, wherever it can be turned on.
        #expect(lines.contains("  listing:cached\tlisting\t\t1 GB\tqwen3 4-bit\t\t\tHF cache, not linked\tno\t"))
        // With no tools the text-only model is usable too, and says it is text only.
        let plain = await ModelListing.lines(config: config, home: home, current: .system, tools: [])
        #expect(plain.contains("  listing:text\tlisting\t\t\t\t\t\t\tyes\ttext only"))
        #expect(!plain.contains { $0.contains("listing:embed") })
    }

    @Test func aDisabledModelIsListedOffAndNotOffered() async throws {
        let gone = ModelSelection.local(backend: "listing", name: "gone")
        let listing = await ModelListing.entries(config: config, home: home, tools: [], disabled: [tools, gone])
        let entry = try #require(listing.entries.first { $0.selection == tools })
        #expect(!entry.enabled && entry.usable && !entry.offered)
        // A disabled model no backend lists is still listed, so it can be enabled, with why it cannot run.
        let missing = try #require(listing.entries.first { $0.selection == gone })
        #expect(!missing.enabled && missing.problem?.contains("cannot hold a conversation") == true)
        #expect(listing.shown(all: false).contains { $0.selection == gone })
        #expect(listing.entries.first { $0.selection == .system }?.enabled == true)
        // A cached model is neither usable nor offered until it is linked.
        let cached = try #require(listing.entries.first { $0.selection == .local(backend: "listing", name: "cached") })
        #expect(!cached.linked && !cached.usable && !cached.enabled && cached.plainCapabilities.isEmpty)
        let fromConfig = await ModelListing.entries(
            config: Config(models: .init(disabled: [tools])).resolved, home: home, tools: [])
        #expect(fromConfig.entries.first { $0.selection == tools }?.enabled == false)
    }

    @Test func allAddsTheExcludedWithTheirReasons() async {
        let lines = await ModelListing.lines(
            config: config, home: home, current: .system, tools: [CurrentDateTool()], all: true)
        #expect(lines.contains { $0.hasPrefix("  listing:text\t") && $0.contains("\tnot usable: ") })
        #expect(lines.contains { $0.contains("tool calling") })
        #expect(lines.contains { $0.hasPrefix("  listing:embed\t") && $0.contains("cannot hold a conversation") })
        #expect(lines.contains { $0.hasPrefix("  private-cloud\t") && $0.contains("not usable: ") })
        let entries = await ModelListing.entries(config: config, home: home, tools: [])
        #expect(entries.entries.first { $0.selection == .local(backend: "listing", name: "text") }?.problem == nil)
        #expect(entries.unreachable.contains { $0.hasPrefix("ollama: ") })
    }

    @Test func theFactsReadInPlainWords() {
        func entry(_ note: String?, size: Int? = 8_192) -> ModelListing.Entry {
            ModelListing.Entry(selection: .system, contextSize: size, contextNote: note)
        }
        #expect(entry(nil).contextFrom == "model")
        #expect(entry(nil, size: nil).contextFrom == nil)
        #expect(entry("configured as ollama.contextLength").contextFrom == "config")
        #expect(entry(ContextSizing.perModelReason("mlx", name: "q")).contextFrom == "model config")
        #expect(entry("declared by the bundle (metadata.json max_context_length)").contextFrom == "bundle")
        #expect(entry("8,192, the default: Ollama reported no model shape to size from").contextFrom == "default")
        #expect(entry("the default, not sized").contextFrom == "default")
        #expect(entry("32,768 of 131,072: 9.1 GiB of a 24.0 GiB budget").contextFrom == "memory")
        #expect(entry("8,192 of 32,768, the floor: needs 30 GiB but the budget is 12 GiB").contextFrom == "memory")
        // Every window note the backends write reads as one of the words.
        let sized = ContextSizing.size(
            shape: .init(maxContext: 131_072, layers: 40, keyValueHeads: 8, keyLength: 128, valueLength: 128),
            weights: 5 << 30, memory: MemoryState(installed: 64 << 30, available: 40 << 30))
        #expect(entry(sized.reason).contextFrom == "memory")
        #expect(entry(OllamaModel(name: "q").windowReason).contextFrom == "default")
        let capable = ModelListing.Entry(
            selection: .system, capabilities: ["toolCalling", "guidedGeneration", "reasoning", "vision"])
        #expect(capable.plainCapabilities == ["tools", "structured replies", "thinking", "vision"])
        #expect(ModelListing.Entry(selection: .system).plainCapabilities == ["text only"])
        #expect(ModelListing.Entry(selection: .system, problem: "no").plainCapabilities.isEmpty)
        #expect(ModelListing.Entry(selection: .system).runtime == "on-device")
        #expect(ModelListing.Entry(selection: .privateCloud).runtime == "Private Cloud")
        #expect(ModelListing.Entry(selection: .ollama("x")).runtime == "Ollama")
        #expect(ModelListing.Entry(selection: .local(backend: "mlx", name: "x")).runtime == "MLX")
        #expect(ModelListing.Entry(selection: .local(backend: "coreai", name: "x")).runtime == "Core AI")
    }

    /// A listing with a model of every runtime, as this Mac might have: what the samples in docs/wisp.md show.
    static let sample = ModelListing.Listing(
        entries: [
            .init(
                selection: .system, contextSize: 8_192, capabilities: ["toolCalling", "guidedGeneration", "vision"]),
            .init(
                selection: .ollama("granite4.1:8b"), parameters: "8.8B", bytes: 5_351_000_000,
                format: "granite Q4_K_M", contextSize: 65_536, contextNote: "65,536 of 131,072: 14.9 GiB of a 24 GiB",
                capabilities: ["toolCalling", "guidedGeneration"]),
            .init(
                selection: .ollama("qwen3.8:27b"), parameters: "27.3B", bytes: 17_740_000_000,
                format: "qwen3 Q4_K_M", contextSize: 32_768, contextNote: "32,768 of 262,144: 23.1 GiB of a 24 GiB",
                capabilities: ["toolCalling", "guidedGeneration", "reasoning"], enabled: false),
            .init(
                selection: .local(backend: "mlx", name: "Qwen3-1.7B-4bit"), bytes: 984_000_000, format: "qwen3 4-bit",
                location: .hubCache, contextSize: 40_960, contextNote: "40,960 of 40,960: 5.5 GiB of a 24 GiB",
                capabilities: ["toolCalling", "guidedGeneration"]),
            .init(
                selection: .local(backend: "mlx", name: "Qwen3-4B-4bit"), bytes: 2_260_000_000, format: "qwen3 4-bit",
                location: .hubCacheNotLinked, enabled: false),
        ],
        unreachable: [])

    @Test func theTerminalTableKeepsWhatFitsAndDropsTheLeastImportantColumnsFirst() {
        let current = ModelSelection.ollama("granite4.1:8b")
        let wide = ModelTable.terminal(Self.sample, current: current, all: false, width: 160)
        #expect(
            wide == [
                "  MODEL                 RUNTIME    PARAMS  SIZE      FORMAT          CONTEXT  FROM    WHERE                 ENABLED  CAPABILITIES",
                "  system                on-device                                    8,192    model                         yes      tools, structured replies, vision",
                "* ollama:granite4.1:8b  Ollama     8.8B    5.35 GB   granite Q4_K_M  65,536   memory                        yes      tools, structured replies",
                "  ollama:qwen3.8:27b    Ollama     27.3B   17.74 GB  qwen3 Q4_K_M    32,768   memory                        no       tools, structured replies, thinking",
                "  mlx:Qwen3-1.7B-4bit   MLX                984 MB    qwen3 4-bit     40,960   memory  HF cache              yes      tools, structured replies",
                "  mlx:Qwen3-4B-4bit     MLX                2.26 GB   qwen3 4-bit                      HF cache, not linked  no",
            ])
        // At 120 columns the format and the runtime go; at 80 where the window came from and where the model lives,
        // and the parameter count, too.
        let medium = ModelTable.terminal(Self.sample, current: current, all: false, width: 120)
        #expect(
            medium.first
                == "  MODEL                 PARAMS  SIZE      CONTEXT  FROM    WHERE                 ENABLED  CAPABILITIES"
        )
        #expect(medium.allSatisfy { $0.count <= 118 })
        let narrow = ModelTable.terminal(Self.sample, current: current, all: false, width: 80)
        #expect(
            narrow == [
                "  MODEL                 SIZE      CONTEXT  ENABLED  CAPABILITIES",
                "  system                          8,192    yes      tools, structured replies,",
                "                                                    vision",
                "* ollama:granite4.1:8b  5.35 GB   65,536   yes      tools, structured replies",
                "  ollama:qwen3.8:27b    17.74 GB  32,768   no       tools, structured replies,",
                "                                                    thinking",
                "  mlx:Qwen3-1.7B-4bit   984 MB    40,960   yes      tools, structured replies",
                "  mlx:Qwen3-4B-4bit     2.26 GB            no",
            ])
        #expect(narrow.allSatisfy { $0.count <= 78 })
        // A column nothing has a value for is left out.
        let apple = ModelListing.Listing(entries: [Self.sample.entries[0]])
        #expect(
            ModelTable.terminal(apple, current: .system, all: false, width: 100) == [
                "  MODEL   RUNTIME    CONTEXT  FROM   ENABLED  CAPABILITIES",
                "* system  on-device  8,192    model  yes      tools, structured replies, vision",
            ])
        #expect(
            ModelTable.terminal(.init(entries: []), current: .system, all: false, width: 80)
                == ["no usable model; wisp models --all shows why"])
        // The reason sits on its own lines under the model, indented four and wrapped to the full width.
        let broken = ModelListing.Listing(
            entries: [.init(selection: .ollama("embed"), bytes: 274_300_000, problem: "it cannot hold a conversation")],
            unreachable: ["mlx: down"])
        #expect(
            ModelTable.terminal(broken, current: .system, all: true, width: 60) == [
                "  MODEL         SIZE      ENABLED  CAPABILITIES",
                "  ollama:embed  274.3 MB  yes",
                "    not usable: it cannot hold a conversation",
                "  (mlx: down)",
            ])
    }

    @Test func fittingDropsByRankAndNeverTheUndroppable() {
        let header = ["NAME", "A", "B", "LAST"]
        let rows = [["a-long-name", "aaaaaaaaaa", "bbbbbbbbbb", "x"]]
        #expect(TerminalTable.fitting(header: header, rows: rows, drop: [0, 2, 1, 0], width: 80) == [0, 1, 2, 3])
        #expect(TerminalTable.fitting(header: header, rows: rows, drop: [0, 2, 1, 0], width: 50) == [0, 1, 3])
        #expect(TerminalTable.fitting(header: header, rows: rows, drop: [0, 2, 1, 0], width: 30) == [0, 3])
        #expect(TerminalTable.fitting(header: header, rows: rows, drop: [0, 0, 0, 0], width: 10) == [0, 1, 2, 3])
    }

    @Test func chatsTableTheJSONAndThePickerHaveTheSameColumns() throws {
        let current = ModelSelection.ollama("granite4.1:8b")
        let text = ModelTable.text(Self.sample, current: current)
        #expect(text.first?.hasPrefix("  MODEL                 RUNTIME    PARAMS") == true)
        #expect(!text.contains { $0.contains("\t") })
        #expect(text.contains { $0.hasPrefix("* ollama:granite4.1:8b") })
        let json = ModelTable.json(Self.sample, current: current, all: false)
        let models = try #require(json.objectValue?["models"]?.arrayValue)
        #expect(models.count == 5)
        let granite = try #require(models[1].objectValue)
        #expect(granite["model"] == "ollama:granite4.1:8b" && granite["default"] == true)
        #expect(granite["runtime"] == "Ollama" && granite["parameters"] == "8.8B" && granite["size"] == "5.35 GB")
        #expect(granite["bytes"] == 5_351_000_000 && granite["format"] == "granite Q4_K_M")
        #expect(granite["context"] == 65_536 && granite["contextFrom"] == "memory")
        #expect(granite["contextNote"]?.stringValue?.hasPrefix("65,536 of") == true)
        #expect(granite["enabled"] == true && granite["usable"] == true && granite["problem"] == .null)
        #expect(granite["capabilities"] == ["tools", "structured replies"] && granite["location"] == .null)
        #expect(models[4].objectValue?["location"] == "hubCacheNotLinked")
        #expect(models[4].objectValue?["usable"] == false && models[4].objectValue?["enabled"] == false)
        // The picker: a row per model, on when enabled, every present column but ENABLED, which the toggle shows.
        let choice = ModelTable.choice(Self.sample, current: current)
        #expect(choice.toggles && choice.current == "ollama:granite4.1:8b")
        #expect(
            choice.columns.map(\.heading) == [
                "MODEL", "RUNTIME", "PARAMS", "SIZE", "FORMAT", "CONTEXT", "FROM", "WHERE", "CAPABILITIES",
            ])
        #expect(choice.columns.map(\.drop) == [0, 2, 5, 6, 1, 7, 3, 4, 0])
        #expect(choice.options.map(\.on) == [true, true, false, true, false])
        #expect(choice.options[1].cells.first == "ollama:granite4.1:8b")
        #expect(choice.options[1].cells.count == choice.columns.count)
    }
}

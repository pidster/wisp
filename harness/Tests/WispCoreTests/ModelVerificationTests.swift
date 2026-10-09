import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// How the fake model answers each question, shared by every copy of the backend.
private final class Answers: Sendable {
    /// Whether the plain reply has words.
    let reply = Mutex(true)
    /// The word `record_word` is called with; nil makes no call.
    let toolWord = Mutex<String?>("heron")
    /// Whether the schema reply decodes.
    let guided = Mutex(true)
    /// Whether the tool question never answers.
    let toolHangs = Mutex(false)

    func reset() {
        reply.withLock { $0 = true }
        toolWord.withLock { $0 = "heron" }
        guided.withLock { $0 = true }
        toolHangs.withLock { $0 = false }
    }
}

/// A model whose every request waits an hour, to hold a question past its limit.
private struct HangingModel: LanguageModel {
    /// The executor that never answers in time.
    struct Executor: LanguageModelExecutor {
        typealias Model = HangingModel
        init(configuration: Int) throws {}
        nonisolated(nonsending) func respond(
            to request: LanguageModelExecutorGenerationRequest, model: HangingModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    let capabilities = LanguageModelCapabilities([.toolCalling])
    var executorConfiguration: Int { 0 }
}

/// A backend under `verifying:` whose models leave their capabilities to `config.json`, as MLX's do, kept in the
/// file's `mlx` section; the model answers each question as `Answers` says.
private struct VerifyingBackend: ModelBackend {
    let scheme = "verifying"
    let answers: Answers

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        let selection = ModelSelection.local(backend: scheme, name: name)
        guard name != "missing" else {
            throw ModelSelection.Failure.unavailable(model: selection.description, reason: "no such model")
        }
        let declared = config.mlxModels[name]
        let capabilities = try CapabilityName.parse(declared ?? [], forModel: selection.description)
        let source: CapabilitySource = declared == nil ? .undeclared : .configuration
        if capabilities == [.toolCalling], answers.toolHangs.withLock({ $0 }) {
            return ResolvedModel(selection: selection, custom: HangingModel(), capabilitySource: source)
        }
        let steps: [ScriptedModel.Step]
        switch capabilities {
        case [.toolCalling]:
            steps =
                answers.toolWord.withLock { $0 }.map {
                    [.call(name: "record_word", arguments: #"{"word":"\#($0)"}"#), .say("recorded")]
                } ?? [.say("I cannot")]
        case [.guidedGeneration]:
            steps = [.say(answers.guided.withLock { $0 } ? #"{"colour":"blue","number":3}"# : "blue")]
        default:
            steps = [.say(answers.reply.withLock { $0 } ? "hello there" : "")]
        }
        return ResolvedModel(
            selection: selection, custom: ScriptedModel(steps: steps, capabilities: capabilities),
            capabilitySource: source)
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        [
            InstalledModel(
                selection: .local(backend: scheme, name: "m"), detail: "", bytes: 1_000_000,
                verified: config.mlxVerified["m"]?.date)
        ]
    }

    func declarationKeys(for name: String) -> [String]? { ["mlx", "models", name] }

    func declaring(
        _ declaration: Config.MLXModelConfig, for name: String, in config: Config.Resolved
    )
        -> Config.Resolved
    {
        var config = config
        config.mlxModels[name] = declaration.capabilities ?? []
        config.mlxVerified[name] = declaration.verified
        return config
    }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { [:] }
}

@Suite(.serialized) struct ModelVerificationTests {
    private static let answers = Answers()
    private let model = ModelSelection.local(backend: "verifying", name: "m")
    /// Limits for checks that pass at once: generous, because a 10 s limit expired under the gate's full parallel
    /// load (2026-10-09, twice) while the scripted model's answer waited for a thread; the hanging check sets its own.
    private let quick = ModelVerification.Limits(first: .seconds(60), each: .seconds(60))
    /// 2026-10-04 at noon, in the Mac's zone.
    private let day: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 4, hour: 12)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }()

    init() {
        Self.answers.reset()
        ModelBackends.register(VerifyingBackend(answers: Self.answers))
    }

    /// A scratch home with `config` as its file, removed by the caller.
    private func home(_ config: String? = nil) throws -> Home {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-verifying-\(UUID())"))
        try home.ensure()
        // Every HTTP backend offline, so listing and checking models never reach a server on this Mac.
        try Data(OfflineBackends.file(config).utf8).write(to: home.configFile)
        return home
    }

    private func session(_ home: Home, sink: MemoryAuditSink) throws -> Session {
        try Session.begin(.init(entryPoint: .models), home: home, dependencies: .testing(sink: sink))
    }

    /// The model's declaration in `home`'s file.
    private func declaration(_ home: Home) throws -> Config.MLXModelConfig? {
        try Config.load(from: home.configFile).mlx?.models?["m"]
    }

    /// Runs the check, returning the progress lines and the result lines.
    private func check(
        _ session: Session, force: Bool, limits: ModelVerification.Limits? = nil, name: String = "verifying:m"
    ) async throws -> (progress: [String], lines: [String]) {
        let progress = Mutex<[String]>([])
        let lines = try await session.checkModels(
            [name], force: force, source: "cli", limits: limits ?? quick, now: day
        ) { line in progress.withLock { $0.append(line) } }
        return (progress.withLock { $0 }, lines)
    }

    @Test func everyCheckPassingRecordsTheCapabilitiesAuditsAndHoldsInTheSessionAtOnce() async throws {
        let home = try home(#"{"ollama":{"baseURL":"http://127.0.0.1:9"}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        // Undeclared, it cannot serve a conversation with tools.
        #expect(throws: ModelSelection.Failure.self) {
            try session.openAgent(approver: DenyingApprover(reason: "x"), model: model)
        }
        let (progress, lines) = try await check(session, force: false)
        #expect(
            progress.first
                == "checking verifying:m: loads the model (1 MB) and asks three short questions (a reply, a tool "
                + "call, a structured reply), allowing 60 s for the first, which loads it, and 60 s for each of the "
                + "others")
        #expect(
            progress.dropFirst().map { $0.components(separatedBy: " in ").first ?? "" } == [
                "  reply: passed", "  tool calling: passed", "  structured reply: passed",
            ])
        #expect(
            lines == [
                "recorded in config.json: verifying:m can do tools, structured replies (verified 2026-10-04)",
                "enabled verifying:m", ModelVerification.uncheckedNote,
            ])
        let written = try #require(try declaration(home))
        #expect(written.capabilities == ["toolCalling", "guidedGeneration"])
        #expect(
            written.verified
                == Config.CapabilityCheck(date: "2026-10-04", passed: ["toolCalling", "guidedGeneration"], failed: []))
        #expect(try Config.load(from: home.configFile).ollama?.baseURL == "http://127.0.0.1:9")  // the rest is kept
        // Audited: the check, then the change, through ConfigEdit.
        let verified = try #require(sink.events.first { $0.kind == .modelVerified })
        #expect(Set(verified.details.keys) == AuditEvent.fields(for: .modelVerified))
        #expect(verified.details["model"] == "verifying:m" && verified.details["trigger"] == "enable")
        #expect(verified.details["outcome"] == "usable")
        #expect(verified.details["recorded"] == ["toolCalling", "guidedGeneration"])
        #expect(verified.details["unchecked"] == ["reasoning", "vision"])
        let checks = try #require(verified.details["checks"]?.arrayValue)
        #expect(
            checks.compactMap { $0.objectValue?["check"]?.stringValue } == ["reply", "toolCalling", "guidedGeneration"])
        #expect(checks.allSatisfy { $0.objectValue?["passed"] == true && $0.objectValue?["seconds"] != nil })
        let change = try #require(sink.events.last { $0.kind == .configChange })
        #expect(change.details["path"] == "mlx.models.m" && change.details["source"] == "cli")
        #expect(change.details["old"] == .null)
        // This session uses it now, with tools; the listing says the capabilities were verified.
        _ = try session.openAgent(approver: DenyingApprover(reason: "x"), model: model)
        let listing = await ModelListing.entries(
            config: session.declaredModels.applied(to: session.config), home: home,
            tools: [CurrentDateTool()])
        let entry = try #require(listing.entries.first { $0.selection == model })
        #expect(entry.usable && entry.capabilitiesFrom == "verified 2026-10-04")
        #expect(ModelTable.cell(ModelTable.columns[9], entry) == "tools, structured replies (verified)")
        let json = ModelTable.json(listing, current: .system, all: false)
        let row = json.objectValue?["models"]?.arrayValue?.first { $0.objectValue?["model"] == "verifying:m" }
        #expect(row?.objectValue?["capabilitiesFrom"] == "verified 2026-10-04")
        // A model already declared is not checked again on enabling.
        let again = try await check(session, force: false)
        #expect(again.progress.isEmpty && again.lines.isEmpty)
        #expect(sink.events.filter { $0.kind == .modelVerified }.count == 1)
    }

    @Test func onlyThePassingCapabilitiesAreRecorded() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.toolWord.withLock { $0 = "egret" }
        let (progress, lines) = try await check(session(home, sink: MemoryAuditSink()), force: false)
        #expect(progress[2].hasPrefix("  tool calling: failed in "))
        #expect(progress[2].hasSuffix("(record_word was called with 'egret', not 'heron')"))
        #expect(lines.first == "recorded in config.json: verifying:m can do structured replies (verified 2026-10-04)")
        #expect(try declaration(home)?.capabilities == ["guidedGeneration"])
        #expect(try declaration(home)?.verified?.failed == ["toolCalling"])
        // No call at all, and a reply that does not decode: text only, still recorded, since the floor held.
        Self.answers.toolWord.withLock { $0 = nil }
        Self.answers.guided.withLock { $0 = false }
        let recheck = try await check(session(home, sink: MemoryAuditSink()), force: true)
        #expect(recheck.progress[2].hasSuffix("(no call to record_word arrived)"))
        #expect(recheck.progress[3].hasPrefix("  structured reply: failed in "))
        #expect(try declaration(home)?.capabilities == [])
        // guidedGeneration was the earlier check's, so this one takes it out, and says so.
        #expect(recheck.lines.contains("took out guidedGeneration: an earlier check passed it, this one did not"))
        #expect(recheck.lines.first == "recorded in config.json: verifying:m can do text only (verified 2026-10-04)")
    }

    @Test func aFailedFloorRecordsNothingAndAsksNothingMore() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.reply.withLock { $0 = false }
        let sink = MemoryAuditSink()
        let (progress, lines) = try await check(session(home, sink: sink), force: false)
        #expect(progress.count == 2 && progress[1].hasSuffix("(the reply was empty)"))
        // Enable refuses: the model, enabled but unusable before, is disabled; no capability is recorded.
        #expect(lines == ["verifying:m cannot hold a conversation (the reply was empty); it stays disabled"])
        #expect(try declaration(home) == nil)
        #expect(try Config.load(from: home.configFile).models?.disabled == [model])
        let verified = try #require(sink.events.first { $0.kind == .modelVerified })
        #expect(verified.details["recorded"] == .null && verified.details["checks"]?.arrayValue?.count == 1)
        #expect(verified.details["outcome"] == "refused")
        #expect(sink.events.filter { $0.kind == .configChange }.map { $0.details["path"] } == ["models.disabled"])
        // `check` reports and records only: it does not turn a model on or off.
        let checked = try await check(session(home, sink: sink), force: true)
        #expect(checked.lines == ["verifying:m cannot hold a conversation (the reply was empty); nothing was recorded"])
        #expect(try Config.load(from: home.configFile).models?.disabled == [model])
    }

    @Test func aCapabilityDeclaredByHandIsKeptWhenItsCheckFailsAndReported() async throws {
        let home = try home(#"{"mlx":{"models":{"m":{"capabilities":["toolCalling","reasoning"]}}}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.toolWord.withLock { $0 = nil }
        let sink = MemoryAuditSink()
        // Declared already: enabling checks nothing.
        let enabling = try await check(session(home, sink: sink), force: false)
        #expect(enabling.lines.isEmpty && sink.events.allSatisfy { $0.kind != .modelVerified })
        let (_, lines) = try await check(session(home, sink: sink), force: true)
        #expect(
            lines.contains(
                "kept toolCalling, which config.json declared by hand, though its check failed; remove it there if the "
                    + "model cannot"))
        let written = try #require(try declaration(home))
        #expect(written.capabilities == ["toolCalling", "guidedGeneration", "reasoning"])
        #expect(written.verified?.passed == ["guidedGeneration"] && written.verified?.failed == ["toolCalling"])
        let verified = try #require(sink.events.first { $0.kind == .modelVerified })
        #expect(verified.details["kept"] == ["toolCalling"] && verified.details["trigger"] == "check")
    }

    @Test func eachQuestionIsHeldToItsTimeLimit() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.toolHangs.withLock { $0 = true }
        let started = ContinuousClock.now
        let (progress, _) = try await check(
            session(home, sink: MemoryAuditSink()), force: false,
            limits: .init(first: .seconds(10), each: .milliseconds(300)))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(
            progress[2].hasPrefix("  tool calling: failed in ") && progress[2].hasSuffix("(no answer within 300 ms)"))
        #expect(try declaration(home)?.capabilities == ["guidedGeneration"])
    }

    @Test func enablingAnEnabledModelWithUndeclaredCapabilitiesChecksIt() async throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let session = try session(home, sink: MemoryAuditSink())
        // Already enabled: setModels leaves it to the check that follows, which still runs.
        #expect(try session.setModels(enable: ["verifying:m"], disable: [], source: "cli", checking: true) == [])
        let (progress, _) = try await check(session, force: false)
        #expect(progress.count == 4)
        #expect(try declaration(home)?.capabilities == ["toolCalling", "guidedGeneration"])
    }

    @Test func runtimesThatReportCapabilitiesAreNotCheckedAndAMissingModelIsSaidSo() async throws {
        let home = try home(#"{"ollama":{"baseURL":"http://127.0.0.1:9"}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        #expect(try await check(session, force: false, name: "ollama:granite4.1:8b").lines.isEmpty)
        #expect(
            try await check(session, force: true, name: "ollama:granite4.1:8b").lines == [
                "ollama:granite4.1:8b: its runtime reports what it can do; there is nothing to check"
            ])
        #expect(try await check(session, force: true, name: "system").lines.count == 1)
        let missing = try await check(session, force: true, name: "verifying:missing")
        #expect(missing.lines.count == 1 && missing.lines[0].hasPrefix("verifying:missing cannot be checked: "))
        #expect(missing.progress.isEmpty)
        #expect(!sink.events.contains { $0.kind == .modelVerified || $0.kind == .configChange })
    }

    @Test func theDecisionRecordsWhatPassedKeepsTheHandsAndTakesOutTheChecks() {
        func result(_ probe: ModelVerification.Probe, _ passed: Bool) -> ModelVerification.Result {
            .init(probe: probe, passed: passed, detail: "", seconds: 0)
        }
        let passing = [result(.reply, true), result(.toolCalling, true), result(.guidedGeneration, false)]
        #expect(ModelVerification.decide([result(.reply, false)], existing: nil, date: "d") == nil)
        let fresh = ModelVerification.decide(passing, existing: nil, date: "d")
        #expect(fresh?.capabilities == ["toolCalling"] && fresh?.kept == [] && fresh?.removed == [])
        #expect(fresh?.check == .init(date: "d", passed: ["toolCalling"], failed: ["guidedGeneration"]))
        // By hand: kept. From an earlier check: taken out. Unchecked ones stay.
        let byHand = Config.MLXModelConfig(capabilities: ["guidedGeneration", "vision"])
        #expect(ModelVerification.decide(passing, existing: byHand, date: "d")?.kept == ["guidedGeneration"])
        #expect(
            ModelVerification.decide(passing, existing: byHand, date: "d")?.capabilities
                == ["toolCalling", "guidedGeneration", "vision"])
        let checked = Config.MLXModelConfig(
            capabilities: ["guidedGeneration"], verified: .init(date: "c", passed: ["guidedGeneration"], failed: []))
        let decision = ModelVerification.decide(passing, existing: checked, date: "d")
        #expect(decision?.capabilities == ["toolCalling"] && decision?.removed == ["guidedGeneration"])
        #expect(ModelVerification.spoken(.seconds(180)) == "3 min" && ModelVerification.spoken(.seconds(60)) == "60 s")
    }

    @Test func aDeclarationIsWrittenUnderAKeyThatHoldsDots() throws {
        let outcome = try ConfigEdit.set(
            keys: ["mlx", "models", "Qwen3-1.7B-4bit"], to: ["capabilities": ["toolCalling"]], in: nil)
        #expect(outcome.path == "mlx.models.Qwen3-1.7B-4bit")
        let config = try JSONDecoder().decode(Config.self, from: outcome.data)
        #expect(config.mlx?.models?["Qwen3-1.7B-4bit"]?.capabilities == ["toolCalling"])
        #expect(config.resolved.mlxModels["Qwen3-1.7B-4bit"] == ["toolCalling"])
        #expect(
            try ConfigEdit.current(keys: ["mlx", "models", "Qwen3-1.7B-4bit"], in: outcome.data)
                == ["capabilities": ["toolCalling"]])
        // A value the file would not load as is refused, as every change is.
        #expect(throws: ConfigEdit.Failure.self) {
            try ConfigEdit.set(keys: ["mlx", "models", "x"], to: ["capabilities": 3], in: nil)
        }
    }

    /// A chat over `session` whose `/models` commands and picker run through the session as the CLI wires them, with
    /// the quick limits; `choose` answers the picker, nil makes the face one without choices.
    private func chat(
        _ session: Session, home: Home, lines: [String], choose: ((ChatChoice) async -> String?)? = nil
    ) async throws -> ChatLoopTests.Capture {
        let capture = ChatLoopTests.Capture(lines: lines + ["/quit"])
        var io = capture.io
        io.choose = choose
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [.say("hi")])))
        let limits = quick
        let day = day
        let context = ChatLoop.Context(
            directory: "/r", approval: "--yes",
            models: { tools in
                await ModelListing.entries(
                    config: session.declaredModels.applied(to: session.config), home: home, tools: tools,
                    disabled: session.disabledModels.all)
            },
            setModels: { enable, disable in
                try session.setModels(enable: enable, disable: disable, source: "chat", checking: true)
            },
            checkModels: { names, force, progress in
                try await session.checkModels(
                    names, force: force, source: "chat", limits: limits, now: day, progress: progress)
            })
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: home.root.appending(path: "saved")), saveName: nil,
            context: context, io: io)
        try await loop.run()
        return capture
    }

    /// The listing's entry for the model, judged for a conversation with tools.
    private func entry(_ session: Session, home: Home) async throws -> ModelListing.Entry {
        let listing = await ModelListing.entries(
            config: session.declaredModels.applied(to: session.config), home: home, tools: [CurrentDateTool()],
            disabled: session.disabledModels.all)
        return try #require(listing.entries.first { $0.selection == model })
    }

    @Test func enableRefusesAModelThatCannotHoldAConversationAndKeepsItDisabled() async throws {
        let home = try home(#"{"models":{"disabled":["verifying:m"]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.reply.withLock { $0 = false }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let typed = try await chat(session, home: home, lines: ["/models enable verifying:m"])
        #expect(typed.noted.contains("verifying:m cannot hold a conversation (the reply was empty); it stays disabled"))
        #expect(!typed.noted.contains { $0.hasPrefix("enabled") || $0.hasSuffix("is enabled") })
        #expect(try Config.load(from: home.configFile).models?.disabled == [model])
        #expect(session.disabledModels.contains(model))
        #expect(try declaration(home) == nil)
        #expect(sink.events.first { $0.kind == .modelVerified }?.details["outcome"] == "refused")
        // The picker's save: the same refusal.
        let picked = try await chat(session, home: home, lines: ["/models"]) { choice in
            ChatChoice.answer(values: choice.options.filter { $0.on == true }.map(\.value) + ["verifying:m"])
        }
        #expect(
            picked.noted.contains("verifying:m cannot hold a conversation (the reply was empty); it stays disabled"))
        #expect(session.disabledModels.contains(model))
    }

    @Test func aModelThatCallsNoToolIsEnabledForUseWithToolsOffOnlyAndSaysSo() async throws {
        let home = try home(#"{"models":{"disabled":["verifying:m"]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        Self.answers.toolWord.withLock { $0 = nil }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let typed = try await chat(session, home: home, lines: ["/models enable verifying:m"])
        #expect(
            typed.noted.contains(
                "verifying:m holds a conversation but did not call a tool; it is usable only with tools off: "
                    + "--no-tools, tools: [] over MCP, the condensers; chat and agents with tools refuse it"))
        #expect(!typed.noted.contains("enabled verifying:m"))
        #expect(try declaration(home)?.capabilities == ["guidedGeneration"])
        #expect(!session.disabledModels.contains(model))
        #expect(sink.events.first { $0.kind == .modelVerified }?.details["outcome"] == "text only")
        // Chat and agents with tools refuse it; with no tools it serves.
        #expect(throws: ModelSelection.Failure.self) {
            try session.openAgent(approver: DenyingApprover(reason: "x"), model: model)
        }
        // The table and the picker show what the check found: text only, verified; /model does not offer it.
        let found = try await entry(session, home: home)
        #expect(found.plainCapabilities == ["text only", "structured replies"] && !found.offered && found.enabled)
        #expect(ModelTable.cell(ModelTable.columns[9], found) == "text only, structured replies (verified)")
        #expect(
            found.problem?.hasPrefix("wisp's check on 2026-10-04 found it holds a conversation but calls no tools")
                == true)
        let listing = ModelListing.Listing(entries: [found])
        #expect(listing.shown(all: false) == [found])
        let choice = ModelTable.choice(listing, current: .system)
        #expect(choice.options.first?.cells.last == "text only, structured replies (verified)")
        // A model that passes nothing past the reply reads `text only`.
        let bare = ModelListing.Entry(
            selection: model, capabilities: [], problem: "x", capabilitySource: .configuration, verified: "2026-10-04")
        #expect(ModelTable.cell(ModelTable.columns[9], bare) == "text only (verified)")
    }

    @Test func aModelThatHoldsAConversationAndCallsToolsIsEnabledAndUsable() async throws {
        let home = try home(#"{"models":{"disabled":["verifying:m"]}}"#)
        defer { try? FileManager.default.removeItem(at: home.root) }
        let sink = MemoryAuditSink()
        let session = try session(home, sink: sink)
        let picked = try await chat(session, home: home, lines: ["/models"]) { choice in
            ChatChoice.answer(values: choice.options.filter { $0.on == true }.map(\.value) + ["verifying:m"])
        }
        #expect(picked.noted.contains("enabled verifying:m"))
        #expect(picked.noted.contains { $0.hasPrefix("checking verifying:m: loads the model") })
        #expect(!session.disabledModels.contains(model))
        #expect(try Config.load(from: home.configFile).models == nil)
        #expect(sink.events.first { $0.kind == .modelVerified }?.details["outcome"] == "usable")
        let found = try await entry(session, home: home)
        #expect(
            found.offered && ModelTable.cell(ModelTable.columns[9], found) == "tools, structured replies (verified)")
        _ = try session.openAgent(approver: DenyingApprover(reason: "x"), model: model)
    }
}

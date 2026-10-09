import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// A backend over the scripted model, registered under `scripted:`; the name selects the declared
/// capabilities (`tools` or `text`) so gating can be tested with no runtime.
private struct ScriptedBackend: ModelBackend {
    let scheme = "scripted"

    func resolve(_ name: String, config: Config.Resolved, home: Home) throws -> ResolvedModel {
        switch name {
        case "tools":
            return ResolvedModel(
                selection: .local(backend: scheme, name: name), custom: ScriptedModel(steps: [.say("hi")]),
                capabilitySource: .configuration, asset: "memory")
        case "text":
            return ResolvedModel(
                selection: .local(backend: scheme, name: name),
                custom: ScriptedModel(steps: [.say("hi")], capabilities: []), capabilitySource: .undeclared)
        default:
            throw ModelSelection.Failure.unavailable(model: "scripted:\(name)", reason: "no such script")
        }
    }

    func installed(config: Config.Resolved, home: Home) async throws -> [InstalledModel] {
        [InstalledModel(selection: .local(backend: scheme, name: "tools"), detail: "scripted")]
    }

    func settings(in config: Config.Resolved, home: Home) -> JSONValue { ["scripts": 2] }
}

@Suite(.serialized) struct ModelBackendTests {
    init() { ModelBackends.register(ScriptedBackend()) }

    @Test func registryResolvesListsAndDescribes() async throws {
        #expect(ModelBackends.schemes.contains("scripted") && ModelBackends.schemes.contains("ollama"))
        let resolved = try ModelSelection(parsing: "scripted:tools").resolve()
        #expect(resolved.capabilityNames == ["toolCalling", "guidedGeneration"])
        #expect(resolved.capabilitySource == .configuration)
        #expect(resolved.asset == "memory")
        #expect(
            try await ModelBackends.backend(for: "scripted")?.installed(
                config: Config().resolved, home: OfflineBackends.home
            )
            .first?.detail
                == "scripted")
        let views = Introspection(home: Home(root: URL(filePath: "/tmp")), config: Config().resolved)
        #expect(views.configuration.objectValue?["backends"]?.objectValue?["scripted"] == ["scripts": 2])
        #expect(throws: ModelSelection.Failure.unavailable(model: "scripted:nope", reason: "no such script")) {
            try ModelSelection.local(backend: "scripted", name: "nope").resolve()
        }
    }

    @Test func toolsAreRefusedBeforeGenerationUnlessDeclared() throws {
        let text = try ModelSelection(parsing: "scripted:text").resolve()
        #expect(text.capabilityNames.isEmpty)
        try text.check(tools: [])
        #expect(throws: ModelSelection.Failure.self) { try text.check(tools: [CurrentDateTool()]) }
        do {
            try text.check(tools: [CurrentDateTool()])
        } catch ModelSelection.Failure.unsupportedCapability(let model, let capability, let declaredBy, let hint) {
            #expect(model == "scripted:text" && capability == "tool calling" && declaredBy == .undeclared)
            #expect(hint.contains("--no-tools"))
            #expect(
                "\(ModelSelection.Failure.unsupportedCapability(model: model, capability: capability, declaredBy: declaredBy, hint: hint))"
                    .contains("undeclared"))
        }
        try ModelSelection(parsing: "scripted:tools").resolve().check(tools: [CurrentDateTool()])
    }

    @Test func aSessionGatesAndAuditsTheResolvedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-backend-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(
            .init(entryPoint: .respond, model: .local(backend: "scripted", name: "text")), home: home,
            dependencies: .testing(sink: sink))
        #expect(throws: ModelSelection.Failure.self) { try session.openAgent(approver: DenyingApprover(reason: "x")) }
        #expect(sink.events.contains { $0.kind == .modelResolved } == false)
        let textOnly = try Session.begin(
            .init(entryPoint: .respond, model: .local(backend: "scripted", name: "text"), tools: ToolSelection.none),
            home: home, dependencies: .testing(sink: sink))
        let agent = try textOnly.openAgent(approver: DenyingApprover(reason: "x"))
        #expect(agent.tools.isEmpty)
        let event = sink.events.last { $0.kind == .modelResolved }
        #expect(event?.details["model"] == "scripted:text")
        #expect(event?.details["backend"] == "scripted")
        #expect(event?.details["capabilities"] == .array([]))
        #expect(event?.details["capabilitySource"] == "undeclared")
        #expect(event?.details["tools"] == .array([]))
        #expect(event?.details["asset"] == .null)
        #expect(sink.events.last { $0.kind == .sessionStart }?.details["tools"] == .array([]))
    }
}

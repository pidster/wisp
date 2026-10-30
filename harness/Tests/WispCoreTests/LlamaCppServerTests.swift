import Foundation
import Testing

@testable import WispCore

/// `llamacpp.server` (ADR 0082, decision 3): `off` as before, `llama-app` at Llama.app's port with its open server
/// said plainly, `wisp` accepted and refused at every use until its server is built, and the choice refused for LM
/// Studio. What needs a server is in `OpenAICompatibleBackendTests`, which share the fake server.
@Suite struct LlamaCppServerTests {
    /// Loads `json` as `config.json`, returning the refusal's text, or nil when it loads.
    private func refusal(_ json: String) throws -> String? {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-llamacpp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(json.utf8).write(to: file)
        do {
            _ = try Config.load(from: file)
            return nil
        } catch let DecodingError.dataCorrupted(context) {
            return context.debugDescription
        } catch {
            return "\(error)"
        }
    }

    /// A folder standing in for an app bundle with `identifier`, under the temporary directory.
    static func bundle(_ identifier: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(
            path: "wisp-llama-app-\(UUID().uuidString)/Llama.app")
        let contents = app.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return app
    }

    @Test func offIsTheDefaultAndLeavesTheServerWhereItWas() {
        let settings = Config().resolved.llamacpp
        #expect(settings.server == .off && settings.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(settings.startHint(for: .llamaCpp) == OpenAICompatibleDialect.llamaCpp.startHint)
        #expect(LlamaCppServer.off.unusable == nil && LlamaCppServer.llamaApp.unusable == nil)
    }

    @Test func llamaAppTakesItsPortUnlessABaseURLIsSet() {
        let app = Config(llamacpp: .init(server: .llamaApp)).resolved.llamacpp
        #expect(app.server == .llamaApp && app.baseURL.absoluteString == "http://127.0.0.1:9931")
        let explicit = Config(llamacpp: .init(baseURL: "http://127.0.0.1:7000", server: .llamaApp)).resolved.llamacpp
        #expect(explicit.baseURL.absoluteString == "http://127.0.0.1:7000")
        // LM Studio's settings never carry the choice.
        #expect(Config().resolved.lmstudio.server == .off)
    }

    @Test func theChoiceLoadsForLlamaCppAndIsRefusedForLMStudio() throws {
        for value in ["off", "wisp", "llama-app"] {
            #expect(try refusal(#"{"llamacpp":{"server":"\#(value)"}}"#) == nil, "\(value)")
        }
        #expect(try refusal(#"{"llamacpp":{"server":"ollama"}}"#) != nil)
        let studio = try refusal(#"{"lmstudio":{"server":"llama-app"}}"#)
        #expect(studio?.hasPrefix("lmstudio: server is not taken: it is llama.cpp's choice") == true, "\(studio ?? "")")
    }

    @Test func configSetExplainsEachChoice() throws {
        let setting = try #require(ConfigSettings.setting("llamacpp.server"))
        #expect(setting.kind == .choice(["off", "wisp", "llama-app"]))
        for word in ["off", "llama-app", "wisp", "not built yet", "no key"] {
            #expect(setting.summary.contains(word), "\(word)")
        }
        #expect(ConfigSettings.defaultValue("llamacpp.server") == "off")
        let app = try ConfigEdit.set("llamacpp.server", to: "llama-app", in: nil)
        #expect(app.new == "llama-app")
        #expect(app.warning?.contains("no API key and answers any origin") == true, "\(app.warning ?? "")")
        #expect(app.warning?.contains("so wisp connects there") == false)
        let overridden = try ConfigEdit.set(
            "llamacpp.server", to: "llama-app", in: Data(#"{"llamacpp":{"baseURL":"http://h:1"}}"#.utf8))
        #expect(overridden.warning?.contains("so wisp connects there") == true)
        let wisp = try ConfigEdit.set("llamacpp.server", to: "wisp", in: nil)
        #expect(wisp.warning?.contains("not built yet") == true)
        #expect(try ConfigEdit.set("llamacpp.server", to: "off", in: nil).warning == nil)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("llamacpp.server", to: "llamaapp", in: nil) }
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("lmstudio.server", to: "llama-app", in: nil) }
    }

    @Test func aLlamaAppModelNameParsesWithItsQuantisation() throws {
        let selection = try ModelSelection(parsing: "llamacpp:ggml-org/gemma-4-E4B-it-GGUF:Q8_0")
        #expect(selection == .local(backend: "llamacpp", name: "ggml-org/gemma-4-E4B-it-GGUF:Q8_0"))
        #expect(selection.description == "llamacpp:ggml-org/gemma-4-E4B-it-GGUF:Q8_0")
        // The name is the server's id as it is: not a `.gguf` path, so not shortened.
        #expect(
            OpenAICompatibleModel.Served.shortName("ggml-org/gemma-4-E4B-it-GGUF:Q8_0")
                == "ggml-org/gemma-4-E4B-it-GGUF:Q8_0")
    }

    @Test func llamaAppIsFoundByItsBundleIdentifier() throws {
        let real = try Self.bundle(LlamaApp.bundleIdentifier)
        let other = try Self.bundle("com.example.Other")
        let missing = FileManager.default.temporaryDirectory.appending(path: "wisp-none-\(UUID().uuidString)/Llama.app")
        #expect(LlamaApp(candidates: [missing, other, real]).installed == real)
        #expect(LlamaApp(candidates: [missing, other]).installed == nil)
        // The hint follows: start it when installed, say it is not when not.
        #expect(LlamaApp(candidates: [real]).startHint.hasPrefix("start Llama.app"))
        let absent = LlamaApp(candidates: [missing]).startHint
        #expect(
            absent.hasPrefix("Llama.app is not installed (looked in ")
                && absent.contains(missing.deletingLastPathComponent().path))
    }

    @Test func theDoctorSaysWhoseServerAndWarnsOfLlamaAppsOpenServer() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "wisp-none-\(UUID().uuidString)/Llama.app")
        #expect(Doctor.llamaCppServer(Config().resolved.llamacpp, installed: nil, answer: nil) == nil)
        let wisp = try #require(
            Doctor.llamaCppServer(
                Config(llamacpp: .init(server: .wisp)).resolved.llamacpp, installed: nil, answer: nil))
        #expect(!wisp.ok && wisp.detail.contains("not built yet") && wisp.name == "llama.cpp server")
        var settings = Config(llamacpp: .init(server: .llamaApp)).resolved.llamacpp
        settings.llamaApp = LlamaApp(candidates: [missing])
        let running = try #require(
            Doctor.llamaCppServer(settings, installed: URL(filePath: "/Applications/Llama.app"), answer: .listed(1)))
        #expect(running.ok, "\(running.detail)")
        #expect(running.detail.contains("Llama.app at /Applications/Llama.app"))
        #expect(running.detail.contains("http://127.0.0.1:9931 answers, listing 1 model;"), "\(running.detail)")
        #expect(running.detail.contains("warning: Llama.app's server has no API key and answers any origin"))
        // Installed and not running is no failure: it says to start it.
        let stopped = try #require(
            Doctor.llamaCppServer(
                settings, installed: URL(filePath: "/Applications/Llama.app"), answer: .failed("refused")))
        #expect(stopped.ok && stopped.detail.contains("nothing answers at http://127.0.0.1:9931 (refused)"))
        // Neither installed nor answering is.
        let absent = try #require(Doctor.llamaCppServer(settings, installed: nil, answer: .failed("refused")))
        #expect(!absent.ok && absent.detail.contains("Llama.app not installed (looked in "), "\(absent.detail)")
    }

    @Test func theDoctorRunsTheProbeAndPlacesItsFinding() async {
        let probes = Doctor.Probes(
            systemModel: { nil }, configuredModel: { _, _, _ in nil },
            llamaCppServer: { _ in Doctor.Finding(name: "llama.cpp server", ok: true, detail: "probed") })
        let findings = await Doctor(
            home: Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-dr-\(UUID().uuidString)")),
            probes: probes
        ).check()
        let index = findings.firstIndex { $0.name == "llama.cpp server" }
        #expect(index != nil && findings[(index ?? 0) + 1].name == "sandbox")
    }
}

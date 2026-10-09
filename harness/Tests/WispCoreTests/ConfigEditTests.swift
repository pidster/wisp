import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// Changing `config.json` from chat and the command line: values checked per setting, the rest of the
/// file kept, and the edited file loading as it would at start-up (ADR 0040).
@Suite struct ConfigEditTests {
    private func setting(_ path: String) throws -> ConfigSettings.Setting {
        try #require(ConfigSettings.setting(path))
    }

    @Test func valuesAreReadAsEachSettingExpects() throws {
        #expect(try ConfigEdit.value("coreml", for: setting("approval.classifier")) == "coreml")
        #expect(try ConfigEdit.value("off", for: setting("audit.enabled")) == false)
        #expect(try ConfigEdit.value("YES", for: setting("notifications.enabled")) == true)
        #expect(try ConfigEdit.value("0", for: setting("approval.timeoutSeconds")) == 0)
        #expect(try ConfigEdit.value("0.75", for: setting("approval.coremlMinimumConfidence")) == .double(0.75))
        #expect(try ConfigEdit.value("ollama:granite4.1:8b", for: setting("model")) == "ollama:granite4.1:8b")
        #expect(
            try ConfigEdit.value(#"["system", "ollama:qwen3.8:27b"]"#, for: setting("routing.ladder"))
                == ["system", "ollama:qwen3.8:27b"])
        #expect(try ConfigEdit.value("notify, inspect", for: setting("tools.disabled")) == ["notify", "inspect"])
        #expect(try ConfigEdit.value("\"be brief\"", for: setting("systemPromptExtension")) == "be brief")
        let refusals: [(String, String)] = [
            ("approval.classifier", "sometimes"), ("audit.enabled", "maybe"), ("approval.persistDays", "0"),
            ("approval.coremlMinimumConfidence", "2"), ("model", "nonsense:"), ("routing.ladder", "system bad:"),
            ("tools.disabled", "run_command teleport"), ("ollama.baseURL", "  "),
        ]
        for (path, text) in refusals {
            #expect(throws: ConfigEdit.Failure.self, "\(path) \(text)") {
                try ConfigEdit.value(text, for: setting(path))
            }
        }
    }

    @Test func aChangeKeepsTheRestOfTheFileAndMustStillLoad() throws {
        let file = Data(#"{"commandPolicy": {"deny": ["^shutdown"]}, "approval": {"timeoutSeconds": 0}}"#.utf8)
        let set = try ConfigEdit.set("approval.classifier", to: "rules", in: file)
        #expect(set.old == nil && set.new == "rules")
        #expect(set.warning?.hasPrefix("only the rules judge commands") == true)
        let config = try JSONDecoder().decode(Config.self, from: set.data)
        #expect(config.approval?.classifier == .rules && config.approval?.timeoutSeconds == 0)
        #expect(config.commandPolicy?.deny == ["^shutdown"])
        #expect(String(decoding: set.data, as: UTF8.self).hasSuffix("}\n"))
        // Unsetting the last key of an object removes the object.
        let unset = try ConfigEdit.unset("approval.timeoutSeconds", in: set.data)
        #expect(unset.old == 0 && unset.new == nil)
        let cleared = try ConfigEdit.unset("approval.classifier", in: unset.data)
        #expect(try ConfigEdit.object(cleared.data)["approval"] == nil)
        #expect(try ConfigEdit.current("commandPolicy.deny", in: cleared.data) == ["^shutdown"])
        // No file is an empty config.
        #expect(try ConfigEdit.set("model", to: "system", in: nil).new == "system")
    }

    @Test func aModelsOwnWindowIsSetUnderItsWholeName() throws {
        let path = "ollama.models.qwen3.8:27b.contextLength"
        #expect(ConfigSettings.keys(path) == ["ollama", "models", "qwen3.8:27b", "contextLength"])
        #expect(try setting(path).kind == .integer(1024...1_048_576))
        #expect(ConfigSettings.setting("ollama.models..contextLength") == nil)
        #expect(ConfigSettings.defaultValue(path) == "sized per model")
        let file = Data(#"{"mlx": {"models": {"Qwen3-1.7B-4bit": {"capabilities": ["toolCalling"]}}}}"#.utf8)
        let set = try ConfigEdit.set(path, to: "12288", in: file)
        #expect(set.path == path && set.new == 12288)
        let config = try JSONDecoder().decode(Config.self, from: set.data).resolved
        #expect(config.ollama.modelContextLengths == ["qwen3.8:27b": 12288])
        #expect(try ConfigEdit.current(path, in: set.data) == 12288)
        // An MLX model's window sits beside its declaration and keeps it.
        let mlx = try ConfigEdit.set("mlx.models.Qwen3-1.7B-4bit.contextLength", to: "4096", in: set.data)
        let both = try JSONDecoder().decode(Config.self, from: mlx.data).resolved
        #expect(both.mlxModels["Qwen3-1.7B-4bit"] == ["toolCalling"])
        #expect(both.mlxModelContextLengths == ["Qwen3-1.7B-4bit": 4096])
        #expect(
            ConfigSettings.listed(in: mlx.data).suffix(2).map(\.path) == [
                path, "mlx.models.Qwen3-1.7B-4bit.contextLength",
            ])
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set(path, to: "12", in: nil) }
        let unset = try ConfigEdit.unset(path, in: mlx.data)
        #expect(try ConfigEdit.object(unset.data)["ollama"] == nil)
    }

    @Test func refusalsNameTheProblemAndWriteNothing() throws {
        #expect(throws: ConfigEdit.Failure.unknownSetting("approval.clasifier")) {
            try ConfigEdit.set("approval.clasifier", to: "rules", in: nil)
        }
        #expect(throws: ConfigEdit.Failure.unknownSetting("commandPolicy")) {
            try ConfigEdit.unset("commandPolicy", in: nil)
        }
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("model", to: "system", in: Data("[1]".utf8)) }
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("model", to: "system", in: Data("{".utf8)) }
        // A file that would not load, here an invalid policy pattern already in it, is refused.
        let broken = Data(#"{"commandPolicy": {"deny": ["("]}}"#.utf8)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("model", to: "system", in: broken) }
        let described = "\(ConfigEdit.Failure.unknownSetting("x"))"
        #expect(described.hasPrefix("no setting 'x'; the settings are: model, models.disabled, approval.threshold"))
        #expect("\(ConfigEdit.Failure.invalidValue(path: "a", reason: "b"))" == "a: b")
        #expect("\(ConfigEdit.Failure.unreadableFile("x"))".hasPrefix("config.json is not a JSON object"))
        #expect("\(ConfigEdit.Failure.wouldNotLoad("x"))".hasPrefix("the change would leave"))
    }

    @Test func weakeningTheGateOrTheAuditIsWarned() throws {
        #expect(
            try ConfigEdit.set("approval.threshold", to: "never", in: nil).warning?.contains("without asking") == true)
        #expect(try ConfigEdit.set("approval.threshold", to: "dangerous", in: nil).warning != nil)
        #expect(try ConfigEdit.set("approval.threshold", to: "moderate", in: nil).warning == nil)
        #expect(try ConfigEdit.set("audit.enabled", to: "false", in: nil).warning != nil)
        #expect(
            try ConfigEdit.set("approval.classifier", to: "coreml", in: nil).warning?.contains("coremlModel") == true)
        let withModel = Data(#"{"approval": {"coremlModel": "risk.mlmodel"}}"#.utf8)
        #expect(try ConfigEdit.set("approval.classifier", to: "coreml", in: withModel).warning == nil)
    }

    @Test func writingReplacesTheFileReadableByTheOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "config.json")
        try ConfigEdit.write(try ConfigEdit.set("model", to: "system", in: nil), to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(try Config.load(from: url).model == .system)
        let details = AuditEvent.Details.configChange(
            try ConfigEdit.set("model", to: "system", in: nil), source: "chat")
        #expect(Set(details.keys) == AuditEvent.fields(for: .configChange) && details["old"] == .null)
    }

    @Test func chatParsesConfigRequests() {
        #expect(ChatInput(line: "/config") == .config(.show))
        #expect(ChatInput(line: "/config list") == .config(.list))
        #expect(ChatInput(line: "/config set") == .config(.set(path: nil, value: nil)))
        #expect(ChatInput(line: "/config set model") == .config(.set(path: "model", value: nil)))
        #expect(
            ChatInput(line: "/config set routing.ladder system ollama:x")
                == .config(.set(path: "routing.ladder", value: "system ollama:x")))
        #expect(ChatInput(line: "/config unset model") == .config(.unset("model")))
        #expect(ChatInput(line: "/config frob") == .config(.unknown("frob")))
    }

    @Test func aChoiceReadsNumbersValuesAndTypedText() {
        let fixed = ChatChoice(
            title: "pick", options: [.init(value: "rules"), .init(value: "coreml", detail: "fast")], current: "coreml")
        #expect(fixed.answer(typed: "2") == "coreml" && fixed.answer(typed: " rules ") == "rules")
        #expect(
            fixed.answer(typed: "3") == nil && fixed.answer(typed: "other") == nil && fixed.answer(typed: "") == nil)
        #expect(
            fixed.numbered == ["pick", "  1  rules", "* 2  coreml  fast", "type a number, or press Enter to leave it"])
        let open = ChatChoice(title: "value", options: [], acceptsText: true)
        #expect(open.answer(typed: "30") == "30" && open.numbered.last == "type a value, or press Enter to leave it")
        let both = ChatChoice(title: "model", options: [.init(value: "system")], acceptsText: true)
        #expect(both.answer(typed: "1") == "system" && both.answer(typed: "ollama:x") == "ollama:x")
        #expect(both.answer(typed: "/quit") == nil, "a slash command is not an answer")
        #expect(both.numbered.last == "type a number or a value, or press Enter to leave it")
    }

    @Test func everySettingHasADefaultOrSaysItHasNone() {
        for setting in ConfigSettings.all where setting.path != "systemPromptExtension" {
            #expect(ConfigSettings.defaultValue(setting.path) != nil, "\(setting.path)")
        }
        #expect(ConfigSettings.defaultValue("systemPromptExtension") == nil)
        #expect(ConfigSettings.defaultValue("approval.timeoutSeconds") == 600)
        #expect(ConfigSettings.defaultValue("approval.coremlModel") == .string("risk@\(WispVersion.current)-default"))
        #expect(ChatInput(line: "/config get model") == .config(.get("model")))
        #expect(ChatInput(line: "/approvals revoke ab12") == .approvals(.revoke("ab12")))
        #expect(ChatInput(line: "/approvals") == .approvals(.list) && ChatInput(line: "/audit") == .inspect("audit"))
    }
}

import Foundation
import Testing

@testable import WispCore

/// `mlx.trustedPublishers`: the Hugging Face organisations `wisp models pull` fetches from without asking, with
/// `mlx-community` always among them, and the name rule every entry and every pulled repository keeps (ADR 0052,
/// amended 2026-10-09).
@Suite struct TrustedPublishersTests {
    @Test func theNameRuleIsHuggingFaces() {
        for name in [
            "mlx-community", "ornith-ai", "Qwen", "a", "x_1", "_x", "a.b", "a-b_c.d", String(repeating: "a", count: 96),
        ] {
            #expect(TrustedPublishers.isHubName(name), "\(name)")
        }
        for name in [
            "", "..", ".", ".x", "x.", "-x", "x-", "a--b", "a..b", "a/b", "a b", "~", "a\u{1b}", "é",
            String(repeating: "a", count: 97),
        ] {
            #expect(!TrustedPublishers.isHubName(name), "\(name)")
        }
    }

    @Test func mlxCommunityIsAlwaysTrustedAndTheListAddsToIt() {
        #expect(Config().resolved.mlxTrustedPublishers == ["mlx-community"])
        #expect(TrustedPublishers.resolve(nil) == ["mlx-community"])
        #expect(TrustedPublishers.resolve([]) == ["mlx-community"])
        #expect(
            TrustedPublishers.resolve(["ornith-ai", "mlx-community", "ornith-ai"]) == ["mlx-community", "ornith-ai"])
        // An entry Hugging Face would not accept could never match a pulled repository, and is left out.
        #expect(TrustedPublishers.resolve(["../x", "ok"]) == ["mlx-community", "ok"])
        let config = Config(mlx: Config.MLXConfig(trustedPublishers: ["ornith-ai"])).resolved
        #expect(TrustedPublishers.trusts("mlx-community", config: config))
        #expect(TrustedPublishers.trusts("ornith-ai", config: config))
        // Compared exactly: another spelling is asked about.
        #expect(!TrustedPublishers.trusts("Ornith-AI", config: config))
        #expect(!TrustedPublishers.trusts("someone", config: config))
    }

    @Test func theSettingTakesOrganisationNamesOnly() throws {
        let setting = try #require(ConfigSettings.setting("mlx.trustedPublishers"))
        #expect(setting.kind == .publishers)
        #expect(ConfigSettings.defaultValue("mlx.trustedPublishers") == ["mlx-community"])
        #expect(try ConfigEdit.value("mlx-community, ornith-ai", for: setting) == ["mlx-community", "ornith-ai"])
        #expect(try ConfigEdit.value(#"["ornith-ai","ornith-ai"]"#, for: setting) == ["ornith-ai"])
        for refused in ["../x", "a--b", "ornith-ai/model", "https://huggingface.co/x", ".hidden"] {
            #expect(throws: ConfigEdit.Failure.self, "\(refused)") { try ConfigEdit.value(refused, for: setting) }
        }
        let set = try ConfigEdit.set("mlx.trustedPublishers", to: "ornith-ai", in: nil)
        let config = try JSONDecoder().decode(Config.self, from: set.data)
        #expect(config.mlx?.trustedPublishers == ["ornith-ai"])
        #expect(config.resolved.mlxTrustedPublishers == ["mlx-community", "ornith-ai"])
    }
}

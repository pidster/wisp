import Foundation
import Synchronization
import Testing

@testable import WispCore

/// `Wisp.app`'s window (ADR 0091), driven through scripted services and prompts: no AppKit, no network, no model.
@MainActor @Suite struct AppPanelTests {
    /// What the scripted services and prompts saw and answer.
    @MainActor final class Script {
        /// The calls made, in order.
        var calls: [String] = []
        /// The releases GitHub "lists", or the failure.
        var releases: [AppUpdate.Published] = []
        /// The failure a listing reports.
        var failure: String?
        /// Whether a check is due when the window opens.
        var due = false
        /// The models listed.
        var entries: [ModelListing.Entry] = [
            .init(selection: .system, capabilities: ["toolCalling"]),
            .init(
                selection: .local(backend: "ollama", name: "granite4.2:8b"), parameters: "8B", bytes: 5_350_000_000,
                format: "granite Q4_K_M", capabilities: ["toolCalling"]),
            .init(
                selection: .local(backend: "mlx", name: "Qwen3-4B-4bit"), problem: "no chat template", enabled: false),
        ]
        /// The backends that could not be asked.
        var unreachable: [String] = []
        /// What `confirm` answers.
        var confirms = true
        /// What `typed` answers.
        var typed: String? = "ollama:granite4.2:8b"
        /// What `publisher` answers.
        var publisher = PublisherCheck.Answer.once
        /// The questions put, as headline and text.
        var asked: [String] = []
        /// What a service throws, by its call's name.
        var throwing: [String: String] = [:]

        /// The services, recording each call.
        func services(source: AppInstall.Source = .app(URL(filePath: "/Applications/Wisp.app"))) -> AppPanel.Services {
            AppPanel.Services(
                welcome: { AppInstall.Welcome(title: "Wisp is a command-line tool", text: "t", offersInstall: true) },
                install: {
                    self.calls.append("install")
                    return ["linked wisp"]
                },
                releases: {
                    self.calls.append("releases")
                    return (self.releases, self.failure)
                },
                lastCheck: { nil },
                checkIsDue: { self.due },
                update: { release in
                    self.calls.append("update \(release.version)")
                    return ("Wisp is updated to \(release.version)", "done")
                },
                source: source,
                models: {
                    self.calls.append("models")
                    return ModelListing.Listing(entries: self.entries, unreachable: self.unreachable)
                },
                setEnabled: { name, on, say in
                    self.calls.append("\(on ? "enable" : "disable") \(name)")
                    say("turned \(name) \(on ? "on" : "off")")
                    if let failure = self.throwing["set"] { throw ConfigEdit.Failure.unknownSetting(failure) }
                },
                check: { name, say in
                    self.calls.append("check \(name)")
                    say("checked \(name)")
                },
                uninstall: { name, dialog in
                    self.calls.append("uninstall \(name)")
                    dialog.show("uninstalling \(name) removes:")
                    let answer = await dialog.typed("Type \(name) to remove it; anything else leaves it")
                    return answer == name
                },
                pull: { text, dialog in
                    self.calls.append("pull \(text)")
                    let answer = await dialog.publisher(
                        PullSummary(
                            repository: text, name: "Model-4bit", revision: "0123456789ab", licence: "mit", files: 2,
                            bytes: 10, missing: 2, remaining: 10, destination: "/models/Model-4bit",
                            snapshot: "/hub/Model-4bit", replacesDirectory: false, reused: 0, seeded: 0, lines: []))
                    guard answer != .refuse, await dialog.confirm("Fetch 2 of them, 10 bytes?") else {
                        return PullResult(outcome: .declined, repository: text, selection: "mlx:x", fetched: 0)
                    }
                    return PullResult(
                        outcome: .fetched, repository: text, selection: "mlx:x", fetched: 10, closing: "it is mlx:x")
                },
                add: { file in
                    self.calls.append("add \(file.lastPathComponent)")
                    return ["linked \(file.lastPathComponent)"]
                })
        }

        /// The prompts, recording each question.
        var prompts: AppPanel.Prompts {
            AppPanel.Prompts(
                confirm: { title, text, _ in
                    self.asked.append("\(title) | \(text)")
                    return self.confirms
                },
                typed: { title, text in
                    self.asked.append("\(title) | \(text)")
                    return self.typed
                },
                publisher: { lines in
                    self.asked.append(lines.first ?? "")
                    return self.publisher
                },
                file: { URL(filePath: "/tmp/Model-Q4_K_M.gguf") },
                tell: { title, text in self.asked.append("\(title) | \(text)") })
        }
    }

    /// Three releases, the newest with a disk image.
    static let releases: [AppUpdate.Published] = [
        .init(
            release: .init(
                version: "0.35.4", image: URL(string: "https://example.com/Wisp-0.35.4.dmg"),
                checksum: URL(string: "https://example.com/Wisp-0.35.4.dmg.sha256"), page: nil),
            notes: "- one"),
        .init(release: .init(version: "0.35.3", image: nil, checksum: nil, page: nil)),
        .init(release: .init(version: "0.35.2", image: nil, checksum: nil, page: nil)),
    ]

    @Test func openingListsTheModelsAndChecksOnlyWhenADailyCheckIsDue() async {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts, version: "0.35.3")
        await panel.start()
        #expect(script.calls == ["models"])
        #expect(panel.models.map(\.name) == ["system", "ollama:granite4.2:8b", "mlx:Qwen3-4B-4bit"])
        #expect(panel.models[1].detail == "8B · granite Q4_K_M · 5.35 GB · Uses tools" && panel.models[1].removable)
        #expect(!panel.models[0].removable && !panel.models[2].enabled && panel.models[2].problem != nil)
        guard case .idle(let text) = panel.update else { Issue.record("not idle"); return }
        #expect(text == "Not checked yet.")
        script.due = true
        script.releases = Self.releases
        await AppPanel(services: script.services(), prompts: script.prompts, version: "0.35.3").start()
        #expect(script.calls == ["models", "releases", "models"])
    }

    @Test func installLinksAndSaysSo() {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        panel.install()
        #expect(script.calls == ["install"] && panel.installNote == "linked wisp")
    }

    @Test func checkingListsTheReleasesAndOnlyTheNewestIsInstalled() async throws {
        let script = Script()
        script.releases = Self.releases
        let panel = AppPanel(services: script.services(), prompts: script.prompts, version: "0.35.3")
        await panel.checkForUpdates()
        guard case .listed(let listed, let advice, let installable) = panel.update else {
            Issue.record("not listed: \(panel.update)")
            return
        }
        #expect(listed.count == 3 && installable?.version == "0.35.4")
        #expect(advice.hasPrefix("Wisp 0.35.4 is newer than this one, 0.35.3. Update installs it"))
        script.confirms = false
        await panel.installUpdate()
        #expect(!script.calls.contains("update 0.35.4"))
        script.confirms = true
        await panel.installUpdate()
        #expect(script.calls.last == "update 0.35.4")
        #expect(script.asked.last == "Wisp is updated to 0.35.4 | done")
    }

    @Test func nothingIsInstallableWhenThisIsTheNewestOrCannotUpdateItself() async {
        let script = Script()
        script.releases = Self.releases
        let latest = AppPanel(services: script.services(), prompts: script.prompts, version: "0.35.4")
        await latest.checkForUpdates()
        #expect(
            latest.update == .listed(Self.releases, advice: "This is the latest release, 0.35.4.", installable: nil))
        let build = AppPanel(services: script.services(source: .elsewhere), prompts: script.prompts, version: "0.35.3")
        await build.checkForUpdates()
        guard case .listed(_, let advice, nil) = build.update else {
            Issue.record("installable from a build")
            return
        }
        #expect(advice.contains("cannot update itself"))
        await build.installUpdate()
        #expect(!script.calls.contains { $0.hasPrefix("update") })
        script.failure = "cannot reach GitHub: offline"
        await build.checkForUpdates()
        #expect(build.update == .failed("GitHub could not be asked: cannot reach GitHub: offline."))
    }

    @Test func modelActionsGoThroughTheServicesAndListAgain() async throws {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        await panel.refreshModels()
        let granite = try #require(panel.models.first { $0.name == "ollama:granite4.2:8b" })
        await panel.toggle(granite)
        await panel.check(try #require(panel.models.last))
        #expect(
            script.calls == ["models", "disable ollama:granite4.2:8b", "models", "check mlx:Qwen3-4B-4bit", "models"])
        #expect(
            panel.log.contains("turned ollama:granite4.2:8b off") && panel.log.contains("checked mlx:Qwen3-4B-4bit"))
        #expect(panel.busy == nil)
        script.throwing["set"] = "x"
        await panel.toggle(granite)
        #expect(panel.log.last?.hasPrefix("Error: ") == true)
        #expect(script.asked.last?.hasPrefix("The Action Couldn’t Be Completed") == true)
    }

    @Test func uninstallAsksForTheNameWithThePlan() async throws {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        await panel.refreshModels()
        await panel.uninstall(try #require(panel.models.first { $0.removable }))
        let question = try #require(script.asked.last)
        #expect(question.hasPrefix("Uninstall ollama:granite4.2:8b? | uninstalling ollama:granite4.2:8b removes:"))
        #expect(question.hasSuffix("Type ollama:granite4.2:8b to remove it; anything else leaves it."))
        #expect(script.calls.contains("uninstall ollama:granite4.2:8b"))
    }

    @Test func aPullPutsThePublisherQuestionThenTheDownload() async {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        await panel.pull("  ")
        #expect(script.calls.isEmpty)
        await panel.pull("someone/Model-4bit")
        #expect(
            script.asked == [
                "someone is not a trusted publisher (\(TrustedPublishers.setting)).",
                "Pull someone/Model-4bit? | Fetch 2 of them, 10 bytes?",
            ])
        #expect(panel.log.contains("it is mlx:x") && !panel.canStop && panel.progress == nil)
        script.publisher = .refuse
        script.asked = []
        await panel.pull("someone/Model-4bit")
        #expect(script.asked.count == 1 && panel.log.last == "Pulling someone/Model-4bit…")
    }

    @Test func addLinksTheChosenFile() async {
        let script = Script()
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        await panel.add()
        #expect(script.calls.first == "add Model-Q4_K_M.gguf" && panel.log.contains("linked Model-Q4_K_M.gguf"))
    }

    @Test func theIdleTextSaysWhatTheDailyCheckFound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = AppPanel.idleText(.init(checkedAt: now, latest: "0.36.0"), current: "0.35.3")
        #expect(newer == "Last checked 2027-01-15: Wisp 0.36.0 is available.")
        #expect(
            AppPanel.idleText(.init(checkedAt: now, latest: "0.35.3"), current: "0.35.3")
                == "Last checked 2027-01-15: up to date.")
        #expect(
            AppPanel.idleText(.init(checkedAt: now, latest: nil, failure: "x"), current: "0.35.3") == "Not checked yet."
        )
        #expect(AppPanel.idleText(nil, current: "0.35.3") == "Not checked yet.")
    }

    @Test func aBackendThatCouldNotBeAskedIsSaidUnderTheList() async {
        let script = Script()
        script.unreachable = [
            "ollama: no Ollama server at http://127.0.0.1:11434: Could not connect to the server."
        ]
        let panel = AppPanel(services: script.services(), prompts: script.prompts)
        await panel.refreshModels()
        #expect(panel.unreachable == ["No Ollama server at http://127.0.0.1:11434: Could not connect to the server."])
        #expect(AppPanel.unreachableNote("odd line with no scheme") == "Odd line with no scheme")
    }
}

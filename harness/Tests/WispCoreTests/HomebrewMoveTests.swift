import Foundation
import Testing

@testable import WispCore

/// The move from Homebrew's formula to its cask (ADR 0084): what Homebrew holds of wisp, the doctor's `install`
/// finding, what `wisp update` says from the formula, and `wisp install` finding the cask's links.
@Suite struct HomebrewMoveTests {
    private let app = URL(filePath: "/Applications/Wisp.app")

    @Test func theCommandsTrustThenUninstallThenInstall() {
        #expect(
            HomebrewMove.line
                == "brew trust pidster/tap && brew uninstall --formula wisp && "
                + "brew install --cask pidster/tap/wisp")
    }

    @Test func readsTheCaskTheKegAndTheWispOnPath() {
        let present: Set<String> = ["/opt/homebrew/Caskroom/wisp", "/opt/homebrew/Cellar/wisp"]
        let reading = HomebrewMove.read(
            environment: ["PATH": "/nowhere:/opt/homebrew/bin"], exists: { present.contains($0.path) },
            executable: { $0.path == "/opt/homebrew/bin/wisp" })
        #expect(reading.cask && reading.keg && reading.onPath?.path.hasSuffix("/opt/homebrew/bin/wisp") == true)
        // HOMEBREW_PREFIX moves where the Caskroom and Cellar are looked for; no wisp on PATH is nil.
        let elsewhere = HomebrewMove.read(
            environment: ["HOMEBREW_PREFIX": "/usr/local", "PATH": "/nowhere"], exists: { present.contains($0.path) },
            executable: { _ in false })
        #expect(elsewhere == HomebrewMove())
        #expect(HomebrewMove(onPath: URL(filePath: "/opt/homebrew/Cellar/wisp/0.34.1/libexec/wisp")).formulaOnPath)
        #expect(!HomebrewMove(onPath: app.appending(path: "Contents/MacOS/wisp")).formulaOnPath)
    }

    /// The doctor's finding for `layout` and `homebrew`.
    private func finding(_ layout: PackageLayout.Reading, _ homebrew: HomebrewMove = HomebrewMove()) -> Doctor.Finding {
        let home = Home(root: FileManager.default.temporaryDirectory.appending(path: "wisp-move-\(UUID().uuidString)"))
        return Doctor(
            home: home, model: .system,
            probes: .init(
                systemModel: { nil }, configuredModel: { _, _, _ in nil }, layout: { layout }, homebrew: { homebrew })
        ).install()
    }

    @Test func theDoctorNamesTheInstallAndAnUnfinishedMove() {
        let manifest = URL(filePath: "/opt/homebrew/Cellar/wisp/0.34.2/libexec/wisp-layout.json")
        let formula = finding(.declared(PackageLayout(declaration: .manifest(manifest), parts: [:])))
        #expect(!formula.ok && formula.detail.contains("ends at 0.34.2") && formula.detail.hasSuffix(HomebrewMove.line))
        let appLayout = PackageLayout.Reading.declared(PackageLayout(declaration: .app(app), parts: [:]))
        #expect(finding(appLayout) == .init(name: "install", ok: true, detail: "Wisp.app at /Applications/Wisp.app"))
        let cask = finding(appLayout, HomebrewMove(cask: true))
        #expect(cask.ok && cask.detail == "Wisp.app at /Applications/Wisp.app, installed by Homebrew's cask")
        // The keg the move leaves behind is named for removal; the finding still passes.
        let left = finding(
            appLayout, HomebrewMove(cask: true, keg: true, onPath: app.appending(path: "Contents/MacOS/wisp")))
        #expect(left.ok && left.detail.hasSuffix("remove it with brew uninstall --formula --force wisp"))
        // The formula's wisp still first on PATH fails: with the cask installed without its links, reinstall it.
        let old = URL(filePath: "/opt/homebrew/Cellar/wisp/0.34.1/libexec/wisp")
        let unlinked = finding(appLayout, HomebrewMove(cask: true, keg: true, onPath: old))
        #expect(
            !unlinked.ok
                && unlinked.detail.hasSuffix(
                    "brew uninstall --formula wisp && brew reinstall --cask pidster/tap/wisp")
        )
        let dragged = finding(appLayout, HomebrewMove(keg: true, onPath: old))
        #expect(!dragged.ok && dragged.detail.contains(old.path) && dragged.detail.hasSuffix(HomebrewMove.line))
        #expect(finding(.none).ok)
    }

    @Test func theFormulaSaysHowToMove() {
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.app(of: .homebrew) }
        do {
            _ = try AppUpdate.app(of: .homebrew)
        } catch {
            #expect("\(error)".hasSuffix("Move to it: \(HomebrewMove.line)"))
        }
    }

    @Test func installFindsTheCasksLinksOnPath() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let folder = URL(filePath: "/Users/someone/.local/bin")
        let brew = "/opt/homebrew/bin"
        let linked: (URL) -> AppInstall.Existing = { link in
            link.path.hasPrefix(brew + "/") ? .link(app.path + "/Contents/MacOS/" + link.lastPathComponent) : .nothing
        }
        let found = AppInstall.linkedElsewhere(
            app: app, folder: folder, path: "/usr/bin:\(brew):\(folder.path)", existing: linked)
        #expect(found?.path == brew)
        // The folder install would link into does not count, nor does a folder linking only one of them.
        #expect(AppInstall.linkedElsewhere(app: app, folder: URL(filePath: brew), path: brew, existing: linked) == nil)
        let one: (URL) -> AppInstall.Existing = { link in
            link.lastPathComponent == "wisp" ? .link(app.path + "/Contents/MacOS/wisp") : .nothing
        }
        #expect(AppInstall.linkedElsewhere(app: app, folder: folder, path: brew, existing: one) == nil)
        let welcome = AppInstall.welcome(source: .app(app), folder: folder, home: home, linked: found) { _ in .nothing }
        #expect(!welcome.offersInstall && welcome.text.contains("installed in /opt/homebrew/bin, as Homebrew's cask"))
        #expect(
            AppInstall.alreadyLinked(URL(filePath: brew), app: app, home: home)
                == "wisp and wisp-tui are already on PATH: /opt/homebrew/bin links them to /Applications/Wisp.app, "
                + "as Homebrew's cask does; nothing to add")
        #expect(AppInstall.Source.app(app).app == app && AppInstall.Source.homebrew.app == nil)
    }

    @Test func theDoctorSendsACopyRunWhereItWasDownloadedToApplications() {
        let moved = URL(filePath: "/private/var/folders/x/AppTranslocation/ABC/d/Wisp.app")
        let found = finding(.declared(PackageLayout(declaration: .app(moved), parts: [:])))
        #expect(!found.ok && found.detail.hasPrefix("Wisp.app at \(moved.path): "))
        #expect(found.detail.count > "Wisp.app at \(moved.path): ".count)
    }

    @Test func aRouterJobWhoseWispIsGoneIsNamedAndReplaced() {
        let path = "/Users/someone/Library/LaunchAgents/\(LlamaCppAgent.plistName)"
        let abandoned = LlamaCppAgent.State.abandoned(path)
        #expect(abandoned.text.hasPrefix("left by the LaunchAgent file \(path), whose wisp no longer exists"))
        #expect(abandoned.text.hasSuffix("replaces it with Wisp.app's Login Item"))
        // Turning the server on says what it replaces, then registers this wisp's job.
        let agent = FakeAgent(state: abandoned)
        var said: [String] = []
        let ok = LlamaCppAgent.follow(
            .server, server: .wisp, control: agent, audit: nil, source: "cli", say: { said.append($0) })
        #expect(ok && agent.calls == ["register"], "\(said)")
        #expect(said.first == "wisp's llama.cpp server was left by \(path), whose wisp no longer exists; replacing it")
        // The doctor's line for a server that does not answer names the state.
        let binary = Result<LlamaCppServerBinary.Approved, LlamaCppServerBinary.Refusal>.success(
            .init(
                executable: URL(filePath: "/b"), sha256: "ab",
                approval: .init(path: "/b", resolved: "/b", sha256: "ab", approved: Date())))
        let diagnosis = LlamaCppRouter.diagnosis(
            binary: binary, agent: abandoned, keyExists: true, settings: .defaults,
            log: URL(filePath: "/L/llamacpp.log"), detail: nil)
        #expect(diagnosis.hasSuffix("its LaunchAgent is \(abandoned.text)"), "\(diagnosis)")
    }

    @Test func aFileThatCannotBeRemovedIsAFileFailure() {
        struct Locked: Error {}
        let path = "/L/\(LlamaCppAgent.plistName)"
        let files = LlamaCppAgent.AbandonedFiles(
            program: { _ in "/gone/wisp" }, exists: { _ in false }, remove: { _ in throw Locked() })
        #expect(throws: LlamaCppAgent.Failure.self) {
            try files.removeIfAbandoned("x = {\n\tpath = \(path)\n\tstate = not running\n}")
        }
    }
}

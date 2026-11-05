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
    }
}

import Foundation
import Testing

@testable import WispCore

/// `wisp install` and `uninstall` (ADR 0073): where they may run, what they link and refuse, `PATH`'s advice, and the
/// Finder dialog, against folders under the temporary directory.
@Suite struct AppInstallTests {
    /// A scratch folder holding a fake `Wisp.app` and a `bin` to link into.
    private struct Scratch {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-install-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        var app: URL { root.appending(path: "Wisp.app") }
        var bin: URL { root.appending(path: "bin") }
        var other: URL { root.appending(path: "Other.app") }

        init() throws {
            for name in AppInstall.names {
                for bundle in [app, other] {
                    let folder = bundle.appending(path: "Contents/MacOS")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data().write(to: folder.appending(path: name))
                }
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func link(_ name: String) -> String? {
            try? FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: name).path)
        }
    }

    @Test func onlyAnAppOffTheDiskImageInstalls() {
        let app = URL(filePath: "/Applications/Wisp.app")
        let declared = PackageLayout.Reading.declared(PackageLayout(declaration: .app(app), parts: [:]))
        #expect(AppInstall.source(of: declared) { _ in false } == .app(app))
        #expect(AppInstall.source(of: declared) { _ in true } == .diskImage(app))
        let moved = URL(filePath: "/private/var/folders/x/AppTranslocation/1234/d/Wisp.app")
        let translocated = PackageLayout.Reading.declared(PackageLayout(declaration: .app(moved), parts: [:]))
        #expect(AppInstall.source(of: translocated) { _ in false } == .translocated(moved))
        let formula = PackageLayout.Reading.declared(
            PackageLayout(declaration: .manifest(URL(filePath: "/opt/homebrew/libexec/wisp-layout.json")), parts: [:]))
        #expect(AppInstall.source(of: formula) { _ in false } == .homebrew)
        #expect(AppInstall.source(of: .none) { _ in false } == .elsewhere)
        #expect(AppInstall.Source.app(app).refusal == nil)
        #expect(AppInstall.Source.homebrew.refusal?.contains("Homebrew") == true)
        #expect(AppInstall.Source.diskImage(app).refusal?.contains("drag it to Applications") == true)
    }

    @Test func theFolderDefaultsToLocalBin() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(AppInstall.folder(nil, home: home).path == "/Users/someone/.local/bin")
        #expect(AppInstall.folder("~/bin", home: home).path == "/Users/someone/bin")
        #expect(AppInstall.folder("/opt/tools/", home: home).path == "/opt/tools")
    }

    @Test func installsLinksAndIsIdempotent() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let report = try AppInstall.install(app: scratch.app, folder: scratch.bin, force: false, home: scratch.root)
        #expect(report.changed)
        #expect(report.lines.count == 2 && report.lines.allSatisfy { $0.hasPrefix("linked ~/bin/") })
        #expect(scratch.link("wisp") == scratch.app.appending(path: "Contents/MacOS/wisp").path)
        #expect(scratch.link("wisp-tui") == scratch.app.appending(path: "Contents/MacOS/wisp-tui").path)
        let again = try AppInstall.install(app: scratch.app, folder: scratch.bin, force: false, home: scratch.root)
        #expect(!again.changed && again.lines.allSatisfy { $0.contains("already links") })
    }

    /// A file is never replaced, a link elsewhere only under `--force`, and a blocked install changes nothing.
    @Test func refusesWhatIsInTheWay() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(at: scratch.bin, withIntermediateDirectories: true)
        let elsewhere = scratch.other.appending(path: "Contents/MacOS/wisp").path
        try FileManager.default.createSymbolicLink(
            atPath: scratch.bin.appending(path: "wisp").path, withDestinationPath: elsewhere)
        #expect(throws: AppInstall.Failure.self) {
            try AppInstall.install(app: scratch.app, folder: scratch.bin, force: false, home: scratch.root)
        }
        #expect(scratch.link("wisp") == elsewhere && scratch.link("wisp-tui") == nil)
        let forced = try AppInstall.install(app: scratch.app, folder: scratch.bin, force: true, home: scratch.root)
        #expect(forced.lines[0] == "~/bin/wisp now links to \(scratch.app.path)/Contents/MacOS/wisp, not \(elsewhere)")
        #expect(scratch.link("wisp") == scratch.app.appending(path: "Contents/MacOS/wisp").path)

        try FileManager.default.removeItem(at: scratch.bin.appending(path: "wisp-tui"))
        try Data("mine".utf8).write(to: scratch.bin.appending(path: "wisp-tui"))
        do {
            _ = try AppInstall.install(app: scratch.app, folder: scratch.bin, force: true, home: scratch.root)
            Issue.record("a file was replaced")
        } catch let failure as AppInstall.Failure {
            #expect("\(failure)".contains("~/bin/wisp-tui is a file wisp did not make"))
        }
        #expect(try Data(contentsOf: scratch.bin.appending(path: "wisp-tui")) == Data("mine".utf8))
    }

    @Test func uninstallRemovesOnlyLinksIntoTheApp() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        #expect(
            try AppInstall.uninstall(app: scratch.app, folder: scratch.bin, home: scratch.root)
                == ["no ~/bin/wisp", "no ~/bin/wisp-tui"])
        _ = try AppInstall.install(app: scratch.app, folder: scratch.bin, force: false, home: scratch.root)
        try FileManager.default.removeItem(at: scratch.bin.appending(path: "wisp-tui"))
        let elsewhere = scratch.other.appending(path: "Contents/MacOS/wisp-tui").path
        try FileManager.default.createSymbolicLink(
            atPath: scratch.bin.appending(path: "wisp-tui").path, withDestinationPath: elsewhere)
        let lines = try AppInstall.uninstall(app: scratch.app, folder: scratch.bin, home: scratch.root)
        #expect(lines[0] == "removed ~/bin/wisp")
        #expect(lines[1] == "left ~/bin/wisp-tui: it links to \(elsewhere), not into \(scratch.app.path)")
        #expect(scratch.link("wisp") == nil && scratch.link("wisp-tui") == elsewhere)
        // A relative link into the app is still the app's.
        try FileManager.default.createSymbolicLink(
            atPath: scratch.bin.appending(path: "wisp").path, withDestinationPath: "../Wisp.app/Contents/MacOS/wisp")
        #expect(
            try AppInstall.uninstall(app: scratch.app, folder: scratch.bin, home: scratch.root)[0]
                == "removed ~/bin/wisp")
    }

    @Test func saysWhenTheFolderIsOffPath() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let folder = URL(filePath: "/Users/someone/.local/bin")
        #expect(AppInstall.isOnPath(folder, path: "/usr/bin:/Users/someone/.local/bin/"))
        #expect(!AppInstall.isOnPath(folder, path: "/usr/bin:/bin"))
        #expect(!AppInstall.isOnPath(folder, path: nil))
        #expect(
            AppInstall.pathAdvice(folder, shell: .zsh, home: home) == [
                "~/.local/bin is not on PATH; add this line to ~/.zshrc, then open a new terminal:",
                "  export PATH=\"$HOME/.local/bin:$PATH\"",
            ])
        #expect(AppInstall.pathAdvice(folder, shell: .fish, home: home)[1] == "  fish_add_path $HOME/.local/bin")
        #expect(AppInstall.pathAdvice(folder, shell: .bash, home: home)[0].contains("~/.bash_profile"))
        #expect(AppInstall.pathAdvice(folder, shell: nil, home: home, known: false)[0].hasPrefix("If a new terminal"))
    }

    @Test func knowsAFinderLaunch() {
        func launch(_ arguments: [String], terminal: Bool = false, parent: Int32 = 1, inApp: Bool = true) -> Bool {
            AppInstall.isFinderLaunch(arguments: arguments, stdinIsTerminal: terminal, parent: parent, inApp: inApp)
        }
        #expect(launch(["wisp"]))
        #expect(launch(["wisp", "-psn_0_12345"]))
        #expect(!launch(["wisp", "doctor"]))
        #expect(!launch(["wisp"], terminal: true))
        #expect(!launch(["wisp"], parent: 4242))
        #expect(!launch(["wisp"], inApp: false))
    }

    @Test func theFinderDialogSaysWhatInstallWouldDo() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let app = URL(filePath: "/Applications/Wisp.app")
        let folder = URL(filePath: "/Users/someone/.local/bin")
        func welcome(_ found: AppInstall.Existing, source: AppInstall.Source? = nil) -> AppInstall.Welcome {
            AppInstall.welcome(source: source ?? .app(app), folder: folder, home: home) { link in
                if case .link = found { return .link(app.path + "/Contents/MacOS/" + link.lastPathComponent) }
                return found
            }
        }
        let fresh = welcome(.nothing)
        #expect(fresh.offersInstall && fresh.text.contains("~/.local/bin"))
        let installed = welcome(.link(""))
        #expect(!installed.offersInstall && installed.text.contains("are installed in ~/.local/bin"))
        let file = welcome(.file)
        #expect(!file.offersInstall && file.text.contains("wisp install to see what"))
        let disk = welcome(.nothing, source: .diskImage(app))
        #expect(!disk.offersInstall && disk.text.contains("drag it to Applications"))
        let other = AppInstall.welcome(source: .app(app), folder: folder, home: home) { _ in .link("/opt/x/wisp") }
        #expect(!other.offersInstall && other.text.contains("install --force"))
    }
}

/// Putting wisp on `PATH` is the person's (ADR 0073); the model may still install its shell completions.
@Suite struct AppInstallPolicyTests {
    @Test func theDefaultPolicyRefusesTheModelInstallingWisp() {
        let policy = CommandPolicy()
        #expect(policy.check("wisp install") != .allowed)
        #expect(policy.check("/Applications/Wisp.app/Contents/MacOS/wisp install --force") != .allowed)
        #expect(policy.check("true && wisp uninstall ~/bin") != .allowed)
        #expect(policy.check("wisp completions install zsh") == .allowed)
        #expect(policy.check("wisp doctor") == .allowed)
    }
}

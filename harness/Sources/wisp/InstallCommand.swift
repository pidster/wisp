import AppKit
import ArgumentParser
import Darwin
import Foundation
import WispCore

/// `wisp install`: links `Wisp.app`'s `wisp` and `wisp-tui` into a folder on `PATH` (`AppInstall`,
/// [ADR 0073](../../../docs/decisions/0073-wisp-install-and-the-finder.md)). Neither reads nor writes `~/.wisp`.
struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Link Wisp.app's wisp and wisp-tui into ~/.local/bin, or a folder you name.",
        discussion:
            "Run from Wisp.app: /Applications/Wisp.app/Contents/MacOS/wisp install. It makes the folder if need be, "
            + "needs no administrator's password, and says when the folder is not on PATH and what line to add; "
            + "shell start-up files are never edited. A file already there is never replaced, and a link to another "
            + "wisp only with --force. A Homebrew install puts wisp on PATH itself and is refused.")

    @Argument(help: "The folder to link into; ~/.local/bin when omitted.", completion: .directory)
    var folder: String?

    @Flag(help: "Replace a link to another wisp (never a file).")
    var force = false

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let home = ShellCompletions.home(environment: environment)
        let folder = AppInstall.folder(folder, home: home)
        let report: AppInstall.Report
        do {
            report = try AppInstall.install(app: try InstallCommand.app(), folder: folder, force: force, home: home)
        } catch let failure as AppInstall.Failure {
            FileHandle.standardError.write(Data("Error: \(failure)\n".utf8))
            throw ExitCode.failure
        }
        for line in report.lines { print(line) }
        if !AppInstall.isOnPath(folder, path: environment["PATH"]) {
            let shell = ShellCompletions.detect(shellPath: environment["SHELL"])
            for line in AppInstall.pathAdvice(folder, shell: shell, home: home) { print(line) }
        }
    }

    /// The running `Wisp.app`.
    ///
    /// - Throws: `AppInstall.Failure.refused` when `wisp` is not running from one it may link.
    static func app() throws -> URL {
        let source = AppInstall.source(of: PackageLayout.current)
        guard case .app(let app) = source else { throw AppInstall.Failure.refused(source.refusal ?? "") }
        return app
    }
}

/// `wisp uninstall`: removes the links `wisp install` made, by where they point.
struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the links to Wisp.app's wisp and wisp-tui from ~/.local/bin, or a folder you name.",
        discussion:
            "Removes wisp and wisp-tui from the folder only when they are links into the Wisp.app it runs from, and "
            + "names anything else it leaves. It does not remove Wisp.app (drag it to the Bin) or ~/.wisp.")

    @Argument(help: "The folder the links are in; ~/.local/bin when omitted.", completion: .directory)
    var folder: String?

    func run() throws {
        let home = ShellCompletions.home(environment: ProcessInfo.processInfo.environment)
        do {
            let lines = try AppInstall.uninstall(
                app: try InstallCommand.app(), folder: AppInstall.folder(folder, home: home), home: home)
            for line in lines { print(line) }
        } catch let failure as AppInstall.Failure {
            FileHandle.standardError.write(Data("Error: \(failure)\n".utf8))
            throw ExitCode.failure
        }
    }
}

/// What `Wisp.app` does when opened from the Finder, with no terminal: a dialog that offers to install
/// (`AppInstall.welcome`), and the result of doing so.
enum FinderLaunch {
    /// Whether this process was opened from the Finder.
    static var isCurrent: Bool {
        AppInstall.isFinderLaunch(
            arguments: CommandLine.arguments, stdinIsTerminal: isatty(STDIN_FILENO) != 0, parent: getppid(),
            inApp: PackageLayout.current.layout?.app != nil)
    }

    /// Shows the dialog, installs on the person's word, and shows what was done.
    @MainActor static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate()
        let environment = ProcessInfo.processInfo.environment
        let home = ShellCompletions.home(environment: environment)
        let folder = AppInstall.folder(nil, home: home)
        let source = AppInstall.source(of: PackageLayout.current)
        let welcome = AppInstall.welcome(source: source, folder: folder, home: home)
        let answer = alert(
            welcome.title, welcome.text, buttons: welcome.offersInstall ? ["Install", "Cancel"] : ["OK"]
        )
        .runModal()
        guard welcome.offersInstall, answer == .alertFirstButtonReturn, case .app(let app) = source else { return }
        do {
            let report = try AppInstall.install(app: app, folder: folder, force: false, home: home)
            var text = report.lines.joined(separator: "\n")
            // The Finder's PATH is launchd's, not a terminal's, so the advice is given as a condition.
            let shell = ShellCompletions.detect(shellPath: environment["SHELL"])
            text +=
                "\n\n" + AppInstall.pathAdvice(folder, shell: shell, home: home, known: false).joined(separator: "\n")
            text += "\n\nOpen a terminal and run wisp chat."
            _ = alert("Wisp is installed", text, buttons: ["OK"]).runModal()
        } catch {
            _ = alert("Wisp could not be installed", "\(error)", buttons: ["OK"], style: .warning).runModal()
        }
    }

    /// An alert with the app's icon and `buttons`, the first the default.
    @MainActor private static func alert(
        _ title: String, _ text: String, buttons: [String], style: NSAlert.Style = .informational
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        for button in buttons { alert.addButton(withTitle: button) }
        return alert
    }
}

import ArgumentParser
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
            + "wisp only with --force. A Homebrew install puts wisp on PATH itself: the formula is refused, and with no "
            + "folder named, the cask's links are found and nothing is added.")

    @Argument(help: "The folder to link into; ~/.local/bin when omitted.", completion: .directory)
    var folder: String?

    @Flag(help: "Replace a link to another wisp (never a file).")
    var force = false

    func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let home = ShellCompletions.home(environment: environment)
        let target = AppInstall.folder(folder, home: home)
        let report: AppInstall.Report
        do {
            let app = try InstallCommand.app()
            // Homebrew's cask already links wisp onto PATH (ADR 0084); a second set is made only into a folder named.
            if self.folder == nil,
                let linked = AppInstall.linkedElsewhere(app: app, folder: target, path: environment["PATH"])
            {
                print(AppInstall.alreadyLinked(linked, app: app, home: home))
                return
            }
            report = try AppInstall.install(app: app, folder: target, force: force, home: home)
        } catch let failure as AppInstall.Failure {
            FileHandle.standardError.write(Data("Error: \(failure)\n".utf8))
            throw ExitCode.failure
        }
        for line in report.lines { print(line) }
        if !AppInstall.isOnPath(target, path: environment["PATH"]) {
            let shell = ShellCompletions.detect(shellPath: environment["SHELL"])
            for line in AppInstall.pathAdvice(target, shell: shell, home: home) { print(line) }
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
            + "names anything else it leaves, and unregisters wisp's own llama.cpp server's Login Item when it is "
            + "registered. It does not remove Wisp.app (drag it to the Bin) or ~/.wisp.")

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
        // The app's Login Item for wisp's own llama.cpp server goes with it (ADR 0082, decision 4).
        let session = try Wisp.begin(.init(entryPoint: .config))
        defer { session.end() }
        let done = LlamaCppAgent.follow(
            .uninstall, server: session.config.llamacpp.server, control: LlamaCppAgent.control(home: Wisp.home),
            audit: session.audit, source: "cli", say: { print($0) })
        guard done else { throw ExitCode.failure }
    }
}

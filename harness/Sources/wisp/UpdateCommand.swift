import ArgumentParser
import Foundation
import WispCore

/// `wisp update`: replaces `Wisp.app` with the latest release, checked first (`AppUpdate`,
/// [ADR 0074](../../../docs/decisions/0074-wisp-update.md)). Run by the person; the default policy refuses it to the
/// model.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update Wisp.app to the latest release, or (--check) say whether there is one.",
        discussion:
            "Asks GitHub for the latest release. When it is newer, downloads Wisp-X.Y.Z.dmg and its sha256 to "
            + "~/Downloads, checks the checksum, that the app inside is signed by wisp's team and notarised, and "
            + "replaces Wisp.app whole, keeping the old one until the new one is in place. When macOS will not let "
            + "it replace the app, it leaves the app as it was and opens the disk image for you to drag the new one. "
            + "A Homebrew install is told to run brew upgrade pidster/tap/wisp. updates.check (off by default) checks "
            + "once a day and shows a newer version in wisp doctor and the chat's status line.")

    @Flag(help: "Only say whether a newer release is out; download nothing.")
    var check = false

    func run() async throws {
        let source = AppInstall.source(of: PackageLayout.current)
        var app: URL?
        if !check {
            do {
                app = try AppUpdate.app(of: source)
            } catch {
                throw Self.failure("\(error)")
            }
        }
        let session = try Wisp.begin(.init(entryPoint: .update))
        defer { session.end() }
        let current = WispVersion.current
        let result = await AppUpdate.check(home: Wisp.home, source: "cli", audit: session.audit)
        if let failure = result.failure { throw Self.failure("\(failure)") }
        guard let release = result.release, let newer = result.state.newer(than: current) else {
            print("wisp \(current) is the latest release")
            return
        }
        guard let app else {
            print("wisp \(newer) is available (this is \(current))")
            do {
                _ = try AppUpdate.app(of: source)
                print("update with: wisp update")
            } catch {
                print("\(error)")
            }
            return
        }
        let downloads =
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        let outcome: AppUpdate.Outcome
        do {
            outcome = try await AppUpdate.update(
                app, to: release, downloads: downloads, audit: session.audit, source: "cli", note: { print($0) })
        } catch {
            throw Self.failure("\(error); \(app.path) is unchanged")
        }
        switch outcome {
        case .replaced(let app, let from, let to):
            print("updated \(app.path) from \(from) to \(to)")
            print("wisp processes already running, such as MCP servers, keep \(from) until they are started again")
        case .blocked(let reason, let image):
            print("\(app.path) is unchanged: \(reason)")
            _ = AppUpdate.run("/usr/bin/open", [image.path])
            print("opened \(image.path); drag Wisp.app onto Applications there to replace the old one")
            throw ExitCode.failure
        }
    }

    /// Says why on standard error, and returns the exit status 1 to throw.
    private static func failure(_ message: String) -> ExitCode {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
        return .failure
    }
}

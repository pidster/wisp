import Foundation
import Testing

@testable import WispCore

/// The decision `wisp chat` makes before handing a terminal session to `wisp-tui`, and where it looks.
@Suite struct FrontEndHandOffTests {
    /// Mirrors the gate in `Chat.frontEnd(besides:json:plain:interactive:exists:)`, which lives in the executable
    /// target; where it looks is `FrontEnd`, tested for real below.
    private func frontEnd(json: Bool, plain: Bool, interactive: Bool, installed: Bool) -> String? {
        guard !json, !plain, interactive else { return nil }
        return installed ? "/opt/wisp/bin/wisp-tui" : nil
    }

    @Test func handsOffOnlyForAnInteractivePlainSessionWithTheFrontEndInstalled() {
        #expect(frontEnd(json: false, plain: false, interactive: true, installed: true) == "/opt/wisp/bin/wisp-tui")
        #expect(frontEnd(json: true, plain: false, interactive: true, installed: true) == nil)
        #expect(frontEnd(json: false, plain: true, interactive: true, installed: true) == nil)
        #expect(frontEnd(json: false, plain: false, interactive: false, installed: true) == nil)
        #expect(frontEnd(json: false, plain: false, interactive: true, installed: false) == nil)
    }

    /// Homebrew's layout since 0.17.0: `wisp` in `libexec`, `wisp-tui` in `bin`. 0.17.0 and 0.18.0 looked only
    /// beside `libexec/wisp`, found nothing, and fell back to the plain chat without a word.
    @Test func findsTheFrontEndInABinBesideLibexec() {
        let wisp = URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.18.1/libexec/wisp")
        let installed: Set = ["/opt/homebrew/Cellar/wisp/0.18.1/bin/wisp-tui"]
        #expect(
            FrontEnd.locate(besides: wisp, exists: installed.contains)?.path
                == "/opt/homebrew/Cellar/wisp/0.18.1/bin/wisp-tui")
        #expect(
            FrontEnd.candidates(besides: wisp).map(\.path) == [
                "/opt/homebrew/Cellar/wisp/0.18.1/libexec/wisp-tui", "/opt/homebrew/Cellar/wisp/0.18.1/bin/wisp-tui",
            ])
    }

    @Test func prefersTheFolderBesideAndLooksOnceInABin() {
        let build = URL(fileURLWithPath: "/repo/harness/.build/debug/wisp")
        let both: Set = ["/repo/harness/.build/debug/wisp-tui", "/repo/harness/.build/bin/wisp-tui"]
        #expect(FrontEnd.locate(besides: build, exists: both.contains)?.path == "/repo/harness/.build/debug/wisp-tui")
        // In a plain bin the sibling bin is the same folder, looked in once.
        #expect(
            FrontEnd.candidates(besides: URL(fileURLWithPath: "/usr/local/bin/wisp")).map(\.path) == [
                "/usr/local/bin/wisp-tui"
            ])
        #expect(FrontEnd.locate(besides: build, exists: { _ in false }) == nil)
    }
}

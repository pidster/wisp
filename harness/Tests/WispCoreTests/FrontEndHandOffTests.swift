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

/// Where the running `wisp` is, by the kernel's path and never by `argv[0]`, which a parent may set to a name of
/// its choosing at spawn (ADR 0061: `wisp mcp (claude-code)`, `wisp chat (tui)`).
@Suite struct ExecutablePathTests {
    @Test func theKernelsAbsolutePathWinsAndLinksAreResolved() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wisp-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appending(path: "wisp")
        try Data().write(to: real)
        let link = folder.appending(path: "wisp-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let bundle = URL(fileURLWithPath: "/opt/elsewhere/wisp")
        #expect(
            ExecutablePath.resolve(kernel: link.path, bundle: bundle)?.path == real.resolvingSymlinksInPath().path)
    }

    @Test func aRelativeKernelPathDefersToTheBundleAndNothingFallsBackToArgv0() {
        let bundle = URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.23.0/libexec/wisp")
        #expect(ExecutablePath.resolve(kernel: ".build/debug/wisp", bundle: bundle)?.path == bundle.path)
        #expect(ExecutablePath.resolve(kernel: nil, bundle: bundle)?.path == bundle.path)
        // With neither source there is no answer: a name such as argv[0] is never taken for a path.
        #expect(ExecutablePath.resolve(kernel: nil, bundle: nil) == nil)
        #expect(ExecutablePath.resolve(kernel: "", bundle: nil) == nil)
    }

    @Test func theRunningProcessIsFoundByTheKernelsPath() throws {
        let kernel = try #require(ExecutablePath.kernelPath())
        let current = try #require(ExecutablePath.current)
        #expect(current.path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: current.path))
        // The kernel's path, not the name the process was given: the two agree on the file, links resolved.
        let byKernel = URL(fileURLWithPath: kernel).standardizedFileURL.resolvingSymlinksInPath()
        #expect(current.path == byKernel.path)
        #expect(FrontEnd.runningExecutable == current)
    }
}

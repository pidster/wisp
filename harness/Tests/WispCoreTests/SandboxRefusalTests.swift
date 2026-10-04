import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The sandbox's refusals checked (ADR 0054): the paths read from each common shape of `Operation not permitted`,
/// checked against the writable roots as real paths; a guess where no path is named; what the model is told; the
/// audit; and one real refusal of a harmless write to a scratch directory outside the roots.
@Suite struct SandboxRefusalTests {
    @Test func eachCommonShapeNamesItsPath() {
        let shapes: [(String, [String])] = [
            ("sh: /etc/wisp-x: Operation not permitted", ["/etc/wisp-x"]),
            ("sh: line 1: /etc/wisp-x: Operation not permitted", ["/etc/wisp-x"]),
            ("/bin/sh: /etc/wisp-x: Operation not permitted", ["/etc/wisp-x"]),
            ("touch: /Users/p/f.txt: Operation not permitted", ["/Users/p/f.txt"]),
            ("cp: /Users/p/out/a.txt: Operation not permitted", ["/Users/p/out/a.txt"]),
            ("mkdir: /Users/p/new: Operation not permitted", ["/Users/p/new"]),
            ("rm: /Users/p/old: Operation not permitted", ["/Users/p/old"]),
            ("cp: cannot create regular file '/Users/p/a': Operation not permitted", ["/Users/p/a"]),
            ("mv: rename a.txt to /Users/p/b.txt: Operation not permitted", ["/Users/p/b.txt"]),
            ("PermissionError: [Errno 1] Operation not permitted: '/Users/p/data.json'", ["/Users/p/data.json"]),
            ("touch: ./here.txt: Operation not permitted", ["./here.txt"]),
            ("touch: ~/notes.txt: Operation not permitted", ["~/notes.txt"]),
            // No path: the nested wisp of session ce87576a, 2026-10-04; a connect refused by the network rule.
            ("Error: Operation not permitted", []),
            ("PermissionError: [Errno 1] Operation not permitted", []),
            ("curl: (7) Failed to connect to example.com port 443: Operation not permitted", []),
            // Lines without the marker name nothing.
            ("ls: /nope: No such file or directory", []),
        ]
        for (stderr, expected) in shapes {
            #expect(SandboxRefusal.paths(in: stderr) == expected, "\(stderr)")
        }
        let several = "touch: /a/1: Operation not permitted\nnoise\ntouch: /a/2: Operation not permitted\n"
        #expect(SandboxRefusal.paths(in: several) == ["/a/1", "/a/2"])
    }

    @Test func aPathOutsideEveryRootIsTheSandboxsAndOneInsideIsNot() {
        let roots = ["/Users/p/project", "/private/tmp", "/private/var/folders/xy/T"]
        func check(_ stderr: String, status: Int32 = 1, sandboxed: Bool = true) -> SandboxRefusal? {
            SandboxRefusal.check(
                stderr: stderr, exitStatus: status, sandboxed: sandboxed, roots: roots, directory: "/Users/p/project")
        }
        #expect(
            check("touch: /Users/p/elsewhere.txt: Operation not permitted")
                == .refused(paths: ["/Users/p/elsewhere.txt"]))
        #expect(
            check("touch: /Users/p/project/locked.txt: Operation not permitted")
                == .notTheSandbox(paths: ["/Users/p/project/locked.txt"]))
        // A relative path is taken from where the command ran; `..` out of the project is outside it.
        #expect(check("touch: ./a.txt: Operation not permitted") == .notTheSandbox(paths: ["/Users/p/project/a.txt"]))
        #expect(check("touch: ../a.txt: Operation not permitted") == .refused(paths: ["/Users/p/a.txt"]))
        // A root's name as a prefix is not the root.
        #expect(
            check("touch: /Users/p/project2/a: Operation not permitted") == .refused(paths: ["/Users/p/project2/a"]))
        // One outside among several is enough, and only it is named.
        #expect(
            check("touch: /private/tmp/ok: Operation not permitted\ntouch: /etc/x: Operation not permitted")
                == .refused(paths: ["/private/etc/x"]))  // /etc is a link to /private/etc
        // No path: a guess. Nothing to say when unconfined, successful, or not EPERM.
        #expect(check("Error: Operation not permitted") == .guess)
        #expect(check("Error: Operation not permitted", sandboxed: false) == nil)
        #expect(check("touch: /etc/x: Operation not permitted", status: 0) == nil)
        #expect(check("touch: /etc/x: Permission denied") == nil)
        #expect(SandboxRefusal.guess.mayBeTheSandbox && SandboxRefusal.refused(paths: []).mayBeTheSandbox)
        #expect(!SandboxRefusal.notTheSandbox(paths: []).mayBeTheSandbox)
    }

    @Test func symlinkedRootsAndPathsCompareAsRealPaths() {
        // /tmp is a symlink to /private/tmp, as the profile's roots are written.
        let roots = [CommandPolicy.canonical("/tmp")]
        #expect(roots == ["/private/tmp"])
        let written = "/tmp/wisp-refusal-\(UUID().uuidString)/x"
        #expect(
            SandboxRefusal.check(
                stderr: "touch: \(written): Operation not permitted", exitStatus: 1, sandboxed: true, roots: roots,
                directory: "/") == .notTheSandbox(paths: ["/private" + written]))
        // And the other way: a root given through its link still holds its real path's files.
        #expect(
            SandboxRefusal.inside("/private/tmp/a", roots: roots) && !SandboxRefusal.inside("/private/tm", roots: roots)
        )
    }

    @Test func theModelIsToldWhatWasRefusedAndWhereItMayWrite() {
        let roots = ["/Users/p/project", "/private/tmp"]
        let refused = SandboxRefusal.refused(paths: ["/Users/p/out.txt"]).note(roots: roots)
        #expect(
            refused
                == "sandbox: refused writing to /Users/p/out.txt; commands may write only under /Users/p/project, /private/tmp"
        )
        let many = SandboxRefusal.refused(paths: ["/a", "/b", "/c", "/d", "/e"]).note(roots: roots)
        #expect(many.contains("/a, /b, /c and 2 more"))
        let long = (1...20).map { "/very/long/root/number/\($0)/with/more/segments" }
        let bounded = SandboxRefusal.refused(paths: ["/x"]).note(roots: long)
        #expect(bounded.utf8.count < 400 && bounded.hasSuffix("more"), "\(bounded)")
        #expect(
            SandboxRefusal.notTheSandbox(paths: ["/Users/p/project/a"]).note(roots: roots).contains("something else"))
        // The pathless case says plainly it was not the policy (session ce87576a, 2026-10-04).
        let guess = SandboxRefusal.guess.note(roots: roots)
        #expect(guess.contains("may have refused") && guess.contains("no path to check"))
        #expect(guess.contains("no policy rule denied it"))
        // The tool's result carries the note after the output.
        var outcome = CommandRunner.Outcome(
            exitStatus: 1, stdout: "", stderr: "Error: Operation not permitted\n", timedOut: false, truncated: false)
        outcome.sandboxNote = guess
        #expect(outcome.rendered.hasSuffix("stderr:\nError: Operation not permitted\n\n" + guess))
    }

    @Test(.enabled(if: !CommandRunnerPolicyTests.nested, "enforcement cannot be asserted inside an outer sandbox"))
    func aRealRefusalIsCheckedToldAndAudited() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A scratch directory outside every writable root: under the home directory, made by the test.
        let outside = FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "wisp-refusal-scratch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let sink = MemoryAuditSink()
        let runner = CommandRunner(options: .init(writableRoot: root.path), audit: AuditLog(session: "s", sink: sink))
        let target = outside.appending(path: "x.txt").path
        let outcome = try await runner.run("touch '\(target)'", in: root.path)
        let real = CommandPolicy.canonical(target)
        #expect(outcome.exitStatus != 0 && !FileManager.default.fileExists(atPath: target))
        #expect(outcome.sandboxRefusal == .refused(paths: [real]), "\(outcome.stderr)")
        #expect(outcome.rendered.contains("sandbox: refused writing to \(real); commands may write only under"))
        #expect(outcome.rendered.contains(CommandPolicy.canonical(root.path)))
        let event = try #require(sink.events.first { $0.kind == .commandOutcome })
        #expect(
            event.details["sandboxRefusal"] == "refused" && event.details["sandboxPaths"] == .array([.string(real)]))
        #expect(Set(event.details.keys).isSubset(of: AuditEvent.fields(for: .commandOutcome)))
        // A write inside the roots that succeeds says nothing.
        let fine = try await runner.run("touch ok.txt", in: root.path)
        #expect(fine.exitStatus == 0 && fine.sandboxRefusal == nil && fine.sandboxNote == nil)
        #expect(sink.events.last { $0.kind == .commandOutcome }?.details["sandboxRefusal"] == nil)
    }

    @Test func theModelsToolResultCarriesTheGuessForThePathlessError() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner(options: .init(writableRoot: root.path))
        // The exact stderr of session ce87576a's nested wisp, which the model then read as a policy denial.
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "echo 'Error: Operation not permitted' >&2; exit 1", workingDirectory: root.path))
        if runner.confines {
            #expect(result.contains("Error: Operation not permitted"))
            #expect(
                result.hasSuffix(
                    "sandbox: the sandbox may have refused this (Operation not permitted, no path to check: a network "
                        + "connection, a process, or a file the error does not name); no policy rule denied it"),
                "\(result)")
        } else {
            #expect(!result.contains("sandbox:"))
        }
    }
}

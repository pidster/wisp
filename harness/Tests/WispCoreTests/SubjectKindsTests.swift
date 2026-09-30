import Foundation
import Testing

@testable import WispCore

/// Subject kinds as data, with their normalisers behind one protocol (decision D2 of the layered-context
/// proposal), and the configuration that adds or changes them.
@Suite struct SubjectKindsTests {
    @Test func theDefaultsShipAsAResource() throws {
        let kinds = SubjectKinds.defaults
        #expect(
            kinds.kinds.map(\.name)
                == [
                    "task", "decision", "preference", "entity", "tests", "file", "service", "machine", "workdir",
                    "branch",
                ])
        #expect(kinds.kind("Entity")?.temporalClass == .permanent)
        #expect(kinds.kind("tests")?.temporalClass == .dynamic && kinds.kind("service")?.temporalClass == .ephemeral)
        #expect(kinds.kinds.allSatisfy { FactNormalisers.named($0.normaliser) != nil && !$0.description.isEmpty })
        #expect(kinds.testCommands.contains("swift test") && kinds.testCommands.contains("scripts/check"))
        #expect(kinds.kinds.filter { !$0.distils }.map(\.name) == ["file", "service", "machine"])
        #expect(kinds.applying(.init(kinds: [.init(name: "file", distil: true)])).kind("file")?.distils == true)
        #expect(kinds.kind("nope") == nil && kinds.identity(subject: "nope", name: "x") == nil)
        let (identity, temporalClass) = try #require(kinds.identity(subject: "entity", name: "  Blue   HERON "))
        #expect(identity == FactIdentity(scope: .permanent, subject: "entity", name: "blue heron"))
        #expect(temporalClass == .permanent)
        #expect(kinds.identity(subject: "task", name: "whatever")?.identity.name == "")
    }

    @Test func normalisersAreSmallAndSeparate() {
        #expect(FactNormalisers.Trim().normalise("  a \n b  ") == "a b")
        #expect(FactNormalisers.CaseFold().normalise("Café “X”.") == "cafe “x”")
        #expect(FactNormalisers.Single().normalise("anything") == "")
        let command = FactNormalisers.Command()
        #expect(command.normalise("set -o pipefail; swift test 2>&1 | tail -3") == "swift test")
        #expect(command.normalise("cd /repo && cargo test --workspace | head -20") == "cargo test --workspace")
        let path = FactNormalisers.Path(root: { $0.hasPrefix("/work/repo/") ? "/work/repo" : nil })
        #expect(path.normalise("/work/repo/Sources/a.swift") == "Sources/a.swift")
        #expect(path.normalise("/work/repo/./Sources/../b.swift") == "b.swift")
        #expect(path.normalise("/elsewhere/c.txt") == "/elsewhere/c.txt")
        #expect(path.normalise("Sources/a.swift") == "Sources/a.swift", "a relative path is kept")
        #expect(FactNormalisers.named("nope") == nil)
        // The walk up the file system finds this repository's root.
        let here = URL(fileURLWithPath: #filePath).path
        let root = FactNormalisers.Path.repositoryRoot(here)
        #expect(root.map { here.hasPrefix($0 + "/") && FileManager.default.fileExists(atPath: $0 + "/.git") } == true)
        #expect(FactNormalisers.Path.repositoryRoot("/") == nil)
    }

    @Test func testCommandsAreRecognisedFromTheList() {
        let kinds = SubjectKinds.defaults
        #expect(kinds.testCommand(in: "swift test --filter X") == "swift test")
        #expect(kinds.testCommand(in: "cd /r && ./scripts/check 2>&1 | tail -5") == "scripts/check")
        #expect(kinds.testCommand(in: "swift build && swift test") == "swift build")
        #expect(kinds.testCommand(in: "swift testing-tool") == nil)
        #expect(kinds.testCommand(in: "echo swift test") == nil)
        #expect(kinds.testCommand(in: "go test ./...") == "go test")
    }

    @Test func configurationAddsAndChangesKinds() throws {
        let config = Config.FactsConfig(
            kinds: [
                .init(name: "Ticket", normaliser: "casefold", description: "A ticket and its state."),
                .init(name: "entity", temporalClass: .dynamic),
            ], testCommands: ["bazel test"])
        let kinds = SubjectKinds.defaults.applying(config)
        #expect(
            kinds.kind("ticket")?.temporalClass == .dynamic
                && kinds.kind("ticket")?.description == "A ticket and its state.")
        #expect(kinds.kind("entity")?.temporalClass == .dynamic)
        #expect(kinds.kind("entity")?.normaliser == "casefold", "a change keeps the fields it does not set")
        #expect(kinds.testCommands == ["bazel test"])
        #expect(SubjectKinds.defaults.applying(nil) == SubjectKinds.defaults)
        // Unknown normalisers and shares out of range are refused when the config loads.
        #expect(throws: DecodingError.self) {
            try Config.FactsConfig(kinds: [.init(name: "x", normaliser: "soundex")]).validate()
        }
        #expect(throws: DecodingError.self) { try Config.FactsConfig(share: 0.9).validate() }
        #expect(throws: DecodingError.self) { try Config.FactsConfig(kinds: [.init(name: " ")]).validate() }
        // The file's shape, with "class" as the key.
        let json = #"{"facts":{"distil":false,"share":0.2,"kinds":[{"name":"ticket","class":"permanent"}]}}"#
        let resolved = try JSONDecoder().decode(Config.self, from: Data(json.utf8)).resolved
        #expect(!resolved.factsDistil && resolved.factsEnabled && resolved.factsShare == 0.2)
        #expect(resolved.subjectKinds.kind("ticket")?.temporalClass == .permanent)
        #expect(Config().resolved.factsShare == 0.1 && Config().resolved.factsDistil)
    }
}

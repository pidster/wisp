import Foundation
import FoundationModels
import Testing

@testable import WispCore

@Suite struct HomeTests {
    @Test func defaultsToDotWispInHome() {
        let home = Home.resolve(environment: [:])
        #expect(home.root.lastPathComponent == ".wisp")
        #expect(home.configFile.lastPathComponent == "config.json")
        #expect(home.logs.lastPathComponent == "logs")
        #expect(home.transcripts.lastPathComponent == "transcripts")
    }

    @Test func environmentOverridesLocation() {
        let home = Home.resolve(environment: [Home.environmentKey: "/tmp/dh"])
        #expect(home.root.path == "/tmp/dh")
        #expect(Home.resolve(environment: [Home.environmentKey: ""]).root.lastPathComponent == ".wisp")
    }

    @Test func ensureCreatesTree() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        try home.ensure()
        for directory in [home.root, home.logs, home.transcripts] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }
}

@Suite struct ConfigTests {
    @Test func missingFileIsEmptyConfig() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")
        #expect(try Config.load(from: missing) == Config())
    }

    @Test func resolvedAppliesDefaults() {
        let resolved = Config().resolved
        #expect(resolved.systemPromptExtension == nil)
        #expect(
            resolved.runner
                == CommandRunner.Options(timeout: .seconds(120), maxTimeout: .seconds(1800), maxOutputBytes: nil))
        #expect(resolved.maxThreads == 32)
    }

    /// ADR 0063: `commandMaxTimeoutSeconds` caps requests, 1 to 86,400; outside that the file does not load.
    @Test func commandMaxTimeoutSecondsIsRangedAndResolved() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wisp-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for (seconds, loads) in [(0, false), (1, true), (600, true), (86_400, true), (86_401, false), (-5, false)] {
            try Data(#"{"commandMaxTimeoutSeconds":\#(seconds)}"#.utf8).write(to: file)
            if loads {
                #expect(try Config.load(from: file).resolved.runner.maxTimeout == .seconds(seconds))
            } else {
                #expect(throws: DecodingError.self, "\(seconds)") { try Config.load(from: file) }
            }
        }
        #expect(Config(commandTimeoutSeconds: 0).resolved.runner.timeout == .zero)
    }

    @Test func roundTripsAndIgnoresUnknownKeys() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wisp-config-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let config = Config(
            systemPromptExtension: "be terse", commandTimeoutSeconds: 5, commandMaxOutputBytes: 100, maxThreads: 2)
        try config.save(to: file)
        #expect(try Config.load(from: file) == config)
        try Data(#"{"instructions":"x","future":true}"#.utf8).write(to: file)
        #expect(try Config.load(from: file) == Config(instructions: "x"))
        #expect(try Config.load(from: file).resolved.systemPromptExtension == "x")  // pre-0.2 key
        try Data(#"{"systemPromptExtension":"y","instructions":"x"}"#.utf8).write(to: file)
        #expect(try Config.load(from: file).resolved.systemPromptExtension == "y")
        #expect(config.resolved.runner.timeout == .seconds(5))
    }
}

@Suite struct TranscriptStoreTests {
    @Test func validatesNames() {
        #expect(throws: Never.self) { try TranscriptStore.validate("a-b_c.1") }
        for bad in ["", "a b", "a/b", String(repeating: "x", count: 65)] {
            #expect(throws: TranscriptStore.Failure.invalidName(bad)) { try TranscriptStore.validate(bad) }
        }
    }

    @Test func savesListsAndLoads() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wisp-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TranscriptStore(directory: directory)
        #expect(try store.list().isEmpty)
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "be brief"))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "hi"))])),
            .response(.init(assetIDs: [], segments: [.text(.init(content: "hello"))])),
        ])
        try store.save(transcript, as: "chat1")
        #expect(try store.list() == ["chat1"])
        let permissions =
            try FileManager.default.attributesOfItem(atPath: store.url(for: "chat1").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try store.load("chat1").count == 3)
        #expect(throws: TranscriptStore.Failure.notFound("nope")) { try store.load("nope") }
    }

    @Test func emptyDirectoryListsNothing() throws {
        let store = TranscriptStore(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(try store.list().isEmpty)
    }
}

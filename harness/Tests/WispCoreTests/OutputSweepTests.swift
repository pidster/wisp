import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The output store swept by age (ADR 0050, 2026-10-12): a session's stored outputs go `context.outputDays` after its
/// last use, at a later session's start, within a bound, never the current session's and never what is not wisp's.
@Suite struct OutputSweepTests {
    /// A fresh home in the temporary directory.
    private func home() throws -> Home {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Home(root: root)
    }

    /// `days` ago.
    private func ago(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    /// Sets `url`'s modification time.
    private func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A session directory as the store writes it, an output and its record, last used `days` ago.
    @discardableResult
    private func session(_ name: String, in home: Home, daysAgo days: Double, bytes: Int = 10) throws -> URL {
        let directory = home.outputs.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in ["3f9a2c1b", "3f9a2c1b.json"] {
            let url = directory.appending(path: file)
            try Data(repeating: 0x61, count: bytes).write(to: url)
            try touch(url, ago(days))
        }
        try touch(directory, ago(days))
        return directory
    }

    /// Whether `name`'s directory is still in the store.
    private func exists(_ name: String, in home: Home) -> Bool {
        FileManager.default.fileExists(atPath: home.outputs.appending(path: name).path)
    }

    @Test func anOldSessionGoesARecentOneAndTheCurrentOneStay() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try session("0ld5e551", in: home, daysAgo: 40, bytes: 100)
        try session("rec3n7aa", in: home, daysAgo: 5)
        try session("cur43n7a", in: home, daysAgo: 40)
        let outcome = OutputSweep(home: home, days: 30).run(current: "cur43n7a")
        #expect(outcome == .init(removed: ["0ld5e551"], bytes: 200, deferred: 0))
        #expect(!exists("0ld5e551", in: home) && exists("rec3n7aa", in: home) && exists("cur43n7a", in: home))
        // Nothing left to do is nothing to record.
        #expect(OutputSweep(home: home, days: 30).run(current: "cur43n7a").isEmpty)
    }

    @Test func lastUseIsTheNewestTimeOfTheDirectoryAndItsFiles() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        // A file still being written moves its own time, not the directory's.
        let directory = try session("w417ing0", in: home, daysAgo: 40)
        try touch(directory.appending(path: "3f9a2c1b"), ago(1))
        try touch(directory, ago(40))
        #expect(OutputSweep(home: home, days: 30).run(current: "x").removed.isEmpty)
        #expect(exists("w417ing0", in: home))
        // A session newer than the cutoff by its directory alone is not examined at all.
        try session("n3wd1r00", in: home, daysAgo: 40)
        try touch(home.outputs.appending(path: "n3wd1r00"), ago(2))
        #expect(OutputSweep(home: home, days: 30).run(current: "x").isEmpty)
    }

    @Test func zeroDaysNeverSweeps() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try session("ancient0", in: home, daysAgo: 4000)
        let sweep = OutputSweep(home: home, days: 0)
        #expect(sweep.cutoff == nil && sweep.run(current: "x").isEmpty)
        #expect(sweep.due(in: sweep.survey()).isEmpty && exists("ancient0", in: home))
        // A store that does not exist is nothing to sweep.
        let empty = try self.home()
        defer { try? FileManager.default.removeItem(at: empty.root) }
        #expect(OutputSweep(home: empty, days: 30).run(current: "x").isEmpty)
    }

    @Test func theWorkIsBoundedAndTheRestWaitsForTheNextStart() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        for (index, name) in ["s0000000", "s1111111", "s2222222", "s3333333", "s4444444"].enumerated() {
            try session(name, in: home, daysAgo: 100 - Double(index))
        }
        let sweep = OutputSweep(home: home, days: 30)
        // Oldest first, at most the limit, the rest counted.
        #expect(sweep.run(current: "x", limit: 2) == .init(removed: ["s0000000", "s1111111"], bytes: 40, deferred: 3))
        // Past the deadline nothing more is examined.
        #expect(sweep.run(current: "x", deadline: .zero) == .init(removed: [], bytes: 0, deferred: 3))
        #expect(sweep.run(current: "x").removed == ["s2222222", "s3333333", "s4444444"])
        #expect(OutputSweep.removalLimit == 16 && OutputSweep.deadline == .milliseconds(100))
    }

    @Test func whatIsNotWispsIsLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let fm = FileManager.default
        try session("0ld5e551", in: home, daysAgo: 40)
        // An unexpected name, a subdirectory, a file with an unexpected name, a file at the top, and a link.
        try session("not wisp", in: home, daysAgo: 40)
        let nested = try session("n3573d00", in: home, daysAgo: 40)
        try fm.createDirectory(at: nested.appending(path: "inner"), withIntermediateDirectories: true)
        try touch(nested, ago(40))
        let named = try session("n4m3d000", in: home, daysAgo: 40)
        try Data("x".utf8).write(to: named.appending(path: "notes.txt~ copy"))
        try touch(named.appending(path: "notes.txt~ copy"), ago(40))
        try touch(named, ago(40))
        let loose = home.outputs.appending(path: "README")
        try Data("mine".utf8).write(to: loose)
        try touch(loose, ago(40))
        let target = try session("74rg3700", in: home, daysAgo: 40)
        let outside = home.root.appending(path: "elsewhere")
        try fm.moveItem(at: target, to: outside)
        try fm.createSymbolicLink(at: home.outputs.appending(path: "l1nk0000"), withDestinationURL: outside)
        let outcome = OutputSweep(home: home, days: 30).run(current: "x")
        #expect(outcome.removed == ["0ld5e551"])
        for name in ["not wisp", "n3573d00", "n4m3d000", "README", "l1nk0000"] {
            #expect(exists(name, in: home), "\(name)")
        }
        #expect(fm.fileExists(atPath: outside.appending(path: "3f9a2c1b").path))
        let survey = OutputSweep(home: home, days: 30).survey()
        #expect(survey.sessions.isEmpty)
        #expect(survey.foreign == ["README", "l1nk0000", "n3573d00", "n4m3d000", "not wisp"])
    }

    @Test func theSessionsStartRecordsTheSweep() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try home.ensure()
        try Data(#"{"context":{"outputDays":7}}"#.utf8).write(to: home.configFile)
        try session("0ld5e551", in: home, daysAgo: 8, bytes: 5)
        try session("rec3n7aa", in: home, daysAgo: 6)
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .respond), home: home, dependencies: .testing(sink: sink))
        let start = try #require(sink.events.first { $0.kind == .sessionStart })
        #expect(
            start.details["outputSweep"]
                == .object(["removed": .array(["0ld5e551"]), "bytes": 10, "deferred": 0]))
        #expect(!exists("0ld5e551", in: home) && exists("rec3n7aa", in: home))
        session.end()
        // A start with nothing to sweep records no field.
        let quiet = MemoryAuditSink()
        let next = try Session.begin(.init(entryPoint: .respond), home: home, dependencies: .testing(sink: quiet))
        #expect(quiet.events.first { $0.kind == .sessionStart }?.details["outputSweep"] == nil)
        next.end()
    }

    @Test func doctorReportsTheStoreAndWhatTheNextSweepRemoves() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        let probes = Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil })
        let doctor = Doctor(home: home, probes: probes)
        #expect(doctor.outputStore().ok && doctor.outputStore().detail.hasSuffix("first passes the budget"))
        try session("0ld5e551", in: home, daysAgo: 40, bytes: 1024)
        try session("rec3n7aa", in: home, daysAgo: 5, bytes: 512)
        try Data("x".utf8).write(to: home.outputs.appending(path: "README"))
        let finding = doctor.outputStore()
        #expect(finding.ok)
        #expect(
            finding.detail
                == "\(home.outputs.path) holds 2 sessions, 3 KiB; kept 30 days after last use (context.outputDays): "
                + "the next sweep removes 1 (2 KiB); 1 not wisp's, left alone: README")
        // Doctor only reports: nothing is removed.
        #expect(exists("0ld5e551", in: home))
        let never = Doctor(home: home, config: Config(context: .init(outputDays: 0)).resolved, probes: probes)
        #expect(never.outputStore().detail.contains("3 KiB; never swept (context.outputDays 0)"))
    }

    @Test func theSettingDefaultsToThirtyDaysAndIsValidated() throws {
        #expect(Config().resolved.contextOutputDays == 30)
        #expect(ConfigSettings.defaultValue("context.outputDays") == .int(30))
        #expect(ConfigSettings.setting("context.outputDays")?.kind == .integer(0...3650))
        let never = try ConfigEdit.set("context.outputDays", to: "0", in: nil)
        #expect(try JSONDecoder().decode(Config.self, from: never.data).resolved.contextOutputDays == 0)
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("context.outputDays", to: "-1", in: nil) }
        #expect(throws: ConfigEdit.Failure.self) { try ConfigEdit.set("context.outputDays", to: "3651", in: nil) }
        // Loading refuses a value out of range, and doctor names it.
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home.root) }
        try Data(#"{"context":{"outputDays":4000}}"#.utf8).write(to: home.configFile)
        #expect(throws: DecodingError.self) { try Config.load(from: home.configFile) }
        let probes = Doctor.Probes(systemModel: { nil }, configuredModel: { _, _, _ in nil })
        let settings = Doctor(home: home, probes: probes).settingsInRange()
        #expect(!settings.ok && settings.detail.contains("context.outputDays 4000 must be between 0 and 3650"))
    }
}

/// memory's `condense` asks its model as a side call: a model that can think is asked not to (ADR 0053).
@Suite struct CondenseThinkingTests {
    @Test func condenseAsksForNoThinkingEvenInsideATurnThatThinks() async throws {
        let model = ScriptedModel(steps: [.say("nothing here")])
        let ask = WispThread.condenserAsk(on: ResolvedModel(selection: .system, custom: model))
        let answer = try await RequestThinking.$current.withValue(.on) { try await ask("why did it fail") }
        #expect(answer == "nothing here")
        #expect(model.script.thinking.withLock { $0 } == [.off])
    }
}

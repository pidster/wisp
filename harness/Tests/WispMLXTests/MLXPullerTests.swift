import Foundation
import Synchronization
import Testing
import WispCore
import WispTestSupport

@testable import WispMLX

/// A Hugging Face that sends the first half of each weights file and then waits, as a slow connection does, until the
/// pull is cancelled; everything else as `FakeHub` serves it.
final class StallingHub: ModelPull.Transport {
    let hub: FakeHub

    init(_ hub: FakeHub) { self.hub = hub }

    func data(from url: URL) async throws -> (Data, Int) { try await hub.data(from: url) }

    func download(from url: URL, resumingAt offset: Int, into file: URL) async throws -> ModelPull.Download {
        guard url.lastPathComponent.hasSuffix(".safetensors"), let data = hub.files[url.lastPathComponent] else {
            return try await hub.download(from: url, resumingAt: offset, into: file)
        }
        try data.prefix(data.count / 2).write(to: file)
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw URLError(.cancelled)
    }
}

/// `ModelPull` as `WispCore`'s puller (ADR 0059), which every face's pull reaches: the plan as a summary and the lines
/// the person reads, the fetch's progress, a cancelled fetch keeping its part for the next pull to resume, and the link.
@Suite struct MLXPullerTests {
    /// A temporary home, cache, and the session a pull would run in.
    struct Place {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-puller-\(UUID().uuidString)")
        var home: Home { Home(root: root.appending(path: "home", directoryHint: .isDirectory)) }
        var cache: HubCache { HubCache(root: root.appending(path: "hub", directoryHint: .isDirectory)) }

        init() throws { try Home(root: root.appending(path: "home", directoryHint: .isDirectory)).ensure() }

        func session() throws -> Session {
            try Session.begin(.init(entryPoint: .models), home: home, dependencies: .testing())
        }

        func puller(_ transport: any ModelPull.Transport) -> MLXPuller {
            MLXPuller(hub: ModelPullTests.hubURL, transport: transport, cache: cache, interval: .milliseconds(5))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func thePlanBecomesASummaryWithTheLinesThePersonReads() async throws {
        let place = try Place()
        defer { place.remove() }
        let hub = FakeHub(files: ModelPullTests.repository, card: ["cardData": ["license": "apache-2.0"]])
        let notices = Mutex<[String]>([])
        let prepared = try await place.puller(hub).prepare("ornith-ai/q", session: try place.session()) { line in
            notices.withLock { $0.append(line) }
        }
        let summary = prepared.summary
        #expect(summary.repository == "ornith-ai/q" && summary.name == "q" && summary.publisher == "ornith-ai")
        #expect(summary.licence == "apache-2.0" && summary.files == 4 && summary.missing == 4)
        #expect(summary.remaining == summary.bytes && summary.selection == "mlx:q" && !summary.replacesDirectory)
        #expect(summary.destination == place.home.models.appending(path: "mlx/q").path)
        // The lines `wisp models pull` printed before ADR 0059, now the summary's.
        #expect(summary.lines.first == "ornith-ai/q at 0123456789ab: 4 files, \(PullSummary.size(summary.bytes))")
        #expect(summary.lines.contains { $0.hasPrefix("  model.safetensors") && $0.hasSuffix("to fetch") })
        #expect(summary.lines.contains("Snapshot: \(summary.snapshot)"))
        #expect(summary.lines.last == "Link: \(summary.destination) to the snapshot, as mlx:q")
        #expect(PublisherCheck.question(for: summary).contains("  Licence:     apache-2.0"))
        #expect(throws: ModelPull.Failure.notAllowed("../q")) { try place.puller(hub).repository("../q") }
        #expect(notices.withLock { $0 }.isEmpty, "nothing in the cache to check yet")
    }

    @Test func theFetchReportsItsProgressAndTheLinkSaysWhatHappened() async throws {
        let place = try Place()
        defer { place.remove() }
        let prepared = try await place.puller(FakeHub(files: ModelPullTests.repository)).prepare(
            "mlx-community/q", session: try place.session()
        ) { _ in }
        let steps = Mutex<[PullProgress]>([])
        let fetched = try await prepared.fetch({ step in steps.withLock { $0.append(step) } }, { _ in })
        #expect(fetched == prepared.summary.remaining)
        let seen = steps.withLock { $0 }
        #expect(Set(seen.map(\.index)) == [1, 2, 3, 4] && seen.allSatisfy { $0.files == 4 })
        #expect(seen.allSatisfy { $0.total == prepared.summary.remaining && $0.fetched <= $0.total })
        #expect(seen.map(\.fetched) == seen.map(\.fetched).sorted(), "progress only goes forward")
        let link = try prepared.link(false)
        #expect(link.outcome == "created" && link.closing.hasSuffix("only what you have verified."))
        #expect(link.closing.contains("Use it as --model mlx:q"))
    }

    /// The flake of 2026-10-12, made deterministic: a reading between a file's part becoming its blob and the next
    /// file starting found no part and counted none of the file, so progress went back (`4127, 4120`).
    @Test func progressCountsAFinishedFileWholeAndNeverGoesBack() async throws {
        let place = try Place()
        defer { place.remove() }
        let pull = ModelPull(
            hub: ModelPullTests.hubURL, transport: FakeHub(files: ModelPullTests.repository), cache: place.cache)
        let plan = try await pull.plan("mlx-community/q", into: place.home.models.appending(path: "mlx"))
        let steps = Mutex<[Int]>([])
        let reporter = FetchProgress(pull, plan) { step in steps.withLock { $0.append(step.fetched) } }
        reporter.report()
        #expect(steps.withLock { $0 }.isEmpty, "nothing before the first file starts")
        let last = try #require(plan.missing.last)
        let before = plan.remaining - last.size
        let blob = place.cache.blob(last.blob, of: plan.repository)
        let part = ModelPull.incomplete(of: blob)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        reporter.start(last, index: plan.missing.count)
        try Data(count: 1).write(to: part)
        reporter.report()
        // The part checked and renamed: the file is whole, and is counted so.
        try Data(count: last.size).write(to: blob)
        try FileManager.default.removeItem(at: part)
        reporter.report()
        // A part started again (the server ignored the range) is smaller than what was reported; it does not lower it.
        try FileManager.default.removeItem(at: blob)
        try Data().write(to: part)
        reporter.report()
        #expect(steps.withLock { $0 } == [before, before + 1, plan.remaining, plan.remaining])
    }

    @Test func aCancelledFetchKeepsItsPartAndTheNextPullResumesIt() async throws {
        let place = try Place()
        defer { place.remove() }
        let session = try place.session()
        let prepared = try await place.puller(StallingHub(FakeHub(files: ModelPullTests.repository))).prepare(
            "mlx-community/q", session: session
        ) { _ in }
        let steps = Mutex<[PullProgress]>([])
        let fetch = Task { try await prepared.fetch({ step in steps.withLock { $0.append(step) } }, { _ in }) }
        let weights = ModelPullTests.repository["model.safetensors"] ?? Data()
        let blob = place.cache.blob(FakeHub.sha256(weights), of: "mlx-community/q")
        let part = ModelPull.incomplete(of: blob)
        try await eventually("half the weights to arrive") { ModelPull.size(of: part) == weights.count / 2 }
        // The progress read the part as it arrived.
        try await eventually("the progress to say so") {
            steps.withLock { $0 }.contains { $0.file == "model.safetensors" && $0.fetched >= weights.count / 2 }
        }
        fetch.cancel()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(ModelPull.size(of: part) == weights.count / 2, "the part is kept")
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        // The next pull resumes the part with a range request.
        let hub = FakeHub(files: ModelPullTests.repository)
        let again = try await place.puller(hub).prepare("mlx-community/q", session: session) { _ in }
        _ = try await again.fetch({ _ in }, { _ in })
        #expect(hub.offsets.withLock { $0 }.contains(weights.count / 2))
        #expect(FileManager.default.fileExists(atPath: blob.path))
    }
}

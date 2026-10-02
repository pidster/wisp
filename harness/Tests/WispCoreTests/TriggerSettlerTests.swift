import Foundation
import Synchronization
import Testing

@testable import WispCore

/// A clock the test moves by hand: `sleep` suspends until `advance` passes its deadline, so a settle period
/// is exercised with no real time.
final class ScriptedClock: Clock, Sendable {
    /// A point on the scripted clock: how far it has been advanced.
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    /// A sleeper waiting for its deadline.
    private struct Sleeper {
        var id: Int
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    /// The current time and the sleepers.
    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    /// How many sleepers are waiting.
    var sleeping: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if deadline <= state.now { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if resume { continuation.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes the sleepers whose deadline has passed.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

@Suite struct TriggerSettlerTests {
    /// A settler over a scripted clock and the stream it feeds.
    private func make(settle: Duration) -> (TriggerSettler<ScriptedClock>, ScriptedClock, Collected) {
        let (stream, continuation) = AsyncStream.makeStream(of: Watcher.Trigger.self)
        let clock = ScriptedClock()
        let collected = Collected()
        let reader = Task { for await trigger in stream { collected.add(trigger) } }
        collected.reader = reader
        return (TriggerSettler(settle: settle, clock: clock, continuation: continuation), clock, collected)
    }

    /// The triggers received so far.
    final class Collected: Sendable {
        private let triggers = Mutex<[Watcher.Trigger]>([])
        private let readerBox = Mutex<Task<Void, Never>?>(nil)
        var reader: Task<Void, Never>? {
            get { readerBox.withLock { $0 } }
            set { readerBox.withLock { $0 = newValue } }
        }
        func add(_ trigger: Watcher.Trigger) { triggers.withLock { $0.append(trigger) } }
        var all: [Watcher.Trigger] { triggers.withLock { $0 } }
    }

    /// Waits until `count` triggers have arrived, or the clock-free wait gives up.
    private func received(_ collected: Collected, _ count: Int) async -> [Watcher.Trigger] {
        for _ in 0..<2000 where collected.all.count < count { await Task.yield() }
        return collected.all
    }

    /// Waits until `count` sleepers are waiting on the clock.
    private func waitForSleepers(_ clock: ScriptedClock, _ count: Int) async {
        for _ in 0..<2000 where clock.sleeping != count { await Task.yield() }
    }

    @Test func aBurstOfChangesIsOneTriggerAfterTheQuietPeriod() async {
        let (settler, clock, collected) = make(settle: .seconds(1))
        for _ in 0..<5 {
            settler.fileChanged()
            await waitForSleepers(clock, 1)
            clock.advance(by: .milliseconds(400))
        }
        // 2 s passed since the first change, but never 1 s without one: nothing yet.
        #expect(collected.all.isEmpty)
        clock.advance(by: .milliseconds(600))
        #expect(await received(collected, 1) == [.change])
        clock.advance(by: .seconds(10))
        await Task.yield()
        #expect(collected.all == [.change])
        settler.finish()
    }

    @Test func changesFurtherApartThanTheSettlePeriodAreSeparateTriggers() async {
        let (settler, clock, collected) = make(settle: .seconds(1))
        settler.fileChanged()
        await waitForSleepers(clock, 1)
        clock.advance(by: .seconds(1))
        #expect(await received(collected, 1) == [.change])
        settler.fileChanged()
        await waitForSleepers(clock, 1)
        clock.advance(by: .seconds(1))
        #expect(await received(collected, 2) == [.change, .change])
        settler.finish()
    }

    @Test func zeroPassesEveryChangeThrough() async {
        let (settler, clock, collected) = make(settle: .zero)
        settler.fileChanged()
        settler.fileChanged()
        #expect(await received(collected, 2) == [.change, .change])
        #expect(clock.sleeping == 0)
        settler.finish()
    }

    @Test func theStartAndTheIntervalAreNotDelayed() async {
        let (settler, clock, collected) = make(settle: .seconds(30))
        settler.start()
        settler.fileChanged()
        await waitForSleepers(clock, 1)
        settler.interval()
        // The change is still settling; the start and the interval have already arrived.
        #expect(await received(collected, 2) == [.start, .interval])
        clock.advance(by: .seconds(30))
        #expect(await received(collected, 3) == [.start, .interval, .change])
        settler.finish()
    }

    @Test func finishingDropsAChangeStillSettling() async {
        let (settler, clock, collected) = make(settle: .seconds(1))
        settler.fileChanged()
        await waitForSleepers(clock, 1)
        settler.finish()
        await waitForSleepers(clock, 0)
        clock.advance(by: .seconds(5))
        _ = await collected.reader?.value
        #expect(collected.all.isEmpty)
    }

    @Test func theSettleSettingDefaultsToOneSecondAndIsRangeChecked() throws {
        #expect(Config().resolved.watchSettle == 1)
        let configured = try JSONDecoder().decode(Config.self, from: Data(#"{"watch": {"settle": 2.5}}"#.utf8))
        #expect(configured.resolved.watchSettle == 2.5)
        #expect(ConfigSettings.defaultValue("watch.settle") == .double(1))
        #expect(ConfigSettings.setting("watch.settle") != nil)
        let home = FileManager.default.temporaryDirectory.appending(path: "wisp-settle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"watch": {"settle": 120}}"#.utf8).write(to: home)
        #expect(throws: DecodingError.self) { try Config.load(from: home) }
    }
}

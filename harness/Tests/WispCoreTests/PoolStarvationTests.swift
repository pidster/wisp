import Foundation
import Synchronization
import Testing

@testable import WispCore

/// The bounds that must hold whatever else the process is doing, checked while every thread of Swift's cooperative
/// pool is blocked, as a dozen `Blocking.run` callers and framework semaphores blocked it under the gate's parallel
/// tests (2026-10-10, docs/design.md, "Concurrency"). Each test starts the bounded work, blocks the pool with twice
/// as many tasks as it has threads, watches from the blocked test thread itself for what only an off-pool timer can
/// do in time, and then lets the pool go.
@Suite(.serialized, .timeLimit(.minutes(1))) struct PoolStarvationTests {
    /// Tasks that each block a cooperative thread until released, or for at most `hold`.
    final class Blockers: Sendable {
        /// How many have started blocking.
        private let entered = Mutex(0)
        /// Released once per blocker.
        private let release = DispatchSemaphore(value: 0)
        /// How many there are: twice the pool's width, so the pool is full even with other tests' work queued.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2

        /// Starts the blockers; each holds its thread for at most `hold`.
        ///
        /// - Parameter hold: The longest any of them blocks, so a failing test cannot hang the process.
        func start(hold: TimeInterval = 8) {
            for _ in 0..<count {
                Task.detached { self.block(hold) }
            }
        }

        /// Blocks the calling thread until released or `hold` passes.
        ///
        /// - Parameter hold: The longest it blocks.
        private func block(_ hold: TimeInterval) {
            entered.withLock { $0 += 1 }
            _ = release.wait(timeout: .now() + hold)
        }

        /// Waits, blocking, until the pool is full of blockers (every thread but the caller's), or a second passes.
        func waitUntilThePoolIsFull() {
            let full = ProcessInfo.processInfo.activeProcessorCount - 1
            _ = PoolStarvationTests.poll(upTo: 1) { entered.withLock { $0 } >= full }
        }

        /// Lets every blocker go.
        func stop() {
            for _ in 0..<count { release.signal() }
        }
    }

    /// Polls `condition` every 10 ms, blocking the calling thread, until it holds or `seconds` pass.
    ///
    /// - Parameters:
    ///   - seconds: How long to keep trying.
    ///   - condition: What to wait for.
    /// - Returns: Whether it held in time.
    static func poll(upTo seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    /// A scratch directory under the temporary directory, where the sandbox lets a command write.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theCommandWatchdogFiresWhileThePoolIsBlocked() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appending(path: "started").path
        let ended = root.appending(path: "ended").path
        let runner = CommandRunner(options: .init(timeout: .milliseconds(200)))
        let run = Task {
            try await runner.run("touch '\(started)'; trap \"touch '\(ended)'; exit 1\" TERM; sleep 30 & wait")
        }
        #expect(Self.poll(upTo: 10) { FileManager.default.fileExists(atPath: started) }, "the command never started")
        let blockers = Blockers()
        blockers.start()
        blockers.waitUntilThePoolIsFull()
        // A 200 ms watchdog has seconds to send SIGTERM; on the pool it waited for the blockers.
        let signalled = Self.poll(upTo: 3) { FileManager.default.fileExists(atPath: ended) }
        blockers.stop()
        let outcome = try await run.value
        #expect(signalled, "the watchdog did not fire while the cooperative pool was blocked")
        #expect(outcome.timedOut)
    }

    @Test func aTimeoutGivesUpWhileThePoolIsBlocked() async throws {
        let entered = Mutex(false)
        let cancelled = Mutex(false)
        let bounded = Task {
            try await Timeout.run(.milliseconds(200)) {
                // Ignores cancellation, as an MCP request in flight does; the handler records that it was asked.
                await withTaskCancellationHandler {
                    entered.withLock { $0 = true }
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                } onCancel: {
                    cancelled.withLock { $0 = true }
                }
            }
        }
        while !entered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        let blockers = Blockers()
        blockers.start()
        blockers.waitUntilThePoolIsFull()
        let gaveUp = Self.poll(upTo: 3) { cancelled.withLock { $0 } }
        blockers.stop()
        await #expect(throws: Timeout.Failure.elapsed(.milliseconds(200))) { try await bounded.value }
        #expect(gaveUp, "the deadline did not pass while the cooperative pool was blocked")
    }

    @Test func aBlockingBridgeCompletesWhileThePoolIsBlocked() throws {
        let blockers = Blockers()
        blockers.start()
        blockers.waitUntilThePoolIsFull()
        let start = Date()
        let value = try Blocking.run {
            try await Task.sleep(for: .milliseconds(20))
            return 7
        }
        let elapsed = Date().timeIntervalSince(start)
        blockers.stop()
        #expect(value == 7)
        // About 20 ms off the pool; on it, the operation waited for the blockers to give up after 8 s.
        #expect(elapsed < 2, "the bridged operation took \(elapsed) s")
    }
}

import Foundation
import Synchronization
import Testing

@testable import WispMCP

@Suite struct TurnQueueTests {
    @Test func turnsRunOneAtATimeInArrivalOrder() async throws {
        let queue = TurnQueue()
        let order = Mutex<[String]>([])
        try await queue.acquire()
        let second = Task { try await queue.run { order.withLock { $0.append("second") } } }
        while await !queue.isBusy { await Task.yield() }
        try await Task.sleep(for: .milliseconds(50))
        order.withLock { $0.append("first") }  // the holder's work, before the queued turn may start
        #expect(order.withLock { $0 } == ["first"])
        await queue.release()
        try await second.value
        #expect(order.withLock { $0 } == ["first", "second"])
        #expect(await !queue.isBusy)
    }

    @Test func closingWaitsForTheTurnUnderWayAndRefusesTheRest() async throws {
        let queue = TurnQueue()
        try await queue.acquire()
        let queued = Task { () async -> TurnQueue.Failure? in
            do throws(TurnQueue.Failure) {
                try await queue.acquire()
                return nil
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let closed = Mutex(false)
        let closing = Task {
            await queue.close()
            closed.withLock { $0 = true }
        }
        #expect(await queued.value == .closed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!closed.withLock { $0 })  // the turn under way still holds the queue
        await queue.release()
        await closing.value
        #expect(closed.withLock { $0 })
        await #expect(throws: TurnQueue.Failure.closed) { try await queue.acquire() }
    }
}

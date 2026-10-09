import Testing

@testable import WispCore

@Suite(.timeLimit(.minutes(1))) struct TimeoutTests {
    @Test func returnsResultWhenInTime() async throws {
        let value = try await Timeout.run(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func throwsTimeoutErrorWhenLate() async {
        await #expect(throws: Timeout.Failure.elapsed(.milliseconds(50))) {
            try await Timeout.run(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
    }

    @Test func givesUpOnTimeEvenWhenTheOperationIgnoresCancellation() async {
        // A continuation nobody resumes cannot be cancelled; the old task-group wait sat on it forever.
        // The bound is loose on purpose: the timer task can wait seconds for a thread on a loaded Mac,
        // and the failure this catches waited minutes. On 2026-10-09 the gate's tests, beside other builds, kept it
        // waiting 12.2 s, past the 10 s this allowed then.
        let started = ContinuousClock.now
        await #expect(throws: Timeout.Failure.elapsed(.milliseconds(100))) {
            try await Timeout.run(.milliseconds(100)) {
                await withCheckedContinuation { (_: CheckedContinuation<Int, Never>) in }
            }
        }
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func propagatesOperationErrors() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await Timeout.run(.seconds(5)) { throw Boom() } }
    }

    @Test func configResolvesTimeout() {
        #expect(Config().resolved.approvalTimeout == .seconds(600))
        #expect(Config(approval: .init(timeoutSeconds: 5)).resolved.approvalTimeout == .seconds(5))
        #expect(Config(approval: .init(timeoutSeconds: 0)).resolved.approvalTimeout == nil)
    }

    @Test func optionalTimeoutRunsUnboundedWhenNil() async throws {
        #expect(try await Timeout.run(nil) { 7 } == 7)
        await #expect(throws: Timeout.Failure.self) {
            try await Timeout.run(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
        }
    }
}

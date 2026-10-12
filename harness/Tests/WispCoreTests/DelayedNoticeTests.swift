import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// How many times a notice was posted.
final class PostCount: Sendable {
    /// The count.
    let count = Mutex(0)
    /// One more.
    func post() { count.withLock { $0 += 1 } }
    /// The count now.
    var value: Int { count.withLock { $0 } }
}

/// "Notify after N s unless settled": posted once when the wait outlasts the delay, never when it settles first,
/// at once for a zero delay or `postNow`, and never twice.
@Suite(.timeLimit(.minutes(1))) struct DelayedNoticeTests {
    @Test func aWaitThatSettlesWithinTheDelayPostsNothing() async throws {
        let posts = PostCount()
        let notice = DelayedNotice(after: .seconds(1)) { posts.post() }
        #expect(notice.outcome == .waiting)
        #expect(notice.settle() == .skipped)
        // Past the delay: the cancelled alarm never posts.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(posts.value == 0 && notice.outcome == .skipped)
        notice.postNow()
        #expect(posts.value == 0, "a settled notice is never posted")
    }

    @Test func aWaitThatOutlastsTheDelayPostsOnce() async throws {
        let posts = PostCount()
        let notice = DelayedNotice(after: .milliseconds(50)) { posts.post() }
        try await eventually("the notice posted") { posts.value == 1 }
        #expect(notice.settle() == .posted)
        notice.postNow()
        #expect(posts.value == 1)
    }

    @Test func aZeroDelayPostsBeforeTheInitialiserReturns() {
        let posts = PostCount()
        let notice = DelayedNotice(after: .zero) { posts.post() }
        #expect(posts.value == 1 && notice.outcome == .posted)
        #expect(notice.settle() == .posted)
        _ = DelayedNotice(after: .seconds(-1)) { posts.post() }
        #expect(posts.value == 2)
    }

    @Test func postNowPostsAtOnceAndTheAlarmDoesNotPostAgain() async throws {
        let posts = PostCount()
        let notice = DelayedNotice(after: .seconds(1)) { posts.post() }
        notice.postNow()
        #expect(posts.value == 1 && notice.outcome == .posted)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(posts.value == 1)
    }
}

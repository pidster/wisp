import Foundation
import Synchronization
import Testing

@testable import WispCore

/// The edges of the exact readers behind a held-back output's summary (`OutputSummary`), of `ToolOutput.fit` where
/// the head and the tail meet, and of `TurnStop.kill`: the cases the main suites do not reach.
@Suite struct OutputSummaryEdgeTests {
    /// An output of blank lines ends in "empty", not at a line number.
    @Test func anOutputOfBlankLinesIsSummarisedAsEmpty() {
        let notable = OutputSummary.notable(["", "   ", ""], tool: nil)
        #expect(notable[0].hasSuffix("; empty"))
    }

    /// With no failure format and no log severity (a traceback is not one), the error-looking lines are listed up to the limit and the rest counted.
    @Test func errorLookingLinesAreListedUpToTheLimitAndTheRestCounted() {
        let lines = (1...20).map { "step \($0): traceback printed" }
        let notable = OutputSummary.notable(lines, tool: nil)
        #expect(notable.contains("20 lines that mention an error or failure:"))
        #expect(notable.contains { $0.hasPrefix("L1: step 1:") })
        #expect(notable.contains { $0.hasPrefix("L12: ") } && !notable.contains { $0.hasPrefix("L13: ") })
        #expect(notable.last == "… and 8 more")
        // One such line is counted in the singular and has nothing after it.
        let one = OutputSummary.notable(["all quiet", "traceback printed", "done"], tool: nil)
        #expect(one.contains("1 line that mention an error or failure:"))
        #expect(!one.contains { $0.hasPrefix("… and ") })
    }

    /// An overview of a JSON document names its shape, as the notable lines do.
    @Test func anOverviewOfJSONNamesItsShape() {
        let overview = OutputSummary.overview(["{\"a\": [1, 2, 3], \"b\": {\"c\": \"x\"}}"], tool: nil)
        #expect(overview.contains { $0.hasPrefix("JSON: ") })
    }

    /// When the head and the tail of a whole output meet within a few bytes of the room, it is shown entire.
    @Test func aWholeOutputWithinAFewBytesOfTheRoomIsShownEntire() {
        let text = String(repeating: "a", count: 60) + "\n" + String(repeating: "b", count: 60)
        let fit = ToolOutput.fit(head: text, tail: text, within: 100)
        #expect(fit.shown == text && fit.held == nil)
    }

    /// In pieces, when the kept head and tail already cover every line, the tail gives way until one line is held back.
    @Test func piecesThatMeetHoldBackTheOneLineTheTailGivesUp() {
        let first = String(repeating: "a", count: 60)
        let last = String(repeating: "z", count: 60)
        let fit = ToolOutput.fit(
            head: first + "\n", tail: "x\n" + last + "\n", total: (lines: 2, bytes: 123), within: 100)
        #expect(fit.held?.lines == 1)
        #expect(fit.shown.hasPrefix(first + "\n[… 1 line ("))
    }

    /// `kill` makes every later request a kill and tells what is attached, even before anyone asked to stop.
    @Test func killTellsEverythingAttachedAndMakesLaterRequestsKills() {
        let stop = TurnStop()
        let seen = Mutex2()
        let token = stop.attach { seen.add($0) }
        stop.kill()
        #expect(stop.requested && stop.requests == 2)
        #expect(seen.all == [.kill])
        #expect(stop.request() == .kill)
        stop.detach(token)
        stop.kill()
        #expect(seen.all == [.kill, .kill])
        // A handler attached after a kill is told at once.
        let late = Mutex2()
        _ = stop.attach { late.add($0) }
        #expect(late.all == [.kill])
    }
}

/// A recorder of the requests a handler was told, safe to share with a `@Sendable` closure.
private final class Mutex2: Sendable {
    private let box = Synchronization.Mutex<[CommandStop.Request]>([])
    func add(_ request: CommandStop.Request) { box.withLock { $0.append(request) } }
    var all: [CommandStop.Request] { box.withLock { $0 } }
}

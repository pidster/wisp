import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Entries a reply cites that the conversation does not hold (ADR 0055): the forms read, ranges expanded and capped,
/// real against invented entries, the line, and every face it reaches.
@Suite struct CitedEntriesTests {
    /// A store of `count` entries.
    static func store(_ count: Int) -> ThreadRecord {
        var store = ThreadRecord()
        for index in 1...count {
            store.record(
                .prompt(.init(segments: [.text(.init(content: "p\(index)"))])), origin: .turn, turn: index, sources: [])
        }
        return store
    }

    @Test func theFormsWispUsesAreRead() {
        let cases: [(String, [Int])] = [
            ("Result (entry 19)", [19]),
            (#"to see it: memory "recall entry 7""#, [7]),
            ("[output of entry 7 not repeated: read_file at 14:05:12, ok]", [7]),
            ("Entry #4 says so.", [4]),
            ("entries 16-30", Array(16...30)),
            ("entries 16–30", Array(16...30)),
            ("entries 16—18", [16, 17, 18]),
            ("entry 19–21", [19, 20, 21]),
            ("entries 19, 20 and 21", [19, 20, 21]),
            ("entries 3, 5-7, or 9", [3, 5, 6, 7, 9]),
            ("entries 2 & 4", [2, 4]),
            ("see entry 3 and entry 3 again", [3]),
            ("no entries here; at 14:05 the entry was fine", []),
            ("an entryway 5", []),
            ("turn 4 and 17 files", []),
        ]
        for (text, expected) in cases {
            #expect(CitedEntries.cited(in: text).numbers == expected, "\(text)")
        }
    }

    @Test func rangesAreExpandedOnlyUpToTheCap() {
        let wide = CitedEntries.cited(in: "entries 1-100000")
        #expect(wide.numbers.count == CitedEntries.expansionLimit && wide.capped)
        #expect(!CitedEntries.cited(in: "entries 1-100").capped)
        let line = CitedEntries.line(Array(19...118), capped: true)
        #expect(
            line == "cited but not in this conversation: entries 19–118 (100); only the first 100 cited were checked")
    }

    @Test func theReplyOfSessionCe87576aIsCaughtOnlyWhereItInvented() {
        // The thread held about 18 entries; the 12:54Z reply cited 19 to 30 one by one and then 16-30 as a range.
        let store = Self.store(18)
        let reply = """
            1. Read the script. Result (entry 19): read 42 lines.
            2. Checked the config. Result (entry 20): ok.
            \((21...30).map { "Step. Result (entry \($0)): ok." }.joined(separator: "\n"))
            (All steps logged in entries 16-30; timestamps omitted for brevity.)
            """
        let missing = CitedEntries.missing(in: reply, store: store)
        #expect(missing.numbers == Array(19...30) && !missing.capped)
        #expect(CitedEntries.line(missing.numbers) == "cited but not in this conversation: entries 19–30 (12)")
        // The range sentence alone names only the missing part of it.
        let range = CitedEntries.missing(
            in: "(All steps logged in entries 16-30; timestamps omitted for brevity.)", store: store)
        #expect(range.numbers == Array(19...30))
        // Real entries, or no citation at all: no line.
        #expect(CitedEntries.missing(in: "See entry 3 and entries 16–18.", store: store).numbers.isEmpty)
        #expect(CitedEntries.line(CitedEntries.missing(in: "All done.", store: store).numbers) == nil)
        // One missing, and gaps, read compactly.
        #expect(CitedEntries.line([40]) == "cited but not in this conversation: entry 40")
        #expect(CitedEntries.line([25, 19, 20, 30]) == "cited but not in this conversation: entries 19–20, 25, 30 (4)")
        let scattered = stride(from: 20, through: 60, by: 2).map { $0 }
        #expect(CitedEntries.line(scattered)?.contains(", +13 more (21)") == true)
    }

    @Test func everyFaceCarriesTheLine() async throws {
        let model = ScriptedModel(steps: [.say("Done. Result (entry 19), see entries 2-3.")])
        let agent = Agent(instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model))
        let reply = try await agent.respond(to: "go")
        // The store holds the instructions, the prompt, and the reply: entries 1 to 3, so only 19 is missing.
        #expect(reply.unknownEntries == [19])
        #expect(reply.cited == "cited but not in this conversation: entry 19")
        let end = ChatTurn.end(turn: 1, seconds: 1, failed: false, ran: "ran: no tools", cited: reply.cited)
        #expect(
            end.footer(style: .plain)
                == "  ran: no tools\n  cited but not in this conversation: entry 19\n  1.0 s")
        #expect(ChatProtocol.turn(end)["cited"] == "cited but not in this conversation: entry 19")
        #expect(ChatProtocol.turn(.end(turn: 1, seconds: 1, failed: false))["cited"] == nil)
        // A reply that cites what exists has neither.
        let fine = try await agent.respond(to: "again")
        #expect(fine.unknownEntries.isEmpty && fine.cited == nil)
    }
}

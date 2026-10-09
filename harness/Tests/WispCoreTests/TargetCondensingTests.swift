import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Condensing to a token target (phase 5 of the layered-context proposal): the arithmetic, the invariant over
/// generated conversations, the overflow retry, the audit, and the person's note, all without a model.
@Suite struct TargetCondensingTests {
    /// SplitMix64: a small generator with a seed, so every generated conversation is the same on every run.
    struct Seeded: RandomNumberGenerator {
        /// The state.
        var state: UInt64

        /// The next value.
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A conversation for the loop to condense: a store and a composer, distilling by growing a simulated earlier
    /// block toward its cap as turns are handed to it, as facts and the summary do.
    final class Host: CondensingHost {
        /// The record.
        var store: ThreadRecord
        /// The composer.
        var composer: ContextComposer
        /// The current turn.
        var condensingTurn = 0
        /// Whether the conversation keeps facts.
        let keepsFacts: Bool
        /// The window, for the earlier block's cap.
        let window: Int
        /// Turns handed to the distiller so far.
        var distilledTurns = 0
        /// Distillations so far.
        var distillations = 0

        /// Creates a host.
        init(store: ThreadRecord, composer: ContextComposer, keepsFacts: Bool, window: Int) {
            self.store = store
            self.composer = composer
            self.keepsFacts = keepsFacts
            self.window = window
        }

        /// Counts the turns leaving, when facts are kept.
        func distil(leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry]) async -> Bool {
            guard keepsFacts else { return false }
            distilledTurns += leaving.filter { $0.kind == .prompt }.count
            distillations += 1
            return true
        }

        /// An earlier block of 150 bytes a distilled turn, within its cap, or within 1 KiB when squeezed.
        func refreshFrame() {
            guard keepsFacts, distilledTurns > 0 else { return }
            let cap =
                composer.squeezesEarlier
                ? ContextComposer.factsFloorBytes
                : max(ContextComposer.factsFloorBytes, Int(Double(window) * composer.factsShare) * 4)
                    + SummaryWriter.capBytes(share: composer.summaryShare, window: window)
            let text = String(repeating: "f", count: min(cap, distilledTurns * 150))
            composer.facts = FactFrame(earlier: text, now: nil, shown: [], omitted: 0)
        }

        /// Marks the outputs as references from this turn.
        func referenced(_ found: [ContextComposer.Referencing]) {
            for output in found { store.reference(output.entry, from: condensingTurn) }
        }
    }

    /// What a model's runtime would count: the bytes the composer sends, plus the tool definitions it leaves out, at
    /// four bytes a token.
    static func trueTokens(_ transcript: Transcript, definitions: Int) -> Int {
        (ContextComposer.bytes(of: transcript) + definitions) / ContextComposer.bytesPerToken
    }

    /// Text of about `bytes` bytes in lines, so a reference has first and last lines to show.
    static func text(_ bytes: Int, _ rng: inout Seeded) -> String {
        var lines: [String] = []
        var total = 0
        while total < bytes {
            let line = (0..<8).map { _ in
                ["sync", "flag", "file", "copy", "dry", "run", "port"].randomElement(using: &rng)!
            }
            .joined(separator: " ")
            lines.append(line)
            total += line.utf8.count + 1
        }
        return lines.joined(separator: "\n")
    }

    /// One turn's entries: a prompt, an optional read with its output, and a reply.
    static func turn(
        _ number: Int, prompt: Int, output: Int, reply: Int, _ rng: inout Seeded
    ) -> [Transcript.Entry] {
        let segment = { (text: String) in Transcript.Segment.text(.init(content: text)) }
        var entries: [Transcript.Entry] = [.prompt(.init(segments: [segment(text(prompt, &rng))]))]
        if output > 0 {
            let id = "call-\(number)"
            let arguments = (try? GeneratedContent(json: #"{"path":"/f\#(number)"}"#)) ?? GeneratedContent("")
            entries.append(
                .toolCalls(.init([Transcript.ToolCall(id: id, toolName: "read_file", arguments: arguments)])))
            entries.append(.toolOutput(.init(id: id, toolName: "read_file", segments: [segment(text(output, &rng))])))
        }
        entries.append(.response(.init(assetIDs: [], segments: [segment(text(reply, &rng))])))
        return entries
    }

    /// A store over instructions of `bytes` bytes.
    static func store(instructions bytes: Int, _ rng: inout Seeded) -> ThreadRecord {
        ThreadRecord(
            carrying: Transcript(entries: [
                .instructions(.init(segments: [.text(.init(content: text(bytes, &rng)))], toolDefinitions: []))
            ]))
    }

    // MARK: - Arithmetic

    @Test func theGoalIsTheTargetOrLessWhenThePromptAndTheHeadroomNeedMore() {
        let composer = ContextComposer(policy: .target(ContextTarget(share: 0.5, headroomTurns: 8)))
        #expect(composer.goal(window: 8192, prompt: 100, headroom: 1000) == 4096)
        // 0.85 × 8192 = 6963; less a 2,000-token prompt and 1,500 of headroom is 3,463, below half the window.
        #expect(composer.goal(window: 8192, prompt: 2000, headroom: 1500) == 3463)
        #expect(composer.goal(window: 8192, prompt: 9000, headroom: 0) == 0)
        #expect(composer.isOverBudget(used: 5000, prompt: 500, headroom: 1500, window: 8192))
        #expect(!composer.isOverBudget(used: 5000, prompt: 500, headroom: 0, window: 8192))
        // Under the fixed policy the goal is the whole window and there is no headroom.
        #expect(ContextComposer(policy: .fixed).goal(window: 100, prompt: 10, headroom: 10) == 100)
    }

    @Test func theTargetShareIsCappedBelowTheBudgetByTheMargin() {
        func composer(_ share: Double, budget: Double = 0.85) -> ContextComposer {
            var composer = ContextComposer(policy: .target(ContextTarget(share: share, headroomTurns: 8)))
            composer.budget = budget
            return composer
        }
        // The default share is untouched; one near the budget is capped at the budget less the margin.
        #expect(composer(0.5).effectiveShare(of: ContextTarget(share: 0.5)) == 0.5)
        #expect(composer(0.65).effectiveShare(of: ContextTarget(share: 0.65)) == 0.65)
        #expect(composer(0.8).effectiveShare(of: ContextTarget(share: 0.8)) == 0.65)
        #expect(composer(1).effectiveShare(of: ContextTarget(share: 1)) == 0.65)
        // It follows the budget, and never goes below 0.
        #expect(composer(0.5, budget: 0.5).effectiveShare(of: ContextTarget(share: 0.5)) == 0.3)
        #expect(composer(0.5, budget: 0.1).effectiveShare(of: ContextTarget(share: 0.5)) == 0)
        // The goal uses the capped share, for a target built in code as well.
        #expect(composer(0.8).goal(window: 10_000, prompt: 0, headroom: 0) == 6500)
        #expect(composer(0.5).goal(window: 10_000, prompt: 0, headroom: 0) == 5000)
    }

    @Test func noTargetCondensesOnTwoConsecutiveTurnsWhileTurnsOfAverageSizeArrive() async {
        let window = 8192
        for step in 0...20 {
            let share = Double(step) / 20
            for headroomTurns in [1, 4, 8] {
                var rng = Seeded(state: UInt64(step * 10 + headroomTurns))
                var composer = ContextComposer(
                    policy: .target(ContextTarget(share: share, headroomTurns: headroomTurns)))
                composer.cutsPresentation = false
                let host = Host(
                    store: Self.store(instructions: 600, &rng), composer: composer, keepsFacts: true, window: window)
                var condensedAt: [Int] = []
                var condensations = 0
                for number in 1...60 {
                    host.condensingTurn = number
                    host.composer.squeezesEarlier = false
                    host.refreshFrame()
                    host.referenced(host.composer.newReferences(in: host.store))
                    let fill = Self.trueTokens(host.composer.compose(host.store), definitions: 800)
                    let promptBytes = Int.random(in: 200...600, using: &rng)
                    let headroom = host.composer.headroom(in: host.store)
                    if host.composer.isOverBudget(
                        used: fill, prompt: (promptBytes + 1) / 4, headroom: headroom, window: window)
                    {
                        let goal = host.composer.goal(window: window, prompt: (promptBytes + 1) / 4, headroom: headroom)
                        _ = await TargetCondensing.run(host, fill: fill, goal: goal)
                        condensedAt.append(number)
                        condensations += 1
                    }
                    // Turns of about the same size: a read of up to 3 KiB (a reference after this turn) and a reply.
                    let output = Bool.random(using: &rng) ? Int.random(in: 500...3000, using: &rng) : 0
                    for entry in Self.turn(
                        number, prompt: promptBytes, output: output, reply: Int.random(in: 200...600, using: &rng),
                        &rng)
                    {
                        host.store.record(entry, origin: .turn, turn: number, sources: [])
                    }
                }
                let adjacent = zip(condensedAt, condensedAt.dropFirst()).filter { $1 - $0 == 1 }
                #expect(
                    adjacent.isEmpty,
                    "share \(share), headroom \(headroomTurns): condensed on turns \(condensedAt)")
                // The generated conversation is long enough to condense at all.
                #expect(condensations > 0, "share \(share), headroom \(headroomTurns)")
            }
        }
    }

    @Test func theHeadroomAveragesTheLatestTurnsWithoutTheirPrompts() {
        var rng = Seeded(state: 1)
        var store = Self.store(instructions: 100, &rng)
        let sizes = [(400, 800, 200), (40, 0, 120), (40, 4000, 400)]
        for (number, size) in sizes.enumerated() {
            for entry in Self.turn(number + 1, prompt: size.0, output: size.1, reply: size.2, &rng) {
                store.record(entry, origin: .turn, turn: number + 1, sources: [])
            }
        }
        let groups = store.turnGroups
        #expect(groups.count == 3 && groups.map(\.count) == [4, 2, 4])
        let whole = groups.map { ContextComposer.bytes(of: $0.filter { $0.kind != .prompt }.map(\.value)) }
        let all = ContextComposer(policy: .target(ContextTarget(share: 0.5, headroomTurns: 8)))
        #expect(all.headroom(in: store) == whole.reduce(0, +) / 3 / 4)
        let last = ContextComposer(policy: .target(ContextTarget(share: 0.5, headroomTurns: 1)))
        #expect(last.headroom(in: store) == whole[2] / 4)
        #expect(ContextComposer(policy: .target(ContextTarget(share: 0.5, headroomTurns: 0))).headroom(in: store) == 0)
        #expect(ContextComposer(policy: .fixed).headroom(in: store) == 0)
        // A dropped turn still counts: the headroom is about the turns' size, not what is active.
        store.retain(store.active.condensed(keepTurns: 1), droppedBy: nil)
        #expect(all.headroom(in: store) == whole.reduce(0, +) / 3 / 4)
    }

    // MARK: - The invariant

    /// One generated conversation, condensed wherever its turns pass the budget, with every condensation checked.
    ///
    /// - Returns: How many condensations it made, and how many reached the floor.
    static func conversation(seed: UInt64, counting: Bool) async -> (condensations: Int, floors: Int) {
        var rng = Seeded(state: seed)
        let window = [2048, 4096, 8192, 32_768].randomElement(using: &rng)!
        let target = ContextTarget(
            share: [0.4, 0.5, 0.6].randomElement(using: &rng)!, headroomTurns: [0, 1, 4, 8].randomElement(using: &rng)!)
        var composer = ContextComposer(policy: .target(target))
        composer.referencesOutput = Bool.random(using: &rng)
        composer.cutsPresentation = false
        let host = Host(
            store: store(instructions: Int.random(in: 200...(window / 2), using: &rng), &rng), composer: composer,
            keepsFacts: Bool.random(using: &rng), window: window)
        let definitions = Int.random(in: 0...2000, using: &rng)
        let count: ((Transcript) async -> Int?)? = counting ? { trueTokens($0, definitions: definitions) } : nil
        var condensations = 0
        var floors = 0
        var lastTurn: Transcript.Entry.ID?
        for number in 1...Int.random(in: 4...40, using: &rng) {
            host.condensingTurn = number
            host.composer.squeezesEarlier = false
            host.refreshFrame()
            host.referenced(host.composer.newReferences(in: host.store))
            let fill = trueTokens(host.composer.compose(host.store), definitions: definitions)
            let promptBytes = Int.random(in: 10...max(10, window / 4), using: &rng)
            let prompt = (promptBytes + 1) / 4
            let headroom = host.composer.headroom(in: host.store)
            if host.composer.isOverBudget(used: fill, prompt: prompt, headroom: headroom, window: window) {
                let entries = host.store.entries.count
                let goal = host.composer.goal(window: window, prompt: prompt, headroom: headroom)
                let outcome = await TargetCondensing.run(host, fill: fill, goal: goal, count: count)
                condensations += 1
                let actual = trueTokens(host.composer.compose(host.store), definitions: definitions)
                let context = "seed \(seed), turn \(number), window \(window), \(outcome)"
                // The measurement is what a model would count, within a token of rounding a measurement.
                #expect(abs(actual - outcome.after) <= outcome.steps.count + 1, "\(actual) \(context)")
                #expect(goal <= Int(Double(window) * target.share), "\(context)")
                #expect(host.store.entries.count == entries, "the store keeps every entry: \(context)")
                #expect(outcome.steps.filter { if case .dropped = $0 { true } else { false } }.count <= entries)
                // The last turn the model took part in is never dropped, whatever commands came after it (D5's floor).
                if let last = lastTurn {
                    #expect(
                        host.store.entries.first { $0.value.id == last }?.state == .active,
                        "the last whole turn stays: \(context)")
                }
                // The person's commands and the model's reasoning are no turn of their own.
                #expect(
                    host.store.turnCount(of: host.composer.literal(host.store))
                        == host.store.entries.filter { $0.kind == .prompt && $0.state == .active }.count,
                    "\(context)")
                if outcome.floor {
                    floors += 1
                    // Only at the floor: one literal turn or none, and the earlier block squeezed or empty.
                    #expect(
                        host.store.turnCount(of: host.composer.literal(host.store)) <= ContextTarget.floorTurns,
                        "\(context)")
                    #expect(host.composer.facts.earlier == nil || host.composer.squeezesEarlier, "\(context)")
                } else {
                    // At or below the target, and a turn of average size fits under the budget after the prompt.
                    #expect(outcome.after <= goal, "\(context)")
                    #expect(
                        Double(outcome.after + prompt + headroom) <= Double(window) * host.composer.budget,
                        "\(context)")
                }
            }
            let output = Bool.random(using: &rng) ? Int.random(in: 100...4096, using: &rng) : 0
            var entries = turn(
                number, prompt: promptBytes, output: output, reply: Int.random(in: 20...1600, using: &rng), &rng)
            // A thinking model's reasoning, kept for the person and never composed (ADR 0053).
            if Int.random(in: 0..<4, using: &rng) == 0 {
                entries.insert(
                    .reasoning(
                        .init(segments: [.text(.init(content: text(Int.random(in: 20...800, using: &rng), &rng)))])),
                    at: 1)
            }
            for entry in entries { host.store.record(entry, origin: .turn, turn: number, sources: []) }
            lastTurn = entries.first?.id
            // Now and then the person runs commands of their own after the turn (ADR 0049).
            for _ in 0..<[0, 0, 0, 1, 2].randomElement(using: &rng)! {
                host.store.record(
                    command: .init(line: "git status", directory: "/w", exitStatus: 0),
                    output: text(Int.random(in: 10...2000, using: &rng), &rng), turn: number + 1, sources: [],
                    time: Date())
            }
        }
        return (condensations, floors)
    }

    @Test func everyCondensationReachesTheTargetOrStopsAtTheFloor() async {
        var condensations = 0
        var floors = 0
        for seed in UInt64(1)...200 {
            let run = await Self.conversation(seed: seed, counting: seed.isMultiple(of: 2))
            condensations += run.condensations
            floors += run.floors
        }
        // The generator reaches both outcomes, so both branches of the invariant were checked.
        #expect(condensations > 200 && floors > 0 && floors < condensations, "\(condensations) \(floors)")
    }

    @Test func theOverflowRetryCondensesFromTheOverflowsOwnCountOrReportsTheFloor() async {
        for seed in UInt64(1)...200 {
            var rng = Seeded(state: seed)
            var composer = ContextComposer(policy: .default)
            composer.cutsPresentation = false
            let host = Host(
                store: Self.store(instructions: Int.random(in: 100...3000, using: &rng), &rng), composer: composer,
                keepsFacts: Bool.random(using: &rng), window: 8192)
            for number in 1...Int.random(in: 1...20, using: &rng) {
                for entry in Self.turn(
                    number, prompt: 200, output: Int.random(in: 0...4096, using: &rng), reply: 600, &rng)
                {
                    host.store.record(entry, origin: .turn, turn: number, sources: [])
                }
            }
            host.condensingTurn = 99
            host.referenced(host.composer.newReferences(in: host.store))
            // The failed request: the composition, the prompt, and the turn's own output, counted by the runtime.
            let composed = host.composer.compose(host.store)
            let own = Self.turn(99, prompt: 400, output: Int.random(in: 0...4096, using: &rng), reply: 0, &rng)
            let failed = Transcript(entries: Array(composed) + own)
            let counted = Self.trueTokens(failed, definitions: 600)
            let window = max(64, counted - Int.random(in: 1...max(1, counted / 2), using: &rng))
            let fill = max(
                0, counted + (ContextComposer.bytes(of: composed) - ContextComposer.bytes(of: failed)) / 4)
            let headroom = host.composer.headroom(in: host.store)
            let goal = host.composer.goal(window: window, prompt: 100, headroom: headroom)
            let outcome = await TargetCondensing.run(host, fill: fill, goal: goal)
            #expect(outcome.floor || outcome.after <= goal, "seed \(seed): \(outcome)")
            if outcome.floor {
                #expect(host.composer.literal(host.store).turnCount <= ContextTarget.floorTurns, "seed \(seed)")
            }
        }
    }

    @Test func theStepsGoReferencesThenDistilThenDropThenSqueezeAndTheFloorIsLastResort() async {
        var rng = Seeded(state: 7)
        var composer = ContextComposer(policy: .default)
        composer.cutsPresentation = false
        let host = Host(
            store: Self.store(instructions: 400, &rng), composer: composer, keepsFacts: true, window: 2048)
        for number in 1...6 {
            for entry in Self.turn(number, prompt: 200, output: 3000, reply: 400, &rng) {
                host.store.record(entry, origin: .turn, turn: number, sources: [])
            }
        }
        host.condensingTurn = 7
        let fill = Self.trueTokens(host.composer.compose(host.store), definitions: 0)
        let outcome = await TargetCondensing.run(host, fill: fill, goal: 600)
        // The six whole outputs become references first; then turns are distilled and dropped, oldest first.
        #expect(outcome.steps.first == .referenced(6), "\(outcome.steps)")
        #expect(outcome.steps.dropFirst().first.map { if case .distilled = $0 { true } else { false } } == true)
        #expect(!outcome.floor && outcome.after <= 600 && host.distillations >= 1, "\(outcome)")
        #expect(outcome.dropped.count == host.store.entries.filter { $0.state != .active }.count)
        #expect(outcome.steps.map(\.words).allSatisfy { !$0.isEmpty })
        // A goal nothing can reach: everything droppable goes, the earlier block is squeezed, and the floor says so.
        let floor = await TargetCondensing.run(host, fill: outcome.after, goal: 10)
        #expect(floor.floor && host.composer.squeezesEarlier, "\(floor)")
        #expect(host.composer.literal(host.store).turnCount == 1 && floor.steps.last == .squeezed)
        // Run again at the floor: nothing left to change, and it still reports the floor.
        let again = await TargetCondensing.run(host, fill: floor.after, goal: 10)
        #expect(again.floor && !again.changed)
    }

    // MARK: - Through the agent

    /// An agent on a scripted model that counts its transcript at four bytes a token and reports no usage.
    static func countingAgent(
        steps: [ScriptedModel.Step], window: Int, policy: ContextPolicy, sink: MemoryAuditSink,
        instructions: String = "Be brief."
    ) -> (Agent, ScriptedModel) {
        let model = ScriptedModel(steps: steps, reportsUsage: false)
        let agent = Agent(
            instructions: instructions, tools: [],
            model: ResolvedModel(
                selection: .system, custom: model, contextSize: window,
                countTokens: { ContextComposer.bytes(of: $0) / ContextComposer.bytesPerToken }),
            contextPolicy: policy, audit: AuditLog(session: "t", sink: sink))
        return (agent, model)
    }

    @Test func fewerDeeperCondensationsThanTheFixedFourTurnsEachAtOrBelowTheTarget() async throws {
        // Turns of about 190 tokens on a 1,000-token window: four of them sit near the 85% budget, so the fixed
        // policy, once full, condenses before almost every turn, a turn at a time (the on-device model's pattern
        // in the proposal's "Problem"). A target of half the window condenses deeper and lasts a few turns; it is
        // set here, since the default share (0.6) leaves room for only one such turn on so small a window.
        let reply = String(repeating: "word ", count: 120)
        let steps = (1...24).map { _ in ScriptedModel.Step.say(reply) }
        let prompts = (1...24).map { "prompt \($0) " + String(repeating: "x", count: 120) }
        let targetSink = MemoryAuditSink()
        let half = ContextPolicy.target(ContextTarget(share: 0.5, headroomTurns: 8))
        let (target, _) = Self.countingAgent(steps: steps, window: 1000, policy: half, sink: targetSink)
        let fixedSink = MemoryAuditSink()
        let (fixed, _) = Self.countingAgent(steps: steps, window: 1000, policy: .fixed, sink: fixedSink)
        for prompt in prompts {
            _ = try await target.respond(to: prompt)
            _ = try await fixed.respond(to: prompt)
        }
        let events = targetSink.events.filter { $0.kind == .condensation }
        #expect(
            !events.isEmpty && target.condensations * 3 / 2 <= fixed.condensations,
            "\(target.condensations) \(fixed.condensations)")
        for event in events {
            let after = try #require(event.details["fillAfter"]?.intValue)
            let goal = try #require(event.details["target"]?.intValue)
            #expect(after <= goal && goal <= 500, "\(event.details)")
            #expect((event.details["fillBefore"]?.intValue ?? 0) > after)
            #expect(event.details["headroom"]?.intValue != nil && event.details["floor"] == nil)
            let steps = event.details["steps"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(steps.contains { $0.hasPrefix("dropped ") }, "\(steps)")
            #expect(AuditEvent.fields(for: .condensation).isSuperset(of: Set(event.details.keys)))
        }
        // The dropped entries are attributed to the event that dropped them.
        let dropped = target.store.entries.filter { $0.state != .active }
        #expect(!dropped.isEmpty)
        #expect(dropped.allSatisfy { if case .dropped(let by) = $0.state { by != nil } else { false } })
        // Phase 2's events are unchanged: no target fields.
        #expect(fixedSink.events.filter { $0.kind == .condensation }.allSatisfy { $0.details["target"] == nil })
    }

    @Test func atTheFloorTheTurnGoesOnWithANoteAndTheEventSaysFloor() async throws {
        let sink = MemoryAuditSink()
        // Instructions of 350 tokens on a 400-token window: past the 340-token budget before any turn, and above
        // the 200-token target with nothing to drop.
        let (agent, _) = Self.countingAgent(
            steps: [.say("one"), .say("two")], window: 400, policy: .default, sink: sink,
            instructions: String(repeating: "rule ", count: 280))
        let first = try await agent.respond(to: "first")
        #expect(first.text == "one" && !first.condensed, "\(first)")
        #expect(first.contextNote?.contains("of 400 tokens") == true, "\(first)")
        let event = try #require(sink.events.last { $0.kind == .condensation })
        #expect(event.details["floor"] == true && event.details["reason"] == "budget")
        #expect(event.details["steps"] == .array([]) && agent.condensations == 0)
        // The person sees it in chat as a note, without a condensation line, since nothing was condensed.
        let line = ChatEvents.render(event, style: .plain) ?? ""
        #expect(line.hasPrefix("(context at its floor: the instructions and the last turn take"), "\(line)")
        // Each turn at the floor says so again; a turn that is not would carry no note.
        let second = try await agent.respond(to: "second")
        #expect(second.contextNote != nil)
    }

    @Test func anOverflowTheRetryCannotFixIsReportedAsDoesNotFit() async throws {
        let sink = MemoryAuditSink()
        let model = ScriptedModel(steps: [.say("one"), .say("two")])
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model),
            audit: AuditLog(session: "o", sink: sink))
        _ = try await agent.respond(to: "first")
        model.script.overflowSize.withLock { $0 = (contextSize: 4096, tokenCount: 5000) }
        model.script.overflows.withLock { $0 = 2 }
        await #expect(throws: ContextFailure.doesNotFit(tokens: 5000, window: 4096)) {
            try await agent.respond(to: "second")
        }
        let event = try #require(sink.events.last { $0.kind == .condensation })
        #expect(event.details["reason"] == "overflow" && event.details["contextSize"] == 4096)
        #expect("\(ContextFailure.doesNotFit(tokens: 5000, window: 4096))".contains("5000 of 4096 tokens"))
        // One overflow: the retry answers.
        model.script.overflows.withLock { $0 = 1 }
        #expect(try await agent.respond(to: "third").condensed)
    }

    @Test func theConfigSetsTheTargetAndTheHeadroom() throws {
        #expect(Config().resolved.contextTarget == .default)
        let config = Config(context: .init(target: 0.6, headroomTurns: 1))
        #expect(config.resolved.contextTarget == ContextTarget(share: 0.6, headroomTurns: 1))
        #expect(throws: DecodingError.self) { try Config.ContextConfig(target: 0.9).validate() }
        #expect(throws: DecodingError.self) { try Config.ContextConfig(headroomTurns: -1).validate() }
        #expect(ConfigSettings.defaultValue("context.target") == .double(0.6))
        // The default is checkpoint 2's (ADR 0057), and the guard leaves it alone at the default budget.
        #expect(ContextTarget.default == ContextTarget(share: 0.6, headroomTurns: 8))
        #expect(ContextComposer().effectiveShare(of: .default) == 0.6)
        #expect(ConfigSettings.defaultValue("context.headroomTurns") == .int(8))
        #expect(ConfigSettings.setting("context.target")?.kind == .number(0.1...0.8))
    }

    @Test func contextMemoryIsOffByDefaultAndRoundTripsThroughTheFile() throws {
        #expect(Config().resolved.contextMemory == false)
        #expect(ConfigSettings.setting("context.memory")?.kind == .flag)
        // Set from chat or `wisp config set`, beside the other context keys, and read back as start-up reads it.
        let file = Data(#"{"context": {"target": 0.5}}"#.utf8)
        let on = try ConfigEdit.set("context.memory", to: "on", in: file)
        #expect(on.old == nil && on.new == true && on.warning == nil)
        let config = try JSONDecoder().decode(Config.self, from: on.data)
        #expect(config.context == Config.ContextConfig(target: 0.5, memory: true))
        #expect(config.resolved.contextMemory && config.resolved.contextTarget.share == 0.5)
        let encoded = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(Config.self, from: encoded) == config)
        let off = try ConfigEdit.unset("context.memory", in: on.data)
        #expect(try JSONDecoder().decode(Config.self, from: off.data).resolved.contextMemory == false)
        #expect(try ConfigEdit.current("context.target", in: off.data) == .double(0.5))
    }
}

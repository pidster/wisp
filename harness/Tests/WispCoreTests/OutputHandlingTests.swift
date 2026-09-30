import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// Output handling, phase 3 of the layered-context proposal: finding presentational text in a reply by
/// word-sequence overlap with its turn's tool output (`Presentation`), cutting it from later requests while
/// the store and the person keep the reply whole, and auditing each cut.
@Suite struct PresentationTests {
    /// A configuration file as `read_file` returns it: numbered lines and the end marker.
    static let config = """
        # harbour.toml: the settings harbour reads at start-up, one table per sync profile.
        # Copy this file to ~/.config/harbour/harbour.toml and edit the paths before the first run.

        [profile.photos]
        source = "~/Pictures/Library"
        destination = "/Volumes/Backup/photos"
        include = ["*.heic", "*.jpg", "*.mov"]
        exclude = [".DS_Store", "*.tmp", "Thumbs.db"]
        delete_extraneous = false
        checksum = "sha256"

        [transport]
        retries = 3
        retry_backoff_seconds = 5
        verify_after_copy = true
        """

    /// `text` numbered as `read_file` renders a page.
    static func numbered(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { "\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n") + "\n[end of file]"
    }

    /// The text of `span` in `reply`.
    static func text(of span: Presentation.Span, in reply: String) -> String {
        String(decoding: Array(reply.utf8)[span.range], as: UTF8.self)
    }

    @Test func aRetypedFileIsCutAndTheWordsAroundItStay() throws {
        let output = Self.numbered(Self.config)
        let reply = "Here is the file:\n\n```toml\n\(Self.config)\n```\n\nIt defines one profile and the transport."
        let spans = Presentation.spans(in: reply, outputs: [output])
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(Self.text(of: span, in: reply) == "```toml\n\(Self.config)\n```")
        #expect(span.coverage == 1 && span.output == 0 && span.words >= Presentation.minimumWords)
        let cut = Presentation.replacing(reply, [(span.range, "(marker)")])
        #expect(cut == "Here is the file:\n\n(marker)\n\nIt defines one profile and the transport.")
    }

    @Test func aFileRetypedWithoutAFenceOrWithItsLineNumbersIsCutWhole() throws {
        let output = Self.numbered(Self.config)
        // Paragraph by paragraph, blank lines between: one span over all of them.
        let spans = Presentation.spans(in: Self.config, outputs: [output])
        #expect(spans.count == 1 && spans.first?.range == 0..<Self.config.utf8.count)
        // With the numbers copied too, the output as it was matches.
        let withNumbers = "```\n\(output)\n```"
        #expect(Presentation.spans(in: withNumbers, outputs: [output]).first?.coverage == 1)
    }

    @Test func aTableRestatingACommandsOutputIsCut() throws {
        let output = """
            exit status: 0
            stdout:
                 425 harness/Sources/WispCore/Session/Agent.swift
                  79 harness/Sources/WispCore/Session/ContextComposer.swift
                 224 harness/Sources/WispCore/Session/ThreadRecord.swift
                 108 harness/Sources/WispCore/Session/ThreadRecordSnapshot.swift
                 170 harness/Sources/WispCore/Session/Introspection.swift
                 463 harness/Sources/WispCore/Session/Session.swift
                1469 total
            """
        let reply = """
            Line counts for the session files:

            | Lines | File |
            | --- | --- |
            | 425 | harness/Sources/WispCore/Session/Agent.swift |
            | 79 | harness/Sources/WispCore/Session/ContextComposer.swift |
            | 224 | harness/Sources/WispCore/Session/ThreadRecord.swift |
            | 108 | harness/Sources/WispCore/Session/ThreadRecordSnapshot.swift |
            | 170 | harness/Sources/WispCore/Session/Introspection.swift |
            | 463 | harness/Sources/WispCore/Session/Session.swift |
            | 1469 | total |

            `Session.swift` and `Agent.swift` are the largest, with most of the logic.
            """
        let spans = Presentation.spans(in: reply, outputs: [output])
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(Self.text(of: span, in: reply).hasPrefix("| Lines | File |"))
        #expect(Self.text(of: span, in: reply).hasSuffix("| 1469 | total |"))
        #expect(span.coverage >= 0.8)
    }

    @Test func aTableThatReordersTheColumnsIsNotMatchedAndNeitherIsAnEditedCopy() {
        let output = """
            exit status: 0
            stdout:
                 425 harness/Sources/WispCore/Session/Agent.swift
                  79 harness/Sources/WispCore/Session/ContextComposer.swift
                 224 harness/Sources/WispCore/Session/ThreadRecord.swift
                 108 harness/Sources/WispCore/Session/ThreadRecordSnapshot.swift
                 170 harness/Sources/WispCore/Session/Introspection.swift
                 463 harness/Sources/WispCore/Session/Session.swift
            """
        let reordered = """
            | File | Lines |
            | --- | --- |
            | Agent.swift | 425 |
            | ContextComposer.swift | 79 |
            | ThreadRecord.swift | 224 |
            | ThreadRecordSnapshot.swift | 108 |
            | Introspection.swift | 170 |
            | Session.swift | 463 |
            """
        #expect(Presentation.spans(in: reordered, outputs: [output]).isEmpty)
        // A copy with one value changed carries something the output does not, so it is kept (D12). Written
        // as paragraphs, the unchanged ones before it are exact copies and may go; the changed one stays.
        let edited = Self.config.replacingOccurrences(of: "retries = 3", with: "retries = 5")
        let changed =
            edited.utf8.count - (edited.firstRange(of: "retries = 5").map { edited[$0.lowerBound...].utf8.count } ?? 0)
        let spans = Presentation.spans(in: edited, outputs: [Self.numbered(Self.config)])
        #expect(spans.allSatisfy { !$0.range.contains(changed) })
        let fenced = "```toml\n\(edited)\n```"
        #expect(Presentation.spans(in: fenced, outputs: [Self.numbered(Self.config)]).isEmpty)
    }

    @Test func aProposedEditShownAsAChangedCopyOfTheFileIsKept() {
        let output = Self.numbered(Self.config)
        // The whole file, retyped with one line added and one operator changed: an edit to review.
        let proposed = Self.config.replacingOccurrences(
            of: "checksum = \"sha256\"", with: "checksum = \"sha256\"\ndry_run = false")
        let reply = "With the flag, the profile would read:\n\n```toml\n\(proposed)\n```\n\nShall I write it?"
        #expect(Presentation.spans(in: reply, outputs: [output]).isEmpty)
        // Whitespace and fences are formatting: the same file reindented is still an exact copy.
        let reindented = Self.config.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "  " + $0.replacingOccurrences(of: " = ", with: "   =   ") }
            .joined(separator: "\n")
        #expect(Presentation.spans(in: "~~~\n\(reindented)\n~~~", outputs: [output]).count == 1)
        // One character changed inside a line is a change.
        let operatorChanged = Self.config.replacingOccurrences(
            of: "delete_extraneous = false", with: "delete_extraneous = true")
        #expect(Presentation.spans(in: "```\n\(operatorChanged)\n```", outputs: [output]).isEmpty)
    }

    @Test func linesAreComparedWithoutFormatting() {
        #expect(Presentation.normalised("12\t  let  x =\t1  ") == "let x = 1")
        #expect(Presentation.normalised("| 425 | Agent.swift |") == "425 Agent.swift")
        #expect(Presentation.normalised("   ") == "")
        #expect(Presentation.isTableSeparator("| --- | :-: |") && !Presentation.isTableSeparator("| a | b |"))
        #expect(
            Presentation.occurs(["b", "c"], in: ["a", "b", "c"])
                && !Presentation.occurs(["c", "b"], in: ["a", "b", "c"]))
        #expect(!Presentation.occurs([], in: ["a"]) && !Presentation.occurs(["a", "b"], in: ["a"]))
    }

    @Test func aSummaryThatQuotesOneLineStays() {
        let output = """
            exit status: 1
            stdout:
            Compiling harbour HarbourCore.swift
            Compiling harbour SyncCommand.swift
            Compiling harbour Planner.swift
            Linking harbour
            stderr:
            Undefined symbols for architecture arm64:
              "_CC_SHA256", referenced from: HarbourCore.Checksum.digest(of:) in Checksum.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """
        let reply = """
            The build failed at the link step, after every file compiled. The key line is:

            > ld: symbol(s) not found for architecture arm64

            `_CC_SHA256` comes from CommonCrypto, so the target that computes checksums is missing that \
            dependency; link it in Package.swift and build again.
            """
        #expect(Presentation.spans(in: reply, outputs: [output]).isEmpty)
    }

    @Test func analysisOfAFileStays() {
        let output = Self.numbered(
            """
            # Postmortem: the queue backlog of 12 March

            At 09:40 the order queue began to grow faster than the workers could drain it. The workers were
            healthy, but each job now waited on a slow call to the pricing service, which had been moved to a
            smaller instance the night before. By 10:15 the backlog held forty thousand jobs and customers saw
            confirmations arrive an hour late. The pricing service was moved back at 10:30 and the backlog
            cleared by 11:05. We will alert on queue age, not queue length, and size services before moving them.
            """)
        let reply = """
            The order queue backed up because the pricing service had been moved to a smaller instance, so every \
            job waited on it and confirmations ran an hour late. Moving it back cleared the backlog; the fix is \
            to alert on queue age and to size services before moving them.
            """
        #expect(Presentation.spans(in: reply, outputs: [output]).isEmpty)
    }

    @Test func codeTheModelWroteStays() {
        let output = Self.numbered(
            """
            struct SyncCommand: ParsableCommand {
                @Option(help: "The profile to sync.") var profile: String
                @Flag(help: "Print every file as it is copied.") var verbose = false

                func run() throws {
                    let settings = try Settings.load()
                    let plan = try Planner(settings: settings).plan(profile: profile)
                    for change in plan.changes {
                        try Copier(settings: settings).apply(change)
                        if verbose { print(change.path) }
                    }
                }
            }
            """)
        let reply = """
            Add a flag and return before copying when it is set:

            ```swift
            @Flag(help: "List what would change without changing anything.") var dryRun = false

            func report(_ plan: Plan) {
                let grouped = Dictionary(grouping: plan.changes, by: \\.kind)
                for kind in ChangeKind.allCases {
                    let paths = grouped[kind, default: []].map(\\.path).sorted()
                    print("\\(kind.label) (\\(paths.count)):")
                    paths.forEach { print("  \\($0)") }
                }
            }
            ```

            In `run()`, call `report(plan)` and return when `dryRun` is true, before the copier is created.
            """
        #expect(Presentation.spans(in: reply, outputs: [output]).isEmpty)
    }

    @Test func eachStretchIsMatchedToTheOutputItReproduces() throws {
        let other = Self.numbered("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu")
        let output = Self.numbered(Self.config)
        let reply = "```\n\(Self.config)\n```"
        #expect(Presentation.spans(in: reply, outputs: [other, output]).first?.output == 1)
        #expect(Presentation.spans(in: reply, outputs: []).isEmpty)
        #expect(Presentation.spans(in: reply, outputs: ["too short"]).isEmpty)
        // Below the minimum a stretch stays even when it matches exactly.
        let short = "source = \"~/Pictures/Library\"\ndestination = \"/Volumes/Backup/photos\""
        #expect(Presentation.spans(in: short, outputs: [output]).isEmpty)
    }

    @Test func blocksAreFencesAndParagraphs() {
        let text = "one two\nthree\n\n```swift\nlet x = 1\n\nlet y = 2\n```\n\nafter\n```\nunclosed fence"
        let blocks = Presentation.blocks(text)
        #expect(
            blocks.map(\.words) == [
                ["one", "two", "three"], ["let", "x", "1", "let", "y", "2"], ["after"], ["unclosed", "fence"],
            ])
        let bytes = Array(text.utf8)
        #expect(String(decoding: bytes[blocks[1].range], as: UTF8.self) == "```swift\nlet x = 1\n\nlet y = 2\n```")
        #expect(Presentation.words("BLUE-HERON, 4,127!") == ["blue", "heron", "4", "127"])
    }

    @Test func replacingSkipsRangesThatDoNotFit() {
        #expect(Presentation.replacing("abcdef", [(4..<6, "Y"), (0..<2, "X")]) == "XcdY")
        #expect(Presentation.replacing("abcdef", [(1..<3, "X"), (2..<4, "Y")]) == "aXdef")
        #expect(Presentation.replacing("abc", [(2..<9, "X"), (1..<1, "Y")]) == "abc")
    }
}

/// Cutting in the store, the composer, and the agent.
@Suite struct OutputHandlingTests {
    /// A scratch directory with `harbour.toml` in it.
    private func scratch() throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-output-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "harbour.toml")
        try Data((PresentationTests.config + "\n").utf8).write(to: file)
        return (dir, file)
    }

    /// The text of the last response entry in `transcript`.
    private func lastReply(_ transcript: Transcript) -> String {
        guard let entry = transcript.last(where: { if case .response = $0 { true } else { false } }) else { return "" }
        return ThreadRecord.text(of: entry)
    }

    @Test func theAgentCutsARetypedFileFromLaterRequestsAndAuditsTheCut() async throws {
        let (dir, file) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        let thread = try session.thread(
            id: "show", approver: DenyingApprover(reason: "not in tests"), tools: .named(["read_file"]))
        let shown = "Here it is:\n\n```\n{tool}\n```\n\nTwo tables."
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say(shown), .say("next"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        let reply = try await agent.respond(to: "Show me \(file.path)")
        // The person sees the reply whole, and the store keeps it whole.
        #expect(reply.text.contains("[profile.photos]") && reply.text.hasPrefix("Here it is:"))
        let stored = try #require(agent.store.entries.last { $0.kind == .response })
        #expect(ThreadRecord.text(of: stored.value) == reply.text)
        #expect(stored.cuts.count == 1)
        let output = try #require(agent.store.entries.last { $0.kind == .toolOutput })
        #expect(stored.cuts.first?.output == output.id && stored.cuts.first?.tool == "read_file")
        // The next request carries the marker in its place, under the same id.
        _ = try await agent.respond(to: "and now?")
        let second = try #require(model.script.requests.withLock { $0 }.last)
        let carried = lastReply(second.transcript)
        #expect(carried == "Here it is:\n\n(showed the person the read_file output, entry \(output.id))\n\nTwo tables.")
        #expect(second.transcript.contains { $0.id == stored.value.id })
        // The output itself still goes with its turn.
        #expect(second.transcript.contains { $0.id == output.value.id })
        // One event names the reply, the output, and the audit events that recorded them.
        let event = try #require(sink.events.first { $0.kind == .presentationCut })
        let details = event.details
        #expect(Set(details.keys) == AuditEvent.fields(for: .presentationCut))
        #expect(details["entry"] == .int(stored.id) && details["output"] == .int(output.id))
        #expect(details["tool"] == .string("read_file"))
        #expect(details["response"]?.stringValue == stored.sources.first?.event)
        #expect(details["result"]?.stringValue == output.sources.first?.event)
        #expect(
            (details["bytes"]?.intValue ?? 0) > 400 && details["tokens"] == .int((details["bytes"]?.intValue ?? 0) / 4))
        #expect(details["coverage"] == .double(1) && event.turn == 1)
        // Saved and resumed, the store keeps the cut, and the resumed first request carries the marker.
        try FileManager.default.createDirectory(
            at: dir.appending(path: "transcripts"), withIntermediateDirectories: true)
        let transcripts = TranscriptStore(directory: dir.appending(path: "transcripts"))
        try transcripts.save(agent.store, as: "show")
        let saved = try transcripts.loadThread("show")
        #expect(lastReply(saved.transcript) == "next")
        let resumed = Agent(
            transcript: saved.transcript, tools: agent.tools,
            model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])), links: saved.links)
        #expect(resumed.store.entries.first { $0.id == stored.id }?.cuts == stored.cuts)
        #expect(resumed.transcript.map(\.id) == agent.transcript.map(\.id))
        #expect(
            resumed.transcript.map(ThreadRecord.text(of:)) == agent.transcript.map(ThreadRecord.text(of:)))
    }

    @Test func withCuttingOffTheReplyIsSentAsStoredAndNothingIsAudited() async throws {
        let (dir, file) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "off", sink: sink)
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(file.path)"}"#), .say("```\n{tool}\n```"), .say("next"),
        ])
        let agent = Agent(
            instructions: "x", tools: ToolRegistry(audit: audit).select(["read_file"]).tools,
            model: ResolvedModel(selection: .system, custom: model), audit: audit)
        agent.cutsPresentation = false
        agent.referencesOutput = false
        let reply = try await agent.respond(to: "show it")
        _ = try await agent.respond(to: "and now?")
        let second = try #require(model.script.requests.withLock { $0 }.last)
        #expect(lastReply(second.transcript) == reply.text)
        #expect(!sink.events.contains { $0.kind == .presentationCut })
        #expect(agent.store.entries.allSatisfy { $0.cuts.isEmpty })
    }

    @Test func theComposerCutsOnlyRepliesOfTheTurnThatProducedTheOutput() {
        let segment = { (text: String) in Transcript.Segment.text(.init(content: text)) }
        let output = PresentationTests.numbered(PresentationTests.config)
        let entries: [Transcript.Entry] = [
            .instructions(.init(segments: [segment("x")], toolDefinitions: [])),
            .prompt(.init(segments: [segment("show")])),
            .toolOutput(.init(id: "o1", toolName: "read_file", segments: [segment(output)])),
            .response(.init(assetIDs: [], segments: [segment(PresentationTests.config)])),
            .prompt(.init(segments: [segment("again from memory")])),
            .response(.init(assetIDs: [], segments: [segment(PresentationTests.config)])),
        ]
        var store = ThreadRecord(carrying: Transcript(entries: [entries[0]]))
        for (index, entry) in entries.enumerated().dropFirst() {
            store.record(entry, origin: .turn, turn: index < 4 ? 1 : 2, sources: [])
        }
        var composer = ContextComposer()
        composer.referencesOutput = false
        // The second turn has no tool output, so its retelling is not presentational by this rule.
        #expect(composer.presentation(in: store, turn: 2).isEmpty)
        let found = composer.presentation(in: store, turn: 1)
        #expect(found.map(\.entry) == [4] && found.first?.cut.output == 3)
        #expect(found.first?.cut.start == 0 && found.first?.cut.end == PresentationTests.config.utf8.count)
        store.cut(4, found.map(\.cut))
        store.cut(99, found.map(\.cut))
        let composed = composer.compose(store)
        #expect(ThreadRecord.text(of: Array(composed)[3]) == "(showed the person the read_file output, entry 3)")
        #expect(Array(composed)[3].id == entries[3].id)
        #expect(store.active == Transcript(entries: entries))
        composer.cutsPresentation = false
        #expect(composer.compose(store) == Transcript(entries: entries))
        #expect(composer.presentation(in: store, turn: 1).isEmpty)
    }
}

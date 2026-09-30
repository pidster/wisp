import Foundation
import FoundationModels
import Testing
import WispTestSupport

@testable import WispCore

/// The acceptance test for phase 2 of the layered-context proposal
/// (docs/proposals/2026-09-29-layered-context.md, "Phasing"): the store and the composer must reproduce
/// what `Agent` did when it continued one session, exactly. Each test drives one scripted conversation and
/// compares its fingerprint (every request the model received, every audit event, every reply, every saved
/// context file, and what chat printed) with a snapshot recorded from the code before the change, in
/// `Fixtures/context-equivalence/<name>.json`.
///
/// Phase 3 made cutting presentational text the default. It changes requests by design wherever a reply
/// reproduces its turn's tool output, so every agent here runs with `cutsPresentation` off: the suite
/// still proves that phase 2's structure sends exactly what the code before it did. The cut behaviour is
/// tested on top of it in `OutputHandlingTests`. Phase 3b made sending a tool output as a reference after
/// its turn the default too; every agent here runs with `referencesOutput` off as well, and chat with its
/// output display off, for the same reason (`OutputReferenceTests` and `ChatOutputTests` test those).
/// Phase 4a added facts, which a conversation opened through `Conversation.openAgent` keeps by default; the
/// one agent here opened that way has them off (`agent.facts = nil`), and every other is made directly and
/// keeps none (`FactsTests` and `FactCompositionTests` test them).
///
/// wisp's system prompt is not what this suite checks: phase 3b changed its wording (D12's standing rule
/// that the person sees tool output), so the prompt in force is written back as the phase 2 text before
/// comparing (`phase2SystemPrompt`), and a change of wording needs no new snapshot.
///
/// Random ids (entry and tool-call ids, audit call ids, session ids) and scratch paths are replaced by
/// stable names in order of first appearance, so the comparison still checks that an entry carried from
/// one request to the next keeps its id. Timings are left out. To record a new snapshot deliberately, when
/// a later phase changes behaviour, run with `WISP_RECORD_EQUIVALENCE=1` and review the diff.
@Suite struct ContextEquivalenceTests {
    /// What one conversation did, in a form that can be compared across builds.
    struct Fingerprint: Codable, Equatable {
        /// Each request the model received: its transcript as JSON, its tools, schema, and options.
        var requests: [String] = []
        /// Each audit event: kind, session, turn, call, and details without timings.
        var events: [String] = []
        /// Each reply, or the error a turn threw.
        var replies: [String] = []
        /// Each saved context file, by name, then its contents.
        var archives: [String] = []
        /// What chat printed and noted.
        var output: [String] = []
    }

    /// wisp's system prompt as the snapshots were recorded with it.
    static let phase2SystemPrompt =
        "You are Wisp, a concise assistant running on this Mac. Use the available tools when they help answer "
        + "accurately: call one tool at a time with exact arguments, and wait for its result before deciding what "
        + "to do next. Report tool results faithfully, quoting exit status and output as returned; if a command "
        + "was refused, say so instead of guessing. When a message asks for nothing, such as a greeting, a single "
        + "word, or \"test\", reply briefly and ask what they would like. Keep replies short."

    /// Replaces random ids and scratch paths with stable names.
    struct Canon {
        /// Raw id to stable name.
        var names: [String: String] = [:]
        /// Literal text to replace first, such as a scratch directory's path; wisp's system prompt always
        /// goes back to the phase 2 wording, in each form it takes in a fingerprint (plain and JSON-escaped).
        var literals: [(String, String)]

        /// The system prompt's replacements.
        static let prompt: [(String, String)] = [
            (Prompting.systemPrompt, ContextEquivalenceTests.phase2SystemPrompt),
            (
                Prompting.systemPrompt.replacingOccurrences(of: "\"", with: "\\\""),
                ContextEquivalenceTests.phase2SystemPrompt.replacingOccurrences(of: "\"", with: "\\\"")
            ),
        ]

        /// A canon replacing `literals` first.
        init(literals: [(String, String)] = []) {
            self.literals = literals + Self.prompt
        }

        /// The stable name for `raw`, minted on first sight.
        mutating func name(_ raw: String) -> String {
            if let known = names[raw] { return known }
            let minted = "<id\(names.count + 1)>"
            names[raw] = minted
            return minted
        }

        /// `text` with literals replaced and every UUID and scripted call id named.
        mutating func text(_ text: String) -> String {
            var result = text
            for (from, to) in literals { result = result.replacingOccurrences(of: from, with: to) }
            let pattern =
                #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|call-[0-9A-F]{4}/#
            var output = ""
            var rest = result[...]
            while let match = rest.firstMatch(of: pattern) {
                output += rest[rest.startIndex..<match.range.lowerBound]
                output += name(String(match.output))
                rest = rest[match.range.upperBound...]
            }
            return output + rest
        }

        /// `value` as sorted JSON, canonicalised.
        mutating func json(_ value: some Encodable) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = (try? encoder.encode(value)) ?? Data()
            return text(String(decoding: data, as: UTF8.self))
        }

        /// One request the executor received.
        mutating func request(_ request: LanguageModelExecutorGenerationRequest) -> String {
            let tools = request.enabledToolDefinitions.map(\.name).joined(separator: ",")
            return "tools=[\(tools)] schema=\(request.schema != nil) "
                + "maxTokens=\(request.generationOptions.maximumResponseTokens.map(String.init) ?? "nil") "
                + json(request.transcript)
        }

        /// One audit event without its time, pid, version, or timings.
        mutating func event(_ event: AuditEvent) -> String {
            var details = event.details
            details["seconds"] = nil
            let call = event.call.map { name($0) } ?? "-"
            return "\(event.kind.rawValue) session=\(text(event.session)) turn=\(event.turn.map(String.init) ?? "-") "
                + "call=\(call) \(json(details))"
        }
    }

    /// A fresh scratch directory with two small files for `read_file`.
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-equivalence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("alpha line one\nalpha line two\n".utf8).write(to: dir.appending(path: "a.txt"))
        try Data("beta: the codename is BLUE HERON\n".utf8).write(to: dir.appending(path: "b.txt"))
        return dir
    }

    /// Where the snapshots are, found from this file's place in the repository.
    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/context-equivalence")
    }

    /// Compares `fingerprint` with the recorded snapshot `name`, or records it under `WISP_RECORD_EQUIVALENCE=1`.
    private func check(_ fingerprint: Fingerprint, _ name: String) throws {
        let file = Self.fixtures.appending(path: "\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["WISP_RECORD_EQUIVALENCE"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try encoder.encode(fingerprint).write(to: file, options: .atomic)
            return
        }
        let recorded = try JSONDecoder().decode(Fingerprint.self, from: Data(contentsOf: file))
        #expect(fingerprint.requests.count == recorded.requests.count, "requests")
        for (index, pair) in zip(fingerprint.requests, recorded.requests).enumerated() {
            #expect(pair.0 == pair.1, "request \(index + 1)")
        }
        #expect(fingerprint.events == recorded.events)
        #expect(fingerprint.replies == recorded.replies)
        #expect(fingerprint.archives == recorded.archives)
        #expect(fingerprint.output == recorded.output)
    }

    /// Fills in the requests, events, and saved files of a finished conversation.
    private func finish(
        _ fingerprint: inout Fingerprint, _ canon: inout Canon, models: [ScriptedModel], sink: MemoryAuditSink,
        archive: URL?
    ) throws {
        for model in models {
            for request in model.script.requests.withLock({ $0 }) {
                fingerprint.requests.append(canon.request(request))
            }
        }
        fingerprint.events = sink.events.map { canon.event($0) }
        guard let archive, FileManager.default.fileExists(atPath: archive.path) else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted() {
            let contents = try String(contentsOf: archive.appending(path: name), encoding: .utf8)
            fingerprint.archives.append(canon.text(name))
            fingerprint.archives.append(canon.text(contents))
        }
    }

    /// Runs `body`, recording its reply or the error it threw.
    private func reply(
        _ fingerprint: inout Fingerprint, _ body: () async throws -> Agent.Reply
    ) async {
        do {
            let reply = try await body()
            fingerprint.replies.append("\(reply.condensed ? "condensed " : "")\(reply.text)")
        } catch {
            fingerprint.replies.append("error: \(error)")
        }
    }

    @Test func toolsCondensingAheadAndArchives() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var canon = Canon(literals: [(dir.path, "<dir>")])
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "eq", sink: sink)
        let a = dir.appending(path: "a.txt").path
        let b = dir.appending(path: "b.txt").path
        let model = ScriptedModel(steps: [
            .say("one"), .call(name: "read_file", arguments: #"{"path":"\#(a)"}"#), .say("A says {tool}"),
            .say("three"), .call(name: "read_file", arguments: #"{"path":"\#(b)"}"#), .say("B: {tool}"),
            .say(#"{"answer":5}"#), .say("six streamed words here"), .say("seven"), .say("eight"),
        ])
        // The scripted runtime reports 40 input tokens a request; on a 60-token window a prompt of 44 bytes or
        // more passes the 85% budget, so long prompts condense ahead once there are more than four turns.
        let agent = Agent(
            instructions: "Be brief.", tools: ToolRegistry(audit: audit).select(["read_file"]).tools,
            model: ResolvedModel(selection: .system, custom: model, contextSize: 60), audit: audit)
        agent.cutsPresentation = false
        agent.referencesOutput = false
        agent.archive = ContextArchive(directory: dir.appending(path: "context"), session: "eq")
        var fingerprint = Fingerprint()
        let long = " This sentence makes the prompt long enough to pass the budget."
        let schema = try OutputSchema(json: ["type": "object", "properties": ["answer": ["type": "integer"]]])
        await reply(&fingerprint) { try await agent.respond(to: "short one") }
        await reply(&fingerprint) { try await agent.respond(to: "Read \(a) with read_file." + long) }
        await reply(&fingerprint) { try await agent.respond(to: "three") }
        await reply(&fingerprint) { try await agent.respond(to: "Read \(b) with read_file." + long) }
        await reply(&fingerprint) { try await agent.respond(to: "How many?" + long, schema: schema) }
        var streamed: [String] = []
        await reply(&fingerprint) { try await agent.stream("Stream six." + long) { streamed.append($0) } }
        fingerprint.replies.append("streamed: \(streamed.joined(separator: "|"))")
        await reply(&fingerprint) { try await agent.respond(to: "seven" + long) }
        await reply(&fingerprint) { try await agent.respond(to: "eight, short") }
        fingerprint.replies.append("condensations \(agent.condensations), turns \(agent.transcript.turnCount)")
        fingerprint.output.append(canon.json(agent.transcript))
        try finish(&fingerprint, &canon, models: [model], sink: sink, archive: dir.appending(path: "context"))
        try check(fingerprint, "tools-condensing-ahead-archives")
    }

    @Test func overflowRetryFailedTurnsAndFailFast() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var canon = Canon(literals: [(dir.path, "<dir>")])
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "ov", sink: sink)
        let a = dir.appending(path: "a.txt").path
        // The first request streams "Hel" and overflows; the retry answers. A call to a tool the session does
        // not have fails its turn; the conversation continues after it.
        let model = ScriptedModel(
            steps: [
                .say("Hello again"), .call(name: "read_file", arguments: #"{"path":"\#(a)"}"#), .say("read {tool}"),
                .call(name: "nope", arguments: "{}"), .say("after the failure"), .say("last"),
            ], overflowOnce: true, partialBeforeOverflow: "Hel")
        let agent = Agent(
            instructions: "Be brief.", tools: ToolRegistry(audit: audit).select(["read_file"]).tools,
            model: ResolvedModel(selection: .system, custom: model), contextPolicy: .condense(keepTurns: 1),
            audit: audit)
        agent.cutsPresentation = false
        agent.referencesOutput = false
        agent.archive = ContextArchive(directory: dir.appending(path: "context"), session: "ov")
        var fingerprint = Fingerprint()
        var streamed: [String] = []
        await reply(&fingerprint) { try await agent.stream("first") { streamed.append($0) } }
        fingerprint.replies.append("streamed: \(streamed.joined(separator: "|"))")
        await reply(&fingerprint) { try await agent.respond(to: "read \(a)") }
        await reply(&fingerprint) { try await agent.respond(to: "call a missing tool") }
        await reply(&fingerprint) { try await agent.respond(to: "carry on") }
        await reply(&fingerprint) { try await agent.respond(to: "and finish") }
        fingerprint.replies.append("condensations \(agent.condensations), window \(agent.contextSize ?? 0)")
        fingerprint.output.append(canon.json(agent.transcript))
        // Fail fast: the overflow propagates and the next turn goes on from what the session kept.
        let failing = ScriptedModel(steps: [.say("second try")], overflowOnce: true)
        let strict = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: failing),
            contextPolicy: .failFast, audit: audit)
        strict.cutsPresentation = false
        strict.referencesOutput = false
        await reply(&fingerprint) { try await strict.respond(to: "boom") }
        await reply(&fingerprint) { try await strict.respond(to: "again") }
        fingerprint.output.append(canon.json(strict.transcript))
        try finish(&fingerprint, &canon, models: [model, failing], sink: sink, archive: dir.appending(path: "context"))
        try check(fingerprint, "overflow-failure-failfast")
    }

    @Test func aModelThatCountsInsteadOfReporting() async throws {
        var canon = Canon()
        let sink = MemoryAuditSink()
        let model = ScriptedModel(steps: [.say("one"), .say("two"), .say("three"), .say("four")], reportsUsage: false)
        let agent = Agent(
            instructions: "x", tools: [],
            model: ResolvedModel(
                selection: .system, custom: model, contextSize: 100,
                countTokens: { transcript in transcript.turnCount * 30 }),
            contextPolicy: .condense(keepTurns: 1), audit: AuditLog(session: "count", sink: sink))
        agent.cutsPresentation = false
        agent.referencesOutput = false
        var fingerprint = Fingerprint()
        for prompt in ["first", "second", "third", "fourth"] {
            await reply(&fingerprint) { try await agent.respond(to: prompt) }
            let tokens = try await agent.contextTokens()
            fingerprint.replies.append("tokens \(tokens.map(String.init) ?? "nil")")
        }
        fingerprint.output.append(canon.json(agent.transcript))
        try finish(&fingerprint, &canon, models: [model], sink: sink, archive: nil)
        try check(fingerprint, "counting-model")
    }

    @Test func resetAndResume() async throws {
        var canon = Canon()
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "rr", sink: sink)
        let model = ScriptedModel(steps: [.say("one"), .say("two"), .say("three")])
        let agent = Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: model, contextSize: 60),
            audit: audit)
        agent.cutsPresentation = false
        agent.referencesOutput = false
        var fingerprint = Fingerprint()
        await reply(&fingerprint) { try await agent.respond(to: "first") }
        await reply(&fingerprint) { try await agent.respond(to: "second") }
        agent.reset()
        fingerprint.output.append(canon.json(agent.transcript))
        await reply(&fingerprint) { try await agent.respond(to: "after reset") }
        // Resumed from the saved transcript, as `--resume` does, on another model.
        let saved = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(agent.transcript))
        let next = ScriptedModel(steps: [.say("resumed"), .say("again")])
        let resumed = Agent(
            transcript: saved, tools: [], model: ResolvedModel(selection: .system, custom: next, contextSize: 60),
            audit: audit)
        resumed.cutsPresentation = false
        resumed.referencesOutput = false
        await reply(&fingerprint) { try await resumed.respond(to: "after resume") }
        await reply(&fingerprint) {
            try await resumed.respond(to: "a long prompt after resuming, long enough to pass the budget")
        }
        fingerprint.output.append(canon.json(resumed.transcript))
        try finish(&fingerprint, &canon, models: [model, next], sink: sink, archive: nil)
        try check(fingerprint, "reset-resume")
    }

    @Test func chatWithAModelSwitch() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var canon = Canon(literals: [(dir.path, "<dir>")])
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "chat", sink: sink)
        let a = dir.appending(path: "a.txt").path
        let archive = ContextArchive(directory: dir.appending(path: "context"), session: "chat")
        let tools = ToolRegistry(audit: audit).select(["read_file"]).tools
        let first = ScriptedModel(steps: [
            .say("noted"), .call(name: "read_file", arguments: #"{"path":"\#(a)"}"#), .say("it says {tool}"),
            .say("third"),
        ])
        let second = ScriptedModel(steps: [
            .say("from the new model"), .say("more"), .say("sixth"), .say("after new"),
        ])
        let agent = Agent(
            instructions: "Be brief.", tools: tools,
            model: ResolvedModel(selection: .system, custom: first, contextSize: 60), audit: audit)
        agent.cutsPresentation = false
        agent.referencesOutput = false
        agent.archive = archive
        let context = ChatLoop.Context(
            directory: "/r", approval: "--yes",
            openModel: { selection, store in
                let switched = Agent(
                    store: store, tools: tools,
                    model: ResolvedModel(selection: selection, custom: second, contextSize: 60), audit: audit)
                switched.cutsPresentation = false
                switched.referencesOutput = false
                switched.archive = archive
                return switched
            })
        let long = " This sentence makes the prompt long enough to pass the budget."
        try FileManager.default.createDirectory(
            at: dir.appending(path: "transcripts"), withIntermediateDirectories: true)
        let capture = ChatLoopTests.Capture(lines: [
            "remember BLUE HERON", "read \(a) with read_file" + long, "third" + long, "/tokens", "/model ollama:q",
            "fourth" + long, "fifth" + long, "sixth" + long, "/tokens", "/inspect context", "/save one", "/new",
            "after new", "/tokens",
            "/quit",
        ])
        var loop = ChatLoop(
            agent: agent, store: TranscriptStore(directory: dir.appending(path: "transcripts")), saveName: nil,
            context: context, io: capture.io)
        try await loop.run()
        var fingerprint = Fingerprint()
        fingerprint.output = [canon.text(capture.output)] + capture.noted.map { canon.text($0) }
        fingerprint.output.append(canon.json(loop.agent.transcript))
        let saved = try TranscriptStore(directory: dir.appending(path: "transcripts")).load("one")
        fingerprint.output.append(canon.json(saved))
        try finish(&fingerprint, &canon, models: [first, second], sink: sink, archive: dir.appending(path: "context"))
        try check(fingerprint, "chat-model-switch")
    }

    @Test func anMCPThreadThroughSessionConversation() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = Home(root: dir.appending(path: "home"))
        try home.ensure()
        let sink = MemoryAuditSink()
        let session = try Session.begin(.init(entryPoint: .mcp), home: home, dependencies: .testing(sink: sink))
        var canon = Canon(literals: [(dir.path, "<dir>"), (session.audit.session, "<session>")])
        let conversation = try session.conversation(
            id: "thread-1", approver: DenyingApprover(reason: "not in tests"), instructions: "Be brief.",
            tools: .named(["read_file"]))
        let a = dir.appending(path: "a.txt").path
        let b = dir.appending(path: "b.txt").path
        let model = ScriptedModel(steps: [
            .call(name: "read_file", arguments: #"{"path":"\#(a)"}"#), .say("A: {tool}"), .say("two"),
            .call(name: "read_file", arguments: #"{"path":"\#(b)"}"#), .say("B: {tool}"), .say("four"), .say("five"),
            .say("six"),
        ])
        let agent = try conversation.openAgent(
            on: ResolvedModel(selection: .system, custom: model, contextSize: 60))
        agent.cutsPresentation = false
        agent.referencesOutput = false
        agent.facts = nil
        var fingerprint = Fingerprint()
        let long = " This sentence makes the prompt long enough to pass the budget."
        for (index, prompt) in ["read \(a)", "two", "read \(b)" + long, "four" + long, "five" + long, "six" + long]
            .enumerated()
        {
            await reply(&fingerprint) { try await agent.respond(to: prompt) }
            let receipt = canon.json(conversation.receipts.take(turn: index + 1).json)
            fingerprint.replies.append(receipt.replacing(#/"seconds":[-0-9.eE+]+/#, with: #""seconds":0"#))
        }
        fingerprint.output.append(canon.json(agent.transcript))
        try finish(&fingerprint, &canon, models: [model], sink: sink, archive: home.contexts)
        try check(fingerprint, "mcp-thread")
    }
}

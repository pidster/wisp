import Foundation
import FoundationModels
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// Output past the budget through the whole stack (ADR 0050): a command's long output held back and kept, the
/// model paging it by the output id within the turn and by its entry after, filtering it, the exact summaries,
/// and the condensing question answered by a scripted model; no command is ever run again to see it.
@Suite struct HeldBackOutputTests {
    /// A session over a scratch home with the audit on a memory sink and a file, so the store and the recall
    /// have something to read.
    private func session() throws -> (Session, MemoryAuditSink, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-held-\(UUID().uuidString)")
        let home = Home(root: dir)
        try home.ensure()
        let sink = MemoryAuditSink()
        let dependencies = Session.Dependencies(
            makeClassifier: { _, _ in RuleRiskClassifier.standard },
            makeSink: { home, config in
                TeeAuditSink([sink, try FileAuditSink(url: home.auditFile, limits: config.auditLimits)])
            })
        return (try Session.begin(.init(entryPoint: .respond), home: home, dependencies: dependencies), sink, dir)
    }

    /// A shell loop printing `lines` numbered lines to stdout.
    private func printing(_ lines: Int) -> String {
        "i=1; while [ $i -le \(lines) ]; do echo \"row $i: the quick brown fox jumps over the lazy dog\"; i=$((i+1)); done"
    }

    @Test func aLongCommandOutputIsHeldBackKeptAndPagedByTheModel() async throws {
        let (session, sink, dir) = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thread = try session.thread(
            id: "held", approver: DenyingApprover(reason: "not in tests"), tools: .named(["run_command", "memory"]))
        let command = printing(600)
        let model = ScriptedModel(steps: [
            .call(
                name: "run_command",
                arguments: Introspection.render(.object(["command": .string(command)]), compact: true)),
            // The marker's own words: page the stored output from where the held-back part begins, in the same turn.
            .say("MARKER:{tool}"),
            .say("second"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        agent.contextSize = 8192
        let first = try await agent.respond(to: "run it")
        // What the model saw: within the budget, head and tail, the marker, and the note naming the stored output.
        let shown = first.text.dropFirst("MARKER:".count)
        #expect(shown.utf8.count <= 4096 + 64, "\(shown.utf8.count)")
        #expect(shown.hasPrefix("exit status: 0\nstdout:\nrow 1: the quick") && shown.contains("row 600: the quick"))
        let note = try #require(shown.split(separator: "\n").first { $0.hasPrefix("held back: stdout lines ") })
        let id = try #require(note.firstMatch(of: #/kept as output ([0-9a-f]{8})/#).map { String($0.1) })
        #expect(note.contains("memory \"recall output \(id) from line "))
        #expect(note.hasSuffix("do not run the command again to see it"))
        // The store holds the whole output, audited by size and hash, under the tool call's id.
        let kept = try #require(thread.outputs?.kept(id))
        #expect(kept.lines == 602 && kept.tool == "run_command")
        let call = try #require(sink.events.first { $0.kind == .toolCall })
        #expect(call.call == id)
        #expect(sink.events.contains { $0.kind == .outputKept && $0.call == id })
        let result = try #require(sink.events.first { $0.kind == .toolResult })
        #expect(result.call == id && (result.details["bytes"]?.intValue ?? 0) <= 4096 + 64)
        // Within the turn, before the entry exists, the output is reachable by its id; the first page starts at
        // the held-back line the note names, and names the next.
        let memory = MemoryTool(
            source: try #require(agent.memory), audit: thread.audit, budget: thread.budget, store: thread.outputs)
        let line = Int(note.firstMatch(of: #/from line (\d+)/#).map { String($0.1) } ?? "") ?? 0
        let page = await memory.call(arguments: .init(request: "recall output \(id) from line \(line)"))
        #expect(page.hasPrefix("output \(id): run_command, 602 lines, "))
        #expect(page.contains("from the output store"))
        #expect(page.split(separator: "\n")[1].hasPrefix("row \(line - 2): "))
        #expect(page.contains("[more: memory \"recall output \(id) from line "))
        #expect(page.utf8.count <= 4096 + 400)
        // Filters read what is stored and number their lines; a filter continues into its own pages.
        let matched = await memory.call(arguments: .init(request: "recall output \(id) matching row 59[0-9]:"))
        #expect(matched.contains("; 10 of 602 lines matching row 59[0-9]:"))
        #expect(matched.contains("\n592: row 590: the quick") && matched.hasSuffix("[end of what recall found]"))
        let tail = await memory.call(arguments: .init(request: "recall output \(id) tail 2"))
        #expect(tail.contains("the last 2 of 602 lines") && tail.contains("\n602: row 600: the quick"))
        let range = await memory.call(arguments: .init(request: "recall output \(id) lines 3-4"))
        #expect(
            range.contains("\n3: row 1: the quick") && range.contains("\n4: row 2: the quick")
                && range.hasSuffix("[end of what recall found]"))
        let recalls = sink.events.filter { $0.kind == .memory }
        #expect(recalls.last?.details["filter"] == "lines" && recalls.last?.details["output"] == .string(id))
        #expect(recalls.first?.details["target"] == "output")
        #expect(recalls.allSatisfy { Set($0.details.keys).isSubset(of: AuditEvent.fields(for: .memory)) })
        // After the turn, the entry's reference stands for it, and recalling the entry gives the whole from the
        // store, not the bounded result the audit's tool.result holds.
        _ = try await agent.respond(to: "second")
        let entry = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        let whole = await memory.call(arguments: .init(request: "recall entry \(entry.id)"))
        #expect(whole.contains(", the whole output from the output store (602 lines)"))
        #expect(whole.contains("; arguments: {\"command\": ") && whole.contains("\nrow 5: the quick"))
        #expect(!whole.contains("held back …]"))
        let requests = model.script.requests.withLock { $0 }
        let referenced = try #require(requests.last?.transcript.first { $0.id == entry.value.id })
        #expect(ThreadRecord.text(of: referenced).contains("to see it: memory \"recall entry \(entry.id)\""))
        // The command ran once.
        #expect(sink.events.count { $0.kind == .commandOutcome } == 1)
        // The resource serves the whole stored output, paged, under the thread's audit session directory.
        #expect(thread.outputs?.directory.lastPathComponent == "held")
    }

    @Test func summarisingAStoredOutputUsesExactReadersAndCondensingAsksTheModel() async throws {
        let (session, sink, dir) = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        let thread = try session.thread(
            id: "sum", approver: DenyingApprover(reason: "not in tests"), tools: .named(["run_command", "memory"]))
        // A build log in a known format, long enough to be held back at the floor: a warning, then one error whose
        // cascade follows it, then a summary line, and a non-zero exit status.
        let script = """
            i=1; while [ $i -le 150 ]; do echo "Compiling Sources/File$i.swift"; i=$((i+1)); done; \
            echo "Sources/A.swift:10:5: warning: unused variable 'x'"; \
            echo "Sources/B.swift:42:9: error: cannot find 'frob' in scope"; \
            echo "    frob(1)"; echo "    ^~~~"; \
            echo "Sources/B.swift:50:1: error: expected '}'"; \
            i=1; while [ $i -le 100 ]; do echo "Compiling Sources/More$i.swift"; i=$((i+1)); done; \
            echo "error: fatalError: 1 of 3 targets failed"; exit 1
            """
        let condensed = OutputCondenser()
        let model = ScriptedModel(steps: [
            .call(
                name: "run_command",
                arguments: Introspection.render(.object(["command": .string(script)]), compact: true)),
            .say("ran"), .say("two"),
        ])
        let agent = try thread.openAgent(on: ResolvedModel(selection: .system, custom: model))
        _ = try await agent.respond(to: "build")
        _ = try await agent.respond(to: "two")
        let entry = try #require(agent.store.entries.first { $0.kind == .toolOutput })
        let memory = MemoryTool(
            source: try #require(agent.memory), audit: thread.audit, budget: thread.budget, store: thread.outputs,
            condenser: condensed)
        let notable = await memory.call(arguments: .init(request: "summarise entry \(entry.id)"))
        #expect(notable.hasPrefix("notable lines (exact readers, no model): 258 lines, "), "\(notable)")
        #expect(notable.contains("exit status 1 (failed)"))
        #expect(notable.contains("2 errors in 1 place; the first of each, root causes first:"))
        #expect(
            notable.contains(" error at Sources/B.swift:42:9: cannot find 'frob' in scope (+1 more in Sources/B.swift)")
        )
        #expect(
            notable.contains("L154 error at Sources") && notable.contains("  L155:     frob(1)")
                && notable.contains("  L156:     ^~~~"))
        #expect(notable.contains("1 warning (Sources/A.swift ×1)"))
        #expect(notable.utf8.count <= 4096)
        let overview = await memory.call(arguments: .init(request: "summarize entry \(entry.id) overview"))
        #expect(overview.hasPrefix("overview (exact readers, no model): 258 lines, "))
        #expect(overview.contains("mentioning an error or failure") && overview.contains("first lines:"))
        #expect(
            await memory.call(arguments: .init(request: "summarise turn 1")).hasPrefix("error: name a stored entry"))
        // Condense: without a model attached it says so; with one, each chunk is asked the question and the answers
        // combined; a chunk that has nothing is left out.
        let off = await memory.call(arguments: .init(request: "condense entry \(entry.id): why did it fail"))
        #expect(off.hasPrefix("error: condense needs the conversation's model"))
        let prompts = Mutex<[String]>([])
        condensed.attach { prompt in
            prompts.withLock { $0.append(prompt) }
            return prompt.contains("cannot find 'frob'") ? "frob is undefined at Sources/B.swift:42:9" : "nothing here"
        }
        let answer = await memory.call(arguments: .init(request: "condense entry \(entry.id): why did it fail"))
        #expect(answer.hasPrefix("condensed answer to \"why did it fail\" from 258 lines in "), "\(answer)")
        #expect(answer.contains("by the model:\npart "), "\(answer)")
        #expect(answer.contains("frob is undefined at Sources/B.swift:42:9") && !answer.contains("nothing here"))
        let asked = prompts.withLock { $0 }
        #expect(asked.count >= 2 && asked.allSatisfy { $0.contains("why did it fail") && $0.utf8.count <= 4096 + 600 })
        #expect(
            await memory.call(arguments: .init(request: "condense entry \(entry.id)")).hasPrefix(
                "error: write condense entry N: QUESTION"))
        let events = sink.events.filter { $0.kind == .memory }
        #expect(
            events.map { $0.details["action"] } == [
                "summarise", "summarise", "summarise", "condense", "condense", "condense",
            ])
        #expect(events[0].details["summary"] == "notable" && events[1].details["summary"] == "overview")
        #expect(events[4].details["chunks"]?.intValue == asked.count && events[3].details["failure"] == "off")
        #expect(events.allSatisfy { Set($0.details.keys).isSubset(of: AuditEvent.fields(for: .memory)) })
        // The command ran once: summaries and questions read the store.
        #expect(sink.events.count { $0.kind == .commandOutcome } == 1)
    }

    @Test func summariesReadLogsJSONAndPlainTextWithoutAModel() {
        let log =
            (1...30).map { "2026-10-11T10:00:\(String(format: "%02d", $0)) INFO request \($0) served in 12ms" }
            + ["2026-10-11T10:01:00 ERROR database connection refused", "2026-10-11T10:01:01 WARN retrying"]
        let notable = OutputSummary.notable(log, tool: nil)
        #expect(notable[0].hasPrefix("notable lines (exact readers, no model): 32 lines"))
        #expect(notable.contains { $0.hasPrefix("log: ") && $0.contains("1 error") })
        #expect(notable.contains { $0.contains("database connection refused") && $0.hasPrefix("error ×1 L31") })
        let json = ["{\"a\": [1, 2, 3], \"b\": {\"c\": \"x\"}}"]
        #expect(OutputSummary.notable(json, tool: nil).contains { $0.hasPrefix("JSON: ") })
        let plain = (1...20).map { "paragraph \($0) of prose" }
        let overview = OutputSummary.overview(plain, tool: nil)
        #expect(overview[1] == "lines: 0 blank, 0 mentioning an error or failure, 0 mentioning a warning")
        #expect(
            overview.contains("first lines:") && overview.contains("last lines:")
                && overview.last == "L20: paragraph 20 of prose")
        let none = OutputSummary.notable(plain, tool: nil)
        #expect(none.contains { $0.hasPrefix("no error lines; no reader explains this output") })
        let succeeded = ["exit status: 0", "stdout:", "Build complete! (2.1s)"]
        #expect(OutputSummary.notable(succeeded, tool: "run_command")[0].hasSuffix("exit status 0 (succeeded)"))
        #expect(OutputSummary.looksLikeHeading("==> build") && OutputSummary.looksLikeHeading("Tests:"))
        #expect(!OutputSummary.looksLikeHeading("a long sentence of prose that ends with a colon anyway:"))
    }
}

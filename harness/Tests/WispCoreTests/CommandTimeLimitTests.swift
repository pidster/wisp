import Foundation
import Testing

@testable import WispCore

/// `run_command`'s time limits (ADR 0063): the call's `timeoutSeconds` over the thread's over the operator's
/// default, a request clamped to `commandMaxTimeoutSeconds`, the limit recorded in `command.outcome`, and a
/// timed-out result that says how to ask for longer.
@Suite struct CommandTimeLimitTests {
    /// A runner in a scratch directory with `seconds` as the default and `cap` as the most a request may be.
    private func runner(
        default seconds: Duration, cap: Duration, sink: MemoryAuditSink = MemoryAuditSink()
    ) throws -> (runner: CommandRunner, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = CommandRunner(
            options: .init(writableRoot: dir.path, timeout: seconds, maxTimeout: cap),
            audit: AuditLog(session: "s", sink: sink))
        return (runner, dir)
    }

    /// The details of the last `command.outcome` the sink holds.
    private func lastOutcome(_ sink: MemoryAuditSink) -> [String: JSONValue] {
        sink.events.last { $0.kind == .commandOutcome }?.details ?? [:]
    }

    @Test func theLimitIsTheRequestClampedToTheCapElseTheOperatorsDefault() throws {
        let (runner, dir) = try runner(default: .seconds(120), cap: .seconds(600))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(runner.limit(for: .person, requested: .init(seconds: 30, source: .call)) == nil)
        #expect(
            runner.limit(for: .model)
                == .init(seconds: 120, source: .default, cap: 600, askable: false))
        #expect(
            runner.limit(for: .model, requested: .init(seconds: nil, source: .thread))
                == .init(seconds: 120, source: .default, cap: 600, askable: true))
        #expect(
            runner.limit(for: .model, requested: .init(seconds: 300, source: .thread))
                == .init(seconds: 300, source: .thread, cap: 600, askable: true))
        #expect(
            runner.limit(for: .model, requested: .init(seconds: 5_000, source: .call))
                == .init(seconds: 600, source: .call, clamped: true, cap: 600, askable: true))
        // The operator's own default is not clamped, and 0 means no limit.
        var options = runner.options
        options.timeout = .seconds(3_600)
        #expect(CommandRunner(options: options).limit(for: .model)?.seconds == 3_600)
        options.timeout = .zero
        #expect(CommandRunner(options: options).limit(for: .model)?.seconds == nil)
    }

    @Test func aCallsTimeoutSecondsOutlastsTheDefaultAndIsRecorded() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .seconds(1), cap: .seconds(10), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "sleep 2; echo done", workingDirectory: dir.path, timeoutSeconds: 5))
        #expect(result.contains("exit status: 0") && result.contains("done"), "\(result)")
        let details = lastOutcome(sink)
        #expect(details["timeoutSource"] == "call" && details["timeoutSeconds"] == 5)
        #expect(details["timeoutClamped"] == nil)
    }

    @Test func aRequestAboveTheCapIsClampedToIt() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .seconds(30), cap: .seconds(1), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "sleep 3; echo done", workingDirectory: dir.path, timeoutSeconds: 60))
        #expect(result.contains("timed out: the command was killed after 1 s, the most allowed"), "\(result)")
        #expect(!result.contains("done"))
        let details = lastOutcome(sink)
        #expect(details["timedOut"] == true && details["timeoutSeconds"] == 1 && details["timeoutClamped"] == true)
    }

    @Test func aTimedOutResultNamesTheLimitAndHowToAskForMore() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .seconds(1), cap: .seconds(5), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "sleep 3", workingDirectory: dir.path))
        #expect(
            result.contains("timed out: the command was killed after 1 s; ask for up to 5 s with timeoutSeconds"),
            "\(result)")
        let details = lastOutcome(sink)
        #expect(details["timeoutSource"] == "default" && details["timeoutSeconds"] == 1)
    }

    @Test func aTimeoutSecondsBelowOneIsAnErrorTheModelReads() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .seconds(1), cap: .seconds(5), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        for seconds in [0, -3] {
            let result = await RunCommandTool(runner: runner).call(
                arguments: .init(command: "echo hi", workingDirectory: dir.path, timeoutSeconds: seconds))
            #expect(result.hasPrefix("error: timeoutSeconds must be at least 1"), "\(result)")
        }
        #expect(sink.events.isEmpty, "nothing ran")
    }

    @Test func theThreadsLimitIsTheDefaultForItsCallsAndACallsOwnWins() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .seconds(1), cap: .seconds(10), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tool = RunCommandTool(runner: runner, threadTimeout: 5)
        let outlasted = await tool.call(arguments: .init(command: "sleep 2; echo done", workingDirectory: dir.path))
        #expect(outlasted.contains("done"), "\(outlasted)")
        #expect(lastOutcome(sink)["timeoutSource"] == "thread" && lastOutcome(sink)["timeoutSeconds"] == 5)
        let cut = await tool.call(
            arguments: .init(command: "sleep 2; echo done", workingDirectory: dir.path, timeoutSeconds: 1))
        #expect(cut.contains("killed after 1 s") && !cut.contains("done"), "\(cut)")
        #expect(lastOutcome(sink)["timeoutSource"] == "call")
        // Another tool over the same runner, as another thread's would be, keeps the default.
        let other = await RunCommandTool(runner: runner).call(
            arguments: .init(command: "sleep 2; echo done", workingDirectory: dir.path))
        #expect(other.contains("killed after 1 s"), "\(other)")
        #expect(lastOutcome(sink)["timeoutSource"] == "default")
    }

    @Test func anOperatorDefaultOfZeroIsNoLimit() async throws {
        let sink = MemoryAuditSink()
        let (runner, dir) = try runner(default: .zero, cap: .seconds(5), sink: sink)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try await runner.run("sleep 1; echo done", in: dir.path)
        #expect(!outcome.timedOut && outcome.stdout == "done\n")
        let details = lastOutcome(sink)
        #expect(details["timeoutSource"] == "default" && details["timeoutSeconds"] == nil)
    }

    @Test func wispConfigKnowsBothSettingsAndTheirDefaults() throws {
        #expect(ConfigSettings.defaultValue("commandTimeoutSeconds") == 120)
        #expect(ConfigSettings.defaultValue("commandMaxTimeoutSeconds") == 1800)
        let cap = try #require(ConfigSettings.setting("commandMaxTimeoutSeconds"))
        #expect(cap.kind == .integer(1...86_400))
        let set = try ConfigEdit.set("commandMaxTimeoutSeconds", to: "3600", in: nil)
        #expect(set.new == 3600)
        #expect(try JSONDecoder().decode(Config.self, from: set.data).resolved.runner.maxTimeout == .seconds(3600))
        for refused in ["0", "86401", "soon"] {
            #expect(throws: ConfigEdit.Failure.self, "\(refused)") {
                try ConfigEdit.set("commandMaxTimeoutSeconds", to: refused, in: nil)
            }
        }
    }

    @Test func theLimitsTextStatesTheDefaultAndTheCap() throws {
        let (runner, dir) = try runner(default: .seconds(120), cap: .seconds(1800))
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(
            RunCommandTool(runner: runner).limits.contains(
                "Timeout 120 s; timeoutSeconds asks for another, up to 1800 s (commandMaxTimeoutSeconds)."))
        #expect(RunCommandTool(runner: runner, threadTimeout: 600).limits.contains("Timeout 600 s (this thread's)"))
        #expect(RunCommandTool(runner: runner, threadTimeout: 9_999).limits.contains("Timeout 1800 s (this thread's)"))
        let tool = ToolRegistry().descriptions.first { $0.name == "run_command" }
        guard case .object(let schema)? = tool?.parameters, case .object(let properties)? = schema["properties"],
            case .object(let timeout)? = properties["timeoutSeconds"]
        else {
            Issue.record("no timeoutSeconds in the schema")
            return
        }
        #expect(timeout["type"] == "integer")
        #expect(timeout["description"]?.stringValue?.contains("Omit for the default") == true)
    }
}

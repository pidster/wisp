import Foundation
import MCP
import Testing
import WispCore

@testable import WispMCP

@Suite struct ToolCatalogTests {
    @Test func advertisesRespondAndRunCommand() {
        #expect(
            ToolCatalog.all.map(\.name) == [
                "respond", "triage", "summarise_diff", "draft_change", "scan_secrets", "redact", "condense_log",
                "json_shape", "dependency_audit", "flaky_tests", "hot_paths", "set_fact_scope", "close_thread",
            ])
    }

    @Test func everyToolHasAnObjectSchemaWithRequiredFields() {
        for tool in ToolCatalog.all {
            let schema = tool.inputSchema.objectValue
            #expect(schema?["type"]?.stringValue == "object", "\(tool.name)")
            #expect(schema?["required"]?.arrayValue != nil, "\(tool.name)")
        }
    }

    @Test func setFactScopeOffersOnlyThreadAndSession() throws {
        let schema = try #require(ToolCatalog.setFactScope.inputSchema.objectValue)
        let scope = try #require(schema["properties"]?.objectValue?["scope"]?.objectValue)
        #expect(scope["enum"]?.arrayValue?.compactMap(\.stringValue) == ["thread", "session"])
        #expect(schema["required"]?.arrayValue?.compactMap(\.stringValue) == ["thread_id", "fact_id", "scope"])
        let request = try SetFactScopeRequest(arguments: [
            "thread_id": "git", "fact_id": "c3", "scope": "session",
        ])
        #expect(request.threadID == "git" && request.factID == "c3" && request.scope == .session)
        for (arguments, message) in [
            (["thread_id": "git", "fact_id": "c3", "scope": "permanent"], "set from chat"),
            (["thread_id": "git", "fact_id": "p1", "scope": "thread"], "managed from chat"),
            (["thread_id": "git", "fact_id": "c3", "scope": "forever"], "'scope' is required"),
            (["thread_id": "git", "fact_id": "x3", "scope": "thread"], "c<number>"),
            (["thread_id": "git", "fact_id": "c", "scope": "thread"], "c<number>"),
            (["thread_id": "git", "fact_id": "", "scope": "thread"], "'fact_id' is required"),
            (["fact_id": "c3", "scope": "thread"], "'thread_id' is required"),
            (["thread_id": "../x", "fact_id": "c3", "scope": "thread"], "'thread_id' must be"),
        ] as [([String: Value], String)] {
            do {
                _ = try SetFactScopeRequest(arguments: arguments)
                Issue.record("\(arguments) was accepted")
            } catch let error as MCPError {
                #expect("\(error)".contains(message), "\(error)")
            }
        }
    }

    @Test func decodesRespondRequest() throws {
        let request = try RespondRequest(arguments: [
            "prompt": .string("hi"),
            "instructions": .string("be brief"),
            "tools": .array([.string("current_date")]),
        ])
        #expect(request.prompt == "hi")
        #expect(request.instructions == "be brief")
        #expect(request.tools == .named(["current_date"]))
        #expect(request.schema == nil)
        let shaped = try RespondRequest(arguments: [
            "prompt": .string("hi"), "schema": .object(["type": .string("object"), "properties": .object([:])]),
        ])
        #expect(shaped.schema == ["type": "object", "properties": [:]])
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("hi"), "schema": .string("x")])
        }
        // The bridge from MCP values covers every shape.
        let bridged = JSONValue(
            MCP.Value.array([.null, .bool(true), .int(1), .double(1.5), .data(mimeType: nil, Data([1])), .string("s")]))
        #expect(bridged == [nil, true, 1, 1.5, "AQ==", "s"])
    }

    @Test func respondRequestDefaults() throws {
        let request = try RespondRequest(arguments: ["prompt": .string("hi")])
        #expect(request.instructions == nil)
        #expect(request.tools == .all)
    }

    @Test func respondRequestRejectsMissingPrompt() {
        #expect(throws: MCPError.self) { try RespondRequest(arguments: [:]) }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .string("")]) }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .int(1)]) }
    }

    @Test func respondRequestRejectsBadTools() {
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "tools": .string("nope")])
        }
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "tools": .array([.int(1)])])
        }
    }

    @Test func respondRequestThreadID() throws {
        #expect(try RespondRequest(arguments: ["prompt": .string("x")]).threadID == nil)
        #expect(
            try RespondRequest(arguments: ["prompt": .string("x"), "thread_id": .string("t-1.a")]).threadID == "t-1.a")
        for bad: Value in [.string(""), .string("has space"), .string(String(repeating: "x", count: 65)), .int(1)] {
            #expect(throws: MCPError.self) {
                try RespondRequest(arguments: ["prompt": .string("x"), "thread_id": bad])
            }
        }
    }

    @Test func respondRequestModel() throws {
        #expect(try RespondRequest(arguments: ["prompt": .string("x")]).model == nil)
        #expect(
            try RespondRequest(arguments: ["prompt": .string("x"), "model": .string("private-cloud")]).model
                == .privateCloud)
        #expect(throws: MCPError.self) {
            try RespondRequest(arguments: ["prompt": .string("x"), "model": .string("nope")])
        }
        #expect(throws: MCPError.self) { try RespondRequest(arguments: ["prompt": .string("x"), "model": .int(1)]) }
    }

    @Test func decodesCloseThreadRequest() throws {
        #expect(try CloseThreadRequest(arguments: ["thread_id": .string("abc")]).threadID == "abc")
        #expect(throws: MCPError.self) { try CloseThreadRequest(arguments: [:]) }
        #expect(throws: MCPError.self) { try CloseThreadRequest(arguments: ["thread_id": .string("a/b")]) }
    }

    @Test func emptyToolsMeansATextOnlyThread() throws {
        let request = try RespondRequest(arguments: ["prompt": .string("hi"), "tools": .array([])])
        #expect(request.tools == ToolSelection.none)
        #expect(ToolSelection.none.resolved(or: ["a"]).isEmpty)
    }
}

@Suite struct SummariseDiffRequestTests {
    @Test func decodesLikeTriageWithItsOwnCap() throws {
        let request = try SummariseDiffRequest(arguments: ["command": .string("git diff"), "max_files": .int(5)])
        #expect(request.source == .command("git diff", workingDirectory: nil) && request.maxFiles == 5)
        #expect(try SummariseDiffRequest(arguments: ["path": .string("/d")]).maxFiles == 40)
        #expect(throws: MCPError.self) {
            try SummariseDiffRequest(arguments: ["path": .string("/d"), "max_files": .int(0)])
        }
        #expect(throws: MCPError.self) { try SummariseDiffRequest(arguments: [:]) }
    }
}

@Suite struct TriageRequestTests {
    @Test func decodesExactlyOneSource() throws {
        let command = try TriageRequest(arguments: [
            "command": .string("swift test"), "working_directory": .string("/r"), "max_findings": .int(3),
            "model": .string("ollama:q"),
        ])
        #expect(command.source == .command("swift test", workingDirectory: "/r"))
        #expect(command.maxFindings == 3 && command.model == .ollama("q"))
        let path = try TriageRequest(arguments: ["path": .string("/log")])
        #expect(path.source == .path("/log") && path.maxFindings == 20 && path.model == nil)
        for bad: [String: Value] in [
            [:], ["command": .string("a"), "path": .string("b")], ["command": .string("")], ["path": .int(1)],
            ["command": .string("a"), "working_directory": .int(1)], ["path": .string("p"), "max_findings": .int(0)],
            ["path": .string("p"), "model": .string("gpt")], ["path": .string("p"), "model": .int(1)],
        ] {
            #expect(throws: MCPError.self, "\(bad)") { try TriageRequest(arguments: bad) }
        }
    }

    @Test func scanAndRedactArgumentsDecodeWithDefaults() throws {
        let scan = try ScanSecretsRequest(arguments: ["command": .string("git diff --cached")])
        #expect(scan.options == SecretScan.Options())
        let full = try ScanSecretsRequest(arguments: [
            "path": .string("/tmp/x"), "personal": .bool(true), "thorough": .bool(true), "max_findings": .int(5),
        ])
        #expect(full.options == SecretScan.Options(categories: [.secret, .personal], thorough: true, maxFindings: 5))
        #expect(throws: MCPError.self) {
            try ScanSecretsRequest(arguments: ["path": .string("/x"), "personal": .string("y")])
        }
        #expect(throws: MCPError.self) { try ScanSecretsRequest(arguments: [:]) }
        let redact = try RedactRequest(arguments: ["path": .string("/tmp/x")])
        #expect(redact.options == Redaction.Options())
        let narrow = try RedactRequest(arguments: [
            "path": .string("/tmp/x"), "secrets_only": .bool(true), "max_bytes": .int(100),
        ])
        #expect(narrow.options.categories == [.secret] && narrow.options.maxOutputBytes == 100)
        #expect(throws: MCPError.self) { try RedactRequest(arguments: ["path": .string("/x"), "max_bytes": .int(0)]) }
    }

    @Test func condenseLogAndJSONShapeArgumentsDecode() throws {
        #expect(try CondenseLogRequest(arguments: ["path": .string("/x")]).maxGroups == 30)
        #expect(try CondenseLogRequest(arguments: ["path": .string("/x"), "max_groups": .int(5)]).maxGroups == 5)
        #expect(throws: MCPError.self) { try CondenseLogRequest(arguments: [:]) }
        let unified = try CondenseLogRequest(arguments: ["last": .string("10m"), "process": .string("Safari")])
        #expect(unified.origin == .unified(.init(seconds: 600, process: "Safari")))
        #expect(throws: MCPError.self) { try CondenseLogRequest(arguments: ["last": .string("3d")]) }
        #expect(throws: MCPError.self) {
            try CondenseLogRequest(arguments: ["last": .string("1m"), "path": .string("/x")])
        }
        #expect(throws: MCPError.self) { try CondenseLogRequest(arguments: ["last": .int(5)]) }
        let shape = try JSONShapeRequest(arguments: [
            "path": .string("/x"), "max_depth": .int(3), "examples": .bool(false),
        ])
        #expect(shape.options == JSONShape.Options(maxDepth: 3, examples: false))
        #expect(try JSONShapeRequest(arguments: ["command": .string("cat x")]).options == JSONShape.Options())
        #expect(throws: MCPError.self) {
            try JSONShapeRequest(arguments: ["path": .string("/x"), "examples": .int(1)])
        }
    }

    @Test func draftChangeDefaultsToTheStagedDiff() throws {
        let staged = try DraftChangeRequest(arguments: ["kind": .string("commit"), "working_directory": .string("/r")])
        #expect(staged.kind == .commit && staged.source == .command("git diff --cached", workingDirectory: "/r"))
        let file = try DraftChangeRequest(arguments: ["kind": .string("pr"), "path": .string("/x.diff")])
        #expect(file.source == .path("/x.diff"))
        #expect(throws: MCPError.self) { try DraftChangeRequest(arguments: ["kind": .string("poem")]) }
        #expect(throws: MCPError.self) { try DraftChangeRequest(arguments: [:]) }
    }

    @Test func flakyTestsTakesPathsOrACommandWithABoundedRunCount() throws {
        let paths = try FlakyTestsRequest(arguments: ["paths": .array([.string("/a"), .string("/b")])])
        #expect(paths.runs == .paths(["/a", "/b"]))
        let command = try FlakyTestsRequest(arguments: ["command": .string("swift test")])
        #expect(command.runs == .command(.command("swift test", workingDirectory: nil), count: 3))
        for bad: [String: Value] in [
            [:], ["paths": .array([.string("/a")])], ["paths": .array([.string("/a"), .int(1)])],
            ["command": .string("x"), "runs": .int(1)], ["command": .string("x"), "runs": .int(11)],
            ["command": .string("x"), "paths": .array([.string("/a"), .string("/b")])],
        ] {
            #expect(throws: MCPError.self) { try FlakyTestsRequest(arguments: bad) }
        }
    }
}

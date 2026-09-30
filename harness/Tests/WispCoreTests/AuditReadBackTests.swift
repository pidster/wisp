import Foundation
import Testing

@testable import WispCore

/// Reading an audit event back by reference (`AuditLog.event(_:)`), which is how `recall` reaches a stored
/// entry's content (decision D8 of the layered-context proposal): from the files, across rotation, from memory,
/// through a tee, and not at all from a sink that keeps nothing.
@Suite struct AuditReadBackTests {
    @Test func aFileSinkFindsAnEventInTheCurrentFileOrARotatedOne() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-readback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try FileAuditSink(
            url: dir.appending(path: "audit.jsonl"), limits: .init(maxFileBytes: 600, keepFiles: 2))
        let log = AuditLog(session: "s", sink: sink)
        // The second event's output quotes the first's id as the encoder writes it; escaped in its line, the
        // quotation is not taken for the first event.
        let first = log.record(.toolResult, details: ["output": "early"])
        let second = log.record(.toolResult, details: ["output": .string("mentions \"id\":\"\(first.event)\"")])
        for index in 0..<4 { log.record(.prompt, details: ["text": .string("filler \(index)")]) }
        let rotated = FileAuditSink.rotatedFiles(for: sink.url, keep: 2)
        #expect(FileManager.default.fileExists(atPath: rotated[0].path))
        #expect(log.event(first)?.details["output"] == "early")
        #expect(log.event(second)?.details["output"]?.stringValue?.hasPrefix("mentions") == true)
        // Another session's reference with the same id is not this event; an unknown id finds nothing.
        #expect(log.event(AuditReference(session: "other", turn: nil, event: first.event)) == nil)
        #expect(log.event(AuditReference(session: "s", turn: nil, event: "0000000000000000")) == nil)
        #expect(log.event(AuditReference(session: "s", turn: nil, event: "")) == nil)
    }

    @Test func memoryAndATeeReadBackAndANullSinkDoesNot() {
        let memory = MemoryAuditSink()
        let log = AuditLog(session: "s", sink: memory).alsoRecording(to: ToolEventTrail())
        let reference = log.record(.response, details: ["text": "hello"])
        #expect(log.event(reference)?.details["text"] == "hello")
        #expect(log.event(AuditReference(session: "s", turn: nil, event: "ffffffffffffffff")) == nil)
        let quiet = AuditLog.disabled(session: "s")
        #expect(quiet.event(quiet.record(.prompt, details: ["text": "x"])) == nil)
    }
}

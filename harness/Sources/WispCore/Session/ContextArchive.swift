import Foundation
import FoundationModels

/// Saves the exact context a model sees: a transcript as JSON, which a session can be rebuilt from, and
/// as Markdown a person can read, each entry under a heading in order. `/inspect context` in chat saves the
/// transcript the next request will carry, and `Agent` saves the transcript before and after every
/// condensation, so what was dropped can be seen, not guessed
/// ([context-management.md](../../../../docs/context-management.md)).
public struct ContextArchive: Sendable {
    /// Where the files go: `<home>/context`, user-only.
    public let directory: URL
    /// The audit session the files are named after.
    public let session: String

    /// Creates an archive writing into `directory` under `session`'s name.
    public init(directory: URL, session: String) {
        self.directory = directory
        self.session = session
    }

    /// Writes `<session>-<label>.md` and `.json`, readable only by the user, and returns the Markdown file.
    ///
    /// - Parameters:
    ///   - transcript: The context to save.
    ///   - label: What it is, such as `turn7` or `turn7-condensed1-before`.
    /// - Returns: The Markdown file's URL.
    /// - Throws: File-system and encoding errors.
    @discardableResult
    public func save(_ transcript: Transcript, label: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = directory.appending(path: "\(session)-\(label)")
        let markdown = base.appendingPathExtension("md")
        let json = base.appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Data(Self.markdown(transcript).utf8).write(to: markdown, options: .atomic)
        try encoder.encode(transcript).write(to: json, options: .atomic)
        for file in [markdown, json] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return markdown
    }

    /// The transcript as Markdown: a heading per entry naming its kind (and a tool's name), then its text
    /// exactly, with tool arguments as JSON.
    public static func markdown(_ transcript: Transcript) -> String {
        var sections: [String] = []
        var turn = 0
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                sections.append("## Instructions\n\n" + text(instructions.segments))
            case .prompt(let prompt):
                turn += 1
                sections.append("## Turn \(turn): prompt\n\n" + text(prompt.segments))
            case .toolCalls(let calls):
                for call in calls {
                    sections.append("## Tool call: \(call.toolName)\n\n```json\n\(call.arguments.jsonString)\n```")
                }
            case .toolOutput(let output):
                sections.append("## Tool output: \(output.toolName)\n\n" + text(output.segments))
            case .response(let response):
                sections.append("## Response\n\n" + text(response.segments))
            default:
                sections.append("## Other entry\n\n\(entry)")
            }
        }
        return "# Context: \(turn) turn\(turn == 1 ? "" : "s")\n\n" + sections.joined(separator: "\n\n") + "\n"
    }

    /// The text of a list of segments, structured content as JSON.
    static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap {
            switch $0 {
            case .text(let segment): segment.content
            case .structure(let segment): segment.content.jsonString
            default: nil
            }
        }.joined()
    }
}

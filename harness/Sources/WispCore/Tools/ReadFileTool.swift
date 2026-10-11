import Foundation
import FoundationModels

/// Lets the model read a text file a page at a time.
///
/// Pages are line ranges bounded by a byte budget, so the model can walk a
/// large file by following the `offset` hint at the end of each page instead
/// of receiving more than its context can hold.
public struct ReadFileTool: WispTool {
    /// The identifier the model uses to request this tool.
    public let name = "read_file"
    /// What the model is told this tool does.
    public let description =
        "Reads a page of lines from a text file, numbered. Follow the offset hint at the end to read the next page."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// Absolute or working-directory-relative path.
        @Guide(description: "Path of the file to read.")
        public var path: String
        /// 1-based first line to return; nil means 1.
        @Guide(description: "1-based line number to start from. Omit to start at the top.")
        public var offset: Int?
        /// Maximum lines to return; nil means the tool default.
        @Guide(description: "Maximum number of lines to return. Omit for the default page size.")
        public var limit: Int?
    }

    /// Supplies the per-page byte budget.
    private let reader: FileReader
    /// Lines per page when the model does not ask for a limit.
    private let defaultLimit: Int
    /// Asks before reading credential-like paths; nil never asks.
    private let approval: ApprovalGate?

    /// Page size and byte budget, from the live reader.
    public var limits: String {
        "Pages of up to \(defaultLimit) lines and \(reader.pageBytes) bytes (the tool-output budget); follow the offset "
            + "hint to continue. Binary files, directories, FIFOs, and devices are refused. Credential-like paths need "
            + "the user's approval."
    }
    /// How to ask for it.
    public let examplePrompt = "Use read_file to read /path/to/file.md, then summarise it in three bullet points."

    /// Creates the tool over a reader that supplies the byte budget.
    public init(reader: FileReader = FileReader(), defaultLimit: Int = 100, approval: ApprovalGate? = nil) {
        self.reader = reader
        self.defaultLimit = defaultLimit
        self.approval = approval
    }

    /// Reads the requested page and renders it for the model.
    ///
    /// - Parameter arguments: Path and optional line range.
    /// - Returns: Numbered lines followed by a continuation or end-of-file marker.
    ///   Refusals and read errors are returned as text so the model can react.
    public func call(arguments: Arguments) async -> String {
        do {
            try await approval?.clear(
                readingFile: arguments.path, workingDirectory: FileManager.default.currentDirectoryPath)
            return try reader.read(
                path: arguments.path, offset: arguments.offset ?? 1, limit: arguments.limit ?? defaultLimit
            )
            .rendered
        } catch ApprovalGate.Failure.refused(let reason) {
            return ToolOutput.error(FileReader.Failure.notApproved(reason))
        } catch {
            return ToolOutput.error(error)
        }
    }
}

/// How tools render text for the model.
///
/// Tools return failures as text rather than throwing, because a thrown error aborts the whole
/// response with a raw framework message; the model can react to `error: …` and try another way.
/// Every tool result is bounded, because the on-device window is about 8k tokens (8,192 on macOS 27).
enum ToolOutput {
    /// `error: <description>`.
    static func error(_ error: some Error) -> String {
        "error: \(error)"
    }

    /// `text`, or its first `maxBytes` (on a character boundary) followed by a marker saying so.
    static func bounded(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while end > text.startIndex, !text.indices.contains(end) { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "\n[truncated: \(text.utf8.count) bytes, showing \(maxBytes)]"
    }
}

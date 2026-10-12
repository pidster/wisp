import Foundation

/// A tool's output as the person's views show it: chat's `/show` and `/last`, and `wisp-tui`'s expanded view
/// ([ADR 0050](../../../../docs/decisions/0050-tool-output-budget-and-overflow.md), "The person's views"). When the
/// tool's result held part of the output back and the output store still holds the whole, the view is the whole,
/// not the head, marker, and tail the model was given; otherwise it is what the tool returned, and `header` says
/// why: nothing was held back, the conversation had no store when it ran (the audit off), or the store no longer
/// holds it (swept after `context.outputDays`, or removed).
public struct ChatOutput: Sendable {
    /// Where the whole output is, or why the view is what the tool returned.
    public enum Whole: Equatable, Sendable {
        /// The store holds the whole output: its record.
        case stored(OutputStore.Kept)
        /// Nothing was held back: what the tool returned is the whole of it.
        case returned
        /// Part was held back and nothing kept: the conversation had no output store when the tool ran.
        case notKept
        /// Part was held back and kept as this output id, which the store no longer holds.
        case gone(String)
    }

    /// The page size of a front end's view of an output, `wisp-tui`'s expanded view: 64 KiB.
    public static let pageBytes = 64 * 1024

    /// What the tool returned: the text the model was given, as its event recorded it.
    public let returned: String
    /// Where the whole is.
    public let whole: Whole
    /// The event that recorded the output, by which a front end asks for its pages; nil when unknown.
    public let source: AuditReference?
    /// The store that holds it, for `.stored`.
    private let store: OutputStore?

    /// Creates a view of an output.
    ///
    /// - Parameters:
    ///   - returned: What the tool returned.
    ///   - whole: Where the whole is.
    ///   - source: The event that recorded it.
    ///   - store: The store that holds it, for `.stored`.
    init(returned: String, whole: Whole, source: AuditReference?, store: OutputStore? = nil) {
        self.returned = returned
        self.whole = whole
        self.source = source
        self.store = store
    }

    /// The phrase a held-back note names the kept output by (`ToolOutput.heldNote`).
    static let keptPhrase = "the whole output is kept as output "
    /// The phrase a held-back note ends with when nothing could be kept.
    static let notKeptPhrase = "not kept: this conversation has no output store"

    /// The output id a held-back note in `returned` names, from its own line (`held back: …`), so text that merely
    /// quotes the phrase elsewhere is not taken for one; nil when there is none.
    ///
    /// - Parameter returned: What the tool returned.
    /// - Returns: The id, or nil.
    static func heldID(in returned: String) -> String? {
        for line in returned.split(separator: "\n").reversed() where line.hasPrefix("held back: ") {
            guard let range = line.range(of: keptPhrase) else { continue }
            let id = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if SafeName.isValid(String(id)) { return String(id) }
        }
        return nil
    }

    /// Whether `returned` ends with a held-back note saying nothing could be kept.
    static func heldWithoutStore(_ returned: String) -> Bool {
        returned.split(separator: "\n").reversed().contains {
            $0.hasPrefix("held back: ") && $0.contains(notKeptPhrase)
        }
    }

    /// The view of the output an event recorded: `tool.result`'s output is kept under the event's call id, a typed
    /// command's (`command.typed`) under its `stored` detail, and either is named by the held-back note.
    ///
    /// - Parameters:
    ///   - returned: What the tool returned, from the event.
    ///   - event: The event, when it could be read; nil leaves only the note to go by.
    ///   - session: The audit session the output belongs to, when `event` is nil.
    ///   - outputs: The output stores' directory (`Home.outputs`); nil when the audit is off, so nothing is stored.
    /// - Returns: The view.
    public static func resolve(
        returned: String, event: AuditEvent?, session: String? = nil, outputs: URL?
    )
        -> ChatOutput
    {
        let source = event.map(AuditReference.init)
        let held = heldID(in: returned)
        let candidates = [
            event?.kind == .toolResult ? event?.call : nil, event?.details["stored"]?.stringValue, held,
        ]
        .compactMap(\.self)
        if let outputs, let session = event?.session ?? session, SafeName.isValid(session) {
            let store = OutputStore(directory: outputs.appending(path: session, directoryHint: .isDirectory))
            for id in candidates {
                if let kept = store.kept(id), FileManager.default.fileExists(atPath: store.url(id).path) {
                    return ChatOutput(returned: returned, whole: .stored(kept), source: source, store: store)
                }
            }
        }
        if let id = held ?? event?.details["stored"]?.stringValue {
            return ChatOutput(returned: returned, whole: .gone(id), source: source)
        }
        return ChatOutput(returned: returned, whole: heldWithoutStore(returned) ? .notKept : .returned, source: source)
    }

    /// The view of the output event `id` recorded, for a front end's `output` request: the event `last` when it is
    /// that one, else read from `audit`; nil when neither has it or it carries no output.
    ///
    /// - Parameters:
    ///   - id: The event's id.
    ///   - session: Its audit session.
    ///   - audit: The conversation's audit log, to read the event from.
    ///   - last: The last tool result the face saw (`ChatEvents.Tap.lastToolEvent`), found without a read.
    ///   - outputs: The output stores' directory; nil when the audit is off.
    /// - Returns: The view, or nil.
    public static func find(
        id: String, session: String, audit: AuditLog?, last: AuditEvent?, outputs: URL?
    )
        -> ChatOutput?
    {
        guard SafeName.isValid(id), SafeName.isValid(session) else { return nil }
        let event =
            last.flatMap { $0.id == id && $0.session == session ? $0 : nil }
            ?? audit?.event(AuditReference(session: session, turn: nil, event: id))
        guard let event, let returned = ChatEvents.shownText(of: event) else { return nil }
        return resolve(returned: returned, event: event, outputs: outputs)
    }

    /// Lines in `text`; an unterminated last line counts, a trailing newline adds none.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.utf8.count(where: { $0 == 0x0A }) + (text.utf8.last == 0x0A ? 0 : 1)
    }

    /// One line saying what the view is: the whole of a stored output (its id, tool, lines, and size, and when the
    /// store cut it at its ceiling, that it did), or what the tool returned and why.
    public var header: String {
        switch whole {
        case .stored(let kept):
            var line =
                "output \(kept.id) from \(kept.tool): the whole of it, \(kept.lines.formatted()) line"
                + "\(kept.lines == 1 ? "" : "s"), \(ToolOutput.size(kept.bytes)), from the output store"
            if kept.cut {
                line +=
                    "; the store cut it at \(ToolOutput.size(kept.bytes)) of \(ToolOutput.size(kept.totalBytes)): the "
                    + "rest was not kept"
            }
            return line
        case .returned:
            let lines = Self.lineCount(returned)
            return
                "the whole output: nothing was held back (\(lines.formatted()) line\(lines == 1 ? "" : "s"), "
                + "\(ToolOutput.size(returned.utf8.count)))"
        case .notKept:
            return
                "what the tool returned, its head and tail: the rest was held back and not kept, since this "
                + "conversation had no output store (audit.enabled was false)"
        case .gone(let id):
            return
                "what the tool returned, its head and tail: output \(id) is no longer in the output store (stored "
                + "outputs are removed context.outputDays days after their conversation was last used)"
        }
    }

    /// Whether the view is the whole of a stored output.
    public var isStored: Bool {
        if case .stored = whole { return true }
        return false
    }

    /// The view's text whole: the stored output, up to the store's ceiling, or what the tool returned.
    public var text: String {
        if case .stored(let kept) = whole, let whole = store?.text(kept.id) { return whole }
        return returned
    }

    /// Page `number` (from 1) of the view's text, `Paging.bytePage`'s pages of `size` bytes, and the page count; a
    /// stored output is read a page at a time from its file. Nil for a page out of range.
    ///
    /// - Parameters:
    ///   - number: The page.
    ///   - size: The page size.
    /// - Returns: The page and the count, or nil.
    public func page(_ number: Int, size: Int = ChatOutput.pageBytes) -> (text: String, count: Int)? {
        if case .stored(let kept) = whole, let store {
            return store.page(kept.id, number: number, size: size)
        }
        let data = Data(returned.utf8)
        return Paging.bytePage(number: number, size: size, total: data.count) { data.subdata(in: $0) }
            .map { (String(decoding: $0.data, as: UTF8.self), $0.count) }
    }

    /// The `source` field of the protocol's output view: `stored`, `returned`, `not-kept`, or `gone`.
    public var sourceName: String {
        switch whole {
        case .stored: "stored"
        case .returned: "returned"
        case .notKept: "not-kept"
        case .gone: "gone"
        }
    }
}

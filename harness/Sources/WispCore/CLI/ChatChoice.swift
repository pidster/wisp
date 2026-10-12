import Foundation

/// A question with a list of answers for a face to offer: a numbered list in the plain chat, a picker in
/// `wisp-tui` ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)). Chat commands ask, and since
/// [ADR 0062](../../../../docs/decisions/0062-the-inquiry-verb.md) so does the model, through its `ask` tool: its
/// choice carries `kind` `question` (`questionKind`), so a face shows it as the model's and never as a command's or
/// an approval.
///
/// A choice with toggles (`toggles`) is a table of rows each on or off, under column headings: the person moves
/// through it, turns rows on and off, and saves the lot, and the answer is the values left on
/// (`ChatChoice.values(answer:)`). `/models` asks one in `wisp-tui` (ADR 0056).
public struct ChatChoice: Equatable, Sendable {
    /// One answer.
    public struct Option: Equatable, Sendable {
        /// What choosing it answers.
        public var value: String
        /// What it is called, often the value itself.
        public var label: String
        /// A line about it, or empty.
        public var detail: String
        /// For a choice with toggles: the row's cells, one per column.
        public var cells: [String]
        /// For a choice with toggles: whether the row is on; nil in a plain choice, and for an action row.
        public var on: Bool?
        /// For a choice with toggles: a row that is no toggle but an action, such as `/models`' "pull a model…" (ADR
        /// 0059). Choosing it answers the choice with its value alone, as a plain choice's option does, and leaves the
        /// toggles unsaved.
        public var action: Bool

        /// Creates an option.
        public init(
            value: String, label: String? = nil, detail: String = "", cells: [String] = [], on: Bool? = nil,
            action: Bool = false
        ) {
            self.value = value
            self.label = label ?? value
            self.detail = detail
            self.cells = cells
            self.on = on
            self.action = action
        }
    }

    /// A column of a choice with toggles.
    public struct Column: Equatable, Sendable {
        /// Its heading.
        public var heading: String
        /// When a narrow face drops it: 0 never, otherwise in rank order, 1 first (`TerminalTable.fitting`).
        public var drop: Int

        /// Creates a column.
        public init(heading: String, drop: Int = 0) {
            self.heading = heading
            self.drop = drop
        }
    }

    /// For a choice with toggles, its columns; empty for a plain choice.
    public var columns: [Column] = []

    /// The `kind` of a choice that is the model's question (ADR 0062).
    public static let questionKind = "question"

    /// What kind of choice it is: nil for a chat command's, `questionKind` for the model's question.
    public var kind: String?

    /// Where a question came from, when it is not this conversation's own: a `wisp mcp` server's thread, relayed to
    /// a front end that declared `answer-questions` (ADR 0062).
    public struct Origin: Equatable, Sendable {
        /// The asking conversation: its audit session, or the MCP `thread_id`.
        public var thread: String?
        /// `mcp` for a question waiting in a `wisp mcp` server; nil for this conversation's own.
        public var source: String?
        /// The MCP client's name, when it gave one.
        public var client: String?
        /// The pending request's id, for a question waiting in a server.
        public var request: String?

        /// Creates an origin.
        public init(thread: String? = nil, source: String? = nil, client: String? = nil, request: String? = nil) {
            self.thread = thread
            self.source = source
            self.client = client
            self.request = request
        }
    }

    /// The question's origin; nil for a chat command's choice.
    public var origin: Origin?

    /// Whether the rows are toggled on and off and saved together, rather than one picked.
    public var toggles: Bool { options.contains { $0.on != nil } }

    /// The values a choice with toggles was answered with, the rows left on; nil when the answer is not one (no
    /// answer, or a front end that picked a single value instead).
    ///
    /// - Parameter answer: The answer as the face returned it.
    /// - Returns: The values, or nil.
    public static func values(answer: String?) -> [String]? {
        guard let answer, answer.hasPrefix("[") else { return nil }
        return try? JSONDecoder().decode([String].self, from: Data(answer.utf8))
    }

    /// The answer a face returns for a choice with toggles: the values left on, as a JSON array.
    ///
    /// - Parameter values: The values.
    /// - Returns: The answer.
    public static func answer(values: [String]) -> String {
        let data = (try? JSONEncoder().encode(values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The question.
    public var title: String
    /// The answers on offer; empty when only typed text will do.
    public var options: [Option]
    /// The value in force now, marked in the list.
    public var current: String?
    /// Whether a typed value is taken as well as an option.
    public var acceptsText: Bool

    /// Creates a choice.
    public init(
        title: String, options: [Option], current: String? = nil, acceptsText: Bool = false, columns: [Column] = []
    ) {
        self.title = title
        self.options = options
        self.current = current
        self.acceptsText = acceptsText
        self.columns = columns
    }

    /// Reads an answer typed at a numbered list: a number picks that option, other text is taken as
    /// typed when the choice accepts text, and an empty line, a slash command, or anything else is no
    /// answer.
    public func answer(typed line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.hasPrefix("/") else { return nil }
        if let number = Int(text), options.indices.contains(number - 1) { return options[number - 1].value }
        if let option = options.first(where: { $0.value == text }) { return option.value }
        return acceptsText ? text : nil
    }

    /// The lines of a numbered list: the title, one line per option with the current one marked, and
    /// what to type.
    public var numbered: [String] {
        let width = String(options.count).count
        var lines = [title]
        for (index, option) in options.enumerated() {
            let number = String(index + 1)
            let mark = option.value == current ? "*" : " "
            let detail = option.detail.isEmpty ? "" : "  \(option.detail)"
            lines.append(
                "\(mark) \(String(repeating: " ", count: width - number.count))\(number)  \(option.label)\(detail)")
        }
        let how =
            options.isEmpty
            ? "type a value, or press Enter to leave it"
            : acceptsText
                ? "type a number or a value, or press Enter to leave it" : "type a number, or press Enter to leave it"
        lines.append(how)
        return lines
    }
}

/// Tab completion for the chat's input: slash commands, `/config`'s words, setting paths, a setting's
/// values, models, and `/inspect`'s views, from the same catalogue the choices come from
/// ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)). Pure; the face supplies the
/// options it knows (the models this Mac can run) and applies the result.
public enum ChatCompletion {
    /// What completing a line offers.
    public struct Result: Equatable, Sendable {
        /// The character index where the word being completed starts; the candidates replace the text
        /// from here to the cursor.
        public var from: Int
        /// The words that fit, sorted, without duplicates.
        public var candidates: [String]
    }

    /// The slash commands, as typed.
    public static let commands = [
        "/help", "/tools", "/tokens", "/status", "/approvals", "/audit", "/last", "/show", "/models",
        "/model",
        "/stats",
        "/history", "/config", "/save", "/new", "/quit", "/exit", "/fact", "/task",
    ]

    /// What `/inspect`, kept as an alias, shows.
    static let views = ["config", "status", "approvals", "audit", "context", "facts"]

    /// The candidates for the word at `cursor` (a character index, the end by default) in `text`.
    ///
    /// - Parameters:
    ///   - text: The input line.
    ///   - cursor: Where the cursor is, in characters; nil is the end.
    ///   - options: The values a setting offers beyond its kind's own, such as the models for `model`.
    ///   - approvalIDs: The standing approvals' ids, for `/approvals revoke`.
    ///   - sessionIDs: The audit log's recent session ids, for `/audit`.
    ///   - subjects: The subject kinds, for `/fact`.
    ///   - factIDs: The current facts' ids, for `/fact delete` and `/fact ID SCOPE`.
    /// - Returns: Where the word starts and what may replace it; no candidates outside a slash command.
    public static func complete(
        _ text: String, cursor: Int? = nil, options: (ConfigSettings.Setting) -> [String] = { _ in [] },
        approvalIDs: [String] = [], sessionIDs: [String] = [],
        subjects: [String] = SubjectKinds.defaults.kinds.map(\.name), factIDs: [String] = []
    ) -> Result {
        let head = String(text.prefix(cursor ?? text.count))
        let from = head.lastIndex(of: " ").map { head.distance(from: head.startIndex, to: $0) + 1 } ?? 0
        let word = String(head.dropFirst(from))
        let before = head.prefix(from).split(separator: " ").map(String.init)
        guard head.hasPrefix("/") else { return Result(from: from, candidates: []) }
        let pool: [String]
        switch before {
        case []: pool = commands
        case ["/config"]: pool = ["show", "list", "get", "set", "unset"]
        case ["/config", "get"], ["/config", "set"], ["/config", "unset"]: pool = ConfigSettings.all.map(\.path)
        case ["/approvals"]: pool = ["list", "revoke"]
        case ["/approvals", "revoke"]: pool = approvalIDs
        case let words where words.count == 3 && words[0] == "/config" && words[1] == "set":
            pool = ConfigSettings.setting(words[2]).map { values($0, options: options) } ?? []
        case ["/model"]: pool = ConfigSettings.setting("model").map(options) ?? []
        case ["/inspect"]: pool = views
        case ["/inspect", "context"]: pool = ["next", "turns"]
        case ["/inspect", "facts"]: pool = ["all"]
        case ["/fact"]: pool = ["delete"] + factIDs + subjects
        case ["/fact", "delete"]: pool = factIDs
        case let words where words.count == 2 && words[0] == "/fact" && factIDs.contains(words[1]):
            pool = FactTarget.allCases.map(\.rawValue)
        case ["/audit"]: pool = ["sessions"] + sessionIDs
        default: pool = []
        }
        return Result(from: from, candidates: Array(Set(pool.filter { $0.hasPrefix(word) })).sorted())
    }

    /// The values completion offers for a setting: its fixed ones, or what the face knows of.
    static func values(_ setting: ConfigSettings.Setting, options: (ConfigSettings.Setting) -> [String]) -> [String] {
        switch setting.kind {
        case .choice(let values): values
        case .flag: ["true", "false"]
        case .tools: ToolRegistry.builtInNames
        default: options(setting)
        }
    }
}

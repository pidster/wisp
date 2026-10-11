import Foundation
import FoundationModels

/// The models wisp can run, for the model ([ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)):
/// the same actions the person has (`ModelActions`), less the person's own. `list` and `show NAME` answer at once with
/// the columns that matter for choosing, paged and bounded; `pull`, `enable`, `disable`, and `check` are approval
/// requests of their own kind (`models pull <repo>` and so on), classified and audited as `edit_file`'s edits are, a
/// pull asked every time and the others remembered for the session at most; `trust` is refused (the person's alone)
/// and `switch` is not offered. A pull, once approved, runs in the background: the tool answers at once, and the pull's
/// end arrives as a note in the conversation. Off by default: a conversation given every tool gets it with
/// `tools.models` on, and a tool list gets it by naming it, as `memory` (ADR 0057).
public struct ModelsTool: WispTool {
    /// The tool's name, as registries and the prompt name it.
    public static let toolName = "models"
    /// The most a reply holds.
    static let maxBytes = 4096
    /// Models a page of `list` holds.
    static let pageSize = 20

    /// The identifier the model uses to request this tool.
    public let name = ModelsTool.toolName
    /// What the model is told this tool does.
    public let description =
        "The models wisp can run: list, show NAME, or ask the person to pull REPO (an MLX model from Hugging Face, "
        + "<organisation>/<name>), enable NAME, disable NAME, or check NAME. A pull runs in the background; its end "
        + "arrives as a note, so never call again to see how it goes."

    /// Arguments the model may supply when calling the tool.
    @Generable
    public struct Arguments {
        /// The action.
        @Guide(description: "One of: list, show, pull, enable, disable, check.")
        public var action: String
        /// The model, or for pull the repository.
        @Guide(description: "The model as list names it, such as ollama:granite4.1:8b; for pull, the repository.")
        public var name: String?
        /// The page of `list`, from 1.
        @Guide(description: "For list: the page, from 1.")
        public var page: Int?
    }

    /// The actions, as the model's; nil where models cannot be managed (a catalogue).
    private let actions: ModelActions?
    /// The conversation's gate, which every change asks through; nil refuses every change.
    private let gate: ApprovalGate?
    /// The conversation's audit session, which a background pull's note goes to.
    private let conversation: String
    /// The conversation's model, marked `*` in the listing.
    private let current: ModelSelection?

    /// What bounds it.
    public var limits: String {
        "list pages \(Self.pageSize) models; every reply at most \(Self.maxBytes) bytes. pull, enable, disable, and "
            + "check ask the person every time (pull) or remember an answer for the session at most; trust is the "
            + "person's alone. A pull runs in the background and its end arrives as a note. Off by default: a "
            + "conversation gets it with tools.models on, or by naming it."
    }
    /// How to ask for it.
    public let examplePrompt = "Use models with action list, then report which models can call tools."

    /// Creates the tool.
    ///
    /// - Parameters:
    ///   - actions: The actions, as the model's (`face` `tool`); nil answers that models cannot be managed here.
    ///   - gate: The conversation's gate; nil refuses every change.
    ///   - conversation: The conversation's audit session.
    ///   - current: The conversation's model.
    public init(
        actions: ModelActions? = nil, gate: ApprovalGate? = nil, conversation: String = "",
        current: ModelSelection? = nil
    ) {
        self.actions = actions
        self.gate = gate
        self.conversation = conversation
        self.current = current
    }

    /// Carries out the action.
    ///
    /// - Parameter arguments: The action and its object.
    /// - Returns: The listing, the model's facts, what changed, or why nothing did; never throws.
    public func call(arguments: Arguments) async -> String {
        guard let actions else { return "error: models cannot be managed here" }
        let verb = arguments.action.trimmingCharacters(in: .whitespaces).lowercased()
        let name = arguments.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let directory = FileManager.default.currentDirectoryPath
        // The listing judges a conversation with tools, as this one is.
        let tools: [any Tool] = [CurrentDateTool()]
        switch ModelActions.Action(rawValue: verb) {
        case .list:
            return Self.page(await actions.list(tools: tools), page: arguments.page ?? 1, current: current)
        case .show:
            guard !name.isEmpty else { return "error: show needs name, as list names the model" }
            do {
                return Self.facts(try await actions.show(name, tools: tools), current: current)
            } catch {
                return ToolOutput.error(error)
            }
        case .pull:
            guard !name.isEmpty else { return "error: pull needs name, the repository <organisation>/<name>" }
            guard let gate else { return "error: not approved: nobody can be asked here" }
            return await actions.requestPull(name, gate: gate, conversation: conversation, workingDirectory: directory)
        case let action? where action == .enable || action == .disable || action == .check:
            guard !name.isEmpty else { return "error: \(verb) needs name, as list names the model" }
            guard let gate else { return "error: not approved: nobody can be asked here" }
            return await actions.requestChange(action, name, gate: gate, workingDirectory: directory)
        case let action?:
            return ToolOutput.error(ModelActions.Failure.notForTheModel(action.rawValue))
        case nil:
            return "error: action must be list, show, pull, enable, disable, or check"
        }
    }

    /// The columns the model chooses by, in this order.
    static let columns = ["runtime", "parameters", "size", "context", "enabled", "capabilities"]

    /// One page of the listing: a line per model the listing shows, its name (`*` for the conversation's) and the
    /// columns that matter for choosing, a model that cannot be used followed by why, then the backends that did not
    /// answer and how to see the next page.
    ///
    /// - Parameters:
    ///   - listing: The models.
    ///   - page: The page, from 1.
    ///   - current: The conversation's model.
    /// - Returns: The reply, bounded.
    static func page(_ listing: ModelListing.Listing, page: Int, current: ModelSelection?) -> String {
        let shown = listing.shown(all: false)
        let pages = max(1, (shown.count + pageSize - 1) / pageSize)
        let number = min(max(1, page), pages)
        var lines: [String] = []
        if shown.isEmpty { lines.append(ModelListing.noUsableModel) }
        for entry in shown.dropFirst((number - 1) * pageSize).prefix(pageSize) {
            let cells = columns.compactMap { key -> String? in
                guard let column = ModelTable.columns.first(where: { $0.key == key }) else { return nil }
                let text = ModelTable.cell(column, entry)
                guard !text.isEmpty else { return nil }
                switch key {
                case "enabled": return entry.enabled ? "enabled" : "disabled"
                case "context": return "context \(text)"
                case "capabilities": return text
                default: return text
                }
            }
            let mark = entry.selection == current ? "* " : ""
            lines.append(([mark + entry.selection.description] + cells).joined(separator: " | "))
            if let problem = entry.problem, entry.linked { lines.append("  not usable: \(problem)") }
        }
        lines += listing.unreachable.map { "(\($0))" }
        if pages > 1 {
            lines.append(
                "page \(number) of \(pages)" + (number < pages ? "; list with page \(number + 1) for more" : ""))
        }
        return ToolOutput.bounded(lines.joined(separator: "\n"), maxBytes: maxBytes)
    }

    /// One model's facts, a line each, from every column the listing has, and why it cannot be used.
    ///
    /// - Parameters:
    ///   - entry: The model.
    ///   - current: The conversation's model.
    /// - Returns: The reply, bounded.
    static func facts(_ entry: ModelListing.Entry, current: ModelSelection?) -> String {
        var lines = ["model: \(entry.selection)" + (entry.selection == current ? " (this conversation's)" : "")]
        for column in ModelTable.columns where column.key != "model" {
            let text = ModelTable.cell(column, entry)
            if !text.isEmpty { lines.append("\(column.heading.lowercased()): \(text)") }
        }
        if let from = entry.capabilitiesFrom { lines.append("capabilities from: \(from)") }
        if let note = entry.contextNote { lines.append("context note: \(note)") }
        lines.append("usable: " + (entry.usable ? "yes" : "no" + (entry.problem.map { ", \($0)" } ?? "")))
        return ToolOutput.bounded(lines.joined(separator: "\n"), maxBytes: maxBytes)
    }
}

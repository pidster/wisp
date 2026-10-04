import Foundation
import FoundationModels

/// The models `wisp models` lists, `/models` shows in chat, and `wisp-tui`'s `/models` offers to turn on and off. A
/// model can serve the conversation when it resolves (so it is installed, reachable, entitled, and able to
/// converse) and declares what the conversation needs (tool calling, when there are tools). The same checks decide
/// whether `/model` or `--model` can switch to it, so the list never offers what would be refused. Each entry also
/// carries every fact wisp knows about the model, which `ModelTable` lays out (ADR 0056).
public enum ModelListing {
    /// One candidate, what is known about it, and whether it can be used.
    public struct Entry: Equatable, Sendable {
        /// The selection that names it.
        public var selection: ModelSelection
        /// The backend's one-line summary (size, parameter count, or whatever it reports); empty for Apple's models.
        public var detail: String
        /// The parameter count, such as `8.8B`, when the runtime reports it.
        public var parameters: String?
        /// Bytes the weights take on disk, when known.
        public var bytes: Int?
        /// The architecture and quantisation, such as `granite Q4_K_M`, when known.
        public var format: String?
        /// Where an MLX model lives; nil for the rest.
        public var location: ModelLocation?
        /// The context window wisp would use, when the model resolved and states or sizes one.
        public var contextSize: Int?
        /// Why the window is what it is (`ResolvedModel.contextNote`); nil when it is the model's own.
        public var contextNote: String?
        /// Declared capabilities when it resolved, as the framework names them (`toolCalling`, …).
        public var capabilities: [String]
        /// Why it cannot be used, or nil when it can.
        public var problem: String?
        /// Whether the operator has it enabled (`models.disabled`); a cached model not linked yet is not.
        public var enabled: Bool

        /// Creates an entry.
        public init(
            selection: ModelSelection, detail: String = "", parameters: String? = nil, bytes: Int? = nil,
            format: String? = nil, location: ModelLocation? = nil, contextSize: Int? = nil,
            contextNote: String? = nil, capabilities: [String] = [], problem: String? = nil, enabled: Bool = true
        ) {
            self.selection = selection
            self.detail = detail
            self.parameters = parameters
            self.bytes = bytes
            self.format = format
            self.location = location
            self.contextSize = contextSize
            self.contextNote = contextNote
            self.capabilities = capabilities
            self.problem = problem
            self.enabled = enabled
        }

        /// Whether it is where its backend resolves it: false for a cached model that enabling would link.
        public var linked: Bool { location != .hubCacheNotLinked }

        /// Whether a conversation could run on it now, were it enabled.
        public var usable: Bool { problem == nil && linked }

        /// Whether `/model` and Tab offer it: usable and enabled.
        public var offered: Bool { usable && enabled }

        /// What runs it, in plain words: `on-device` for Apple's on-device model, `Private Cloud` for Apple's
        /// server model, and the runtime's name for the rest.
        public var runtime: String {
            switch selection.backend {
            case "system": "on-device"
            case "private-cloud": "Private Cloud"
            case "ollama": "Ollama"
            case "mlx": "MLX"
            case "coreai": "Core AI"
            case let other: other
            }
        }

        /// How the window is known, in a word: `memory` (sized from the weights and the Mac's memory, ADR 0043),
        /// `config` (`ollama.contextLength` or `mlx.contextLength`), `bundle` (declared by a Core AI bundle),
        /// `default` (the floor, with no shape to size from), or `model` (the model states its own); nil without a
        /// window.
        public var contextFrom: String? {
            guard contextSize != nil else { return nil }
            guard let note = contextNote else { return "model" }
            if note.hasPrefix("configured") { return "config" }
            if note.hasPrefix("declared by") { return "bundle" }
            if note.contains(", the default") || note.hasPrefix("the default") { return "default" }
            return "memory"
        }

        /// The capabilities in plain words (`tools`, `structured replies`, `thinking`, `vision`); `text only` for a
        /// model that resolved and declares none; empty when it did not resolve.
        public var plainCapabilities: [String] {
            guard problem == nil, linked else { return [] }
            let words = capabilities.map { name in
                switch name {
                case "toolCalling": "tools"
                case "guidedGeneration": "structured replies"
                case "reasoning": "thinking"
                default: name
                }
            }
            return words.isEmpty ? ["text only"] : words
        }
    }

    /// The entries, and a line of text for each backend that did not answer.
    public struct Listing: Equatable, Sendable {
        /// Every candidate, judged.
        public var entries: [Entry]
        /// One line per backend that could not be asked, such as `ollama: no Ollama server at …`.
        public var unreachable: [String]

        /// Creates a listing.
        public init(entries: [Entry], unreachable: [String] = []) {
            self.entries = entries
            self.unreachable = unreachable
        }

        /// The entries a listing shows: with `all`, every one; otherwise those that can serve the conversation, and
        /// those the operator can turn on (a disabled model, a cached model not linked), whether or not they can.
        public func shown(all: Bool) -> [Entry] {
            entries.filter { all || $0.usable || !$0.enabled }
        }
    }

    /// Every candidate: Apple's two, each backend's installed models, every disabled model none of them listed,
    /// and each backend's cached models not linked yet, each judged; and a line of text for each backend that did
    /// not answer.
    ///
    /// - Parameters:
    ///   - config: The effective configuration.
    ///   - home: wisp's home.
    ///   - tools: The tools the conversation would have; empty needs nothing.
    ///   - disabled: The disabled models; nil takes the configuration's.
    /// - Returns: The listing.
    public static func entries(
        config: Config.Resolved, home: Home, tools: [any Tool], disabled: [ModelSelection]? = nil
    ) async -> Listing {
        let disabled = disabled ?? config.disabledModels
        var candidates = [InstalledModel(selection: .system, detail: ""), .init(selection: .privateCloud, detail: "")]
        var unreachable: [String] = []
        var cached: [InstalledModel] = []
        for backend in ModelBackends.all {
            do {
                candidates += try await backend.installed(config: config, home: home)
            } catch {
                unreachable.append("\(backend.scheme): \(error)")
            }
            cached += backend.unlinked(config: config, home: home)
        }
        for selection in disabled where !candidates.contains(where: { $0.selection == selection }) {
            candidates.append(InstalledModel(selection: selection, detail: ""))
        }
        var entries = candidates.map { installed in
            var entry = Entry(
                selection: installed.selection, detail: installed.detail, parameters: installed.parameters,
                bytes: installed.bytes, format: installed.format, location: installed.location,
                enabled: !disabled.contains(installed.selection))
            do {
                let resolved = try installed.selection.resolve(config: config, home: home)
                try resolved.check(tools: tools)
                entry.capabilities = resolved.capabilityNames
                entry.contextSize = resolved.contextSize
                entry.contextNote = resolved.contextNote
            } catch {
                entry.problem = "\(error)"
            }
            return entry
        }
        entries += cached.filter { model in !entries.contains { $0.selection == model.selection } }.map { model in
            Entry(
                selection: model.selection, detail: model.detail, parameters: model.parameters, bytes: model.bytes,
                format: model.format, location: model.location, enabled: false)
        }
        return Listing(entries: entries, unreachable: unreachable)
    }

    /// `wisp models`: on a terminal (`width`), the table `ModelTable.terminal` lays out; piped, its tab-separated
    /// rows for scripts.
    ///
    /// - Parameters:
    ///   - config: The effective configuration.
    ///   - home: wisp's home.
    ///   - current: The model to mark `*`, the configured default.
    ///   - tools: The tools a conversation would have.
    ///   - all: Whether to list the models that cannot be used, with the reason.
    ///   - width: The terminal's width, or nil when piped.
    /// - Returns: The lines.
    public static func lines(
        config: Config.Resolved, home: Home, current: ModelSelection, tools: [any Tool], all: Bool = false,
        width: Int? = nil
    ) async -> [String] {
        let listing = await entries(config: config, home: home, tools: tools)
        guard let width else { return ModelTable.tabSeparated(listing, current: current, all: all) }
        return ModelTable.terminal(listing, current: current, all: all, width: width)
    }

    /// The line shown when nothing can serve the conversation.
    static let noUsableModel = "no usable model; wisp models --all shows why"
}

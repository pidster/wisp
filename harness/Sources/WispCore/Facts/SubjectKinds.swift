import Foundation

/// Turns a fact's name as said or extracted into the name its identity uses, so one thing is not split into
/// several lineages by spelling (decision D2 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)). One protocol, so the
/// rules can be changed without touching the store or the composer; each subject kind names one.
public protocol FactNameNormaliser: Sendable {
    /// The normalised name.
    ///
    /// - Parameter name: The name as given.
    /// - Returns: The name the identity uses.
    func normalise(_ name: String) -> String
}

/// Names that ship with wisp for `SubjectKind.normaliser`.
public enum FactNormalisers {
    /// Whitespace trimmed and collapsed to single spaces.
    public struct Trim: FactNameNormaliser {
        /// Creates the normaliser.
        public init() {}

        /// `name` trimmed, runs of whitespace as one space.
        public func normalise(_ name: String) -> String {
            name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    /// Trimmed, then case-folded and stripped of diacritics, so `BLUE HERON` and `Blue Heron` are one name.
    public struct CaseFold: FactNameNormaliser {
        /// Creates the normaliser.
        public init() {}

        /// `name` trimmed and folded.
        public func normalise(_ name: String) -> String {
            Trim().normalise(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.:"))
        }
    }

    /// One fact per conversation: every name maps to the empty name, as for `task`, `workdir`, and `branch`.
    public struct Single: FactNameNormaliser {
        /// Creates the normaliser.
        public init() {}

        /// The empty name.
        public func normalise(_ name: String) -> String { "" }
    }

    /// A command line as a test or build is named: a leading `cd … &&`, `set -o pipefail;`, a trailing
    /// redirection of stderr, and a pipe into `tail` or `head` removed, whitespace collapsed.
    public struct Command: FactNameNormaliser {
        /// Creates the normaliser.
        public init() {}

        /// The command's core.
        public func normalise(_ name: String) -> String {
            var text = Trim().normalise(name)
            text = text.replacing(#/^(set -o pipefail\s*;\s*)/#, with: "")
            text = text.replacing(#/^cd\s+\S+\s*&&\s*/#, with: "")
            text = text.replacing(#/\s*\|\s*(tail|head)(\s+-?\w+)*\s*$/#, with: "")
            text = text.replacing(#/\s*2>&1\s*$/#, with: "")
            return Trim().normalise(text)
        }
    }

    /// A path relative to the root of the git repository that holds it, found by walking up to a `.git`
    /// entry; an absolute path outside any repository stays absolute, and a relative path is kept as given.
    public struct Path: FactNameNormaliser {
        /// Finds the repository root for an absolute, standardised path; nil when there is none.
        let root: @Sendable (String) -> String?

        /// Creates the normaliser.
        ///
        /// - Parameter root: Finds a path's repository root; defaults to walking up the file system.
        public init(root: @escaping @Sendable (String) -> String? = Path.repositoryRoot) {
            self.root = root
        }

        /// `name` relative to its repository's root, or standardised.
        public func normalise(_ name: String) -> String {
            let trimmed = Trim().normalise(name)
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return trimmed }
            let path = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
            guard let root = root(path), path.hasPrefix(root + "/") else { return path }
            return String(path.dropFirst(root.count + 1))
        }

        /// The nearest directory above `path` (or `path` itself) that holds a `.git` entry, or nil.
        ///
        /// - Parameter path: An absolute path.
        /// - Returns: The repository root, or nil.
        public static func repositoryRoot(_ path: String) -> String? {
            var directory = URL(fileURLWithPath: path)
            for _ in 0..<32 {
                if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
                    return directory.path
                }
                let parent = directory.deletingLastPathComponent()
                guard parent.path != directory.path else { return nil }
                directory = parent
            }
            return nil
        }
    }

    /// The normaliser a kind names: `trim`, `casefold`, `single`, `command`, or `path`; nil for another name.
    ///
    /// - Parameter name: The name.
    /// - Returns: The normaliser, or nil.
    public static func named(_ name: String) -> (any FactNameNormaliser)? {
        switch name {
        case "trim": Trim()
        case "casefold": CaseFold()
        case "single": Single()
        case "command": Command()
        case "path": Path()
        default: nil
        }
    }

    /// Every name `named(_:)` knows.
    public static let names = ["trim", "casefold", "single", "command", "path"]
}

/// What a fact can be about: its name, its temporal class, how names under it are normalised, and the
/// description the distiller is shown (decision D2). The defaults ship as `Resources/subject-kinds.json`;
/// `facts.kinds` in the config adds kinds or changes them.
public struct SubjectKind: Codable, Sendable, Equatable {
    /// The subject, such as `tests`.
    public var name: String
    /// How long its facts stay true, and so where they live.
    public var temporalClass: TemporalClass
    /// The normaliser's name (`FactNormalisers.named`).
    public var normaliser: String
    /// One sentence for the distiller: what facts of this kind are.
    public var description: String
    /// Whether the distiller may record facts of this kind; nil means yes. Kinds whose facts come from tool
    /// output (`file`, `service`, `machine`) say no, so the model does not spend its facts summarising files.
    public var distil: Bool?

    /// Whether the distiller is shown this kind and may record its facts.
    public var distils: Bool { distil ?? true }

    /// The JSON keys.
    enum CodingKeys: String, CodingKey {
        case name
        case temporalClass = "class"
        case normaliser
        case description
        case distil
    }

    /// Creates a kind.
    public init(
        name: String, temporalClass: TemporalClass, normaliser: String, description: String, distil: Bool? = nil
    ) {
        self.name = name
        self.temporalClass = temporalClass
        self.normaliser = normaliser
        self.description = description
        self.distil = distil
    }

    /// `name` as this kind normalises it; trimmed only when the normaliser's name is unknown.
    ///
    /// - Parameter name: The name as given.
    /// - Returns: The identity's name.
    public func normalise(_ name: String) -> String {
        (FactNormalisers.named(normaliser) ?? FactNormalisers.Trim()).normalise(name)
    }
}

/// The subject kinds in force, and the commands that count as tests: wisp's defaults with the
/// configuration's changes applied.
public struct SubjectKinds: Sendable, Equatable {
    /// The kinds, in order: the defaults', then any the configuration adds.
    public private(set) var kinds: [SubjectKind]
    /// Command prefixes whose exit status is a `tests` fact, such as `swift test`.
    public private(set) var testCommands: [String]

    /// The resource's shape.
    struct Resource: Codable {
        /// The kinds.
        var kinds: [SubjectKind]
        /// The test commands.
        var testCommands: [String]
    }

    /// Creates a catalogue.
    public init(kinds: [SubjectKind], testCommands: [String]) {
        self.kinds = kinds
        self.testCommands = testCommands
    }

    /// wisp's defaults, from `Resources/subject-kinds.json`, embedded at build time.
    public static let defaults: SubjectKinds = {
        guard let resource = try? JSONDecoder().decode(Resource.self, from: Data(SubjectKindsText.text.utf8)) else {
            return SubjectKinds(kinds: [], testCommands: [])
        }
        return SubjectKinds(kinds: resource.kinds, testCommands: resource.testCommands)
    }()

    /// The kind named `name`, or nil.
    public func kind(_ name: String) -> SubjectKind? {
        let folded = name.lowercased().trimmingCharacters(in: .whitespaces)
        return kinds.first { $0.name == folded }
    }

    /// This catalogue with the configuration's changes: each configured kind replaces the fields it sets of
    /// the kind of that name, or adds a kind when there is none; `testCommands`, when set, replaces the list.
    ///
    /// - Parameter config: The `facts` section.
    /// - Returns: The catalogue in force.
    public func applying(_ config: Config.FactsConfig?) -> SubjectKinds {
        guard let config else { return self }
        var result = self
        for change in config.kinds ?? [] {
            let name = change.name.lowercased()
            if let index = result.kinds.firstIndex(where: { $0.name == name }) {
                if let value = change.temporalClass { result.kinds[index].temporalClass = value }
                if let value = change.normaliser { result.kinds[index].normaliser = value }
                if let value = change.description { result.kinds[index].description = value }
                if let value = change.distil { result.kinds[index].distil = value }
            } else {
                result.kinds.append(
                    SubjectKind(
                        name: name, temporalClass: change.temporalClass ?? .dynamic,
                        normaliser: change.normaliser ?? "casefold", description: change.description ?? name,
                        distil: change.distil))
            }
        }
        if let commands = config.testCommands { result.testCommands = commands }
        return result
    }

    /// The identity `name` under the kind `subject` has, normalised: nil for an unknown kind.
    ///
    /// - Parameters:
    ///   - subject: The kind's name.
    ///   - name: The name as given.
    /// - Returns: The identity, in the kind's class's scope, and the class.
    public func identity(subject: String, name: String) -> (identity: FactIdentity, temporalClass: TemporalClass)? {
        guard let kind = kind(subject) else { return nil }
        return (
            FactIdentity(scope: kind.temporalClass.scope, subject: kind.name, name: kind.normalise(name)),
            kind.temporalClass
        )
    }

    /// The test command `command` runs, as its `testCommands` prefix names it, or nil: the command's core
    /// (`FactNormalisers.Command`) must start with a listed prefix at a word boundary, or contain it after
    /// `&&` or `;`.
    ///
    /// - Parameter command: A command line.
    /// - Returns: The listed prefix, or nil.
    public func testCommand(in command: String) -> String? {
        let core = FactNormalisers.Command().normalise(command)
        let parts = core.split(whereSeparator: { $0 == ";" || $0 == "&" }).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for part in parts {
            for prefix in testCommands {
                let bare = part.hasPrefix("./") ? String(part.dropFirst(2)) : part
                if bare == prefix || bare.hasPrefix(prefix + " ") { return prefix }
            }
        }
        return nil
    }
}

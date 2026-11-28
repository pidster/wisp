import Foundation

/// Every model wisp has seen or set up, kept in `~/.wisp/models.json` when its runtime is not running
/// ([ADR 0092](../../../../docs/decisions/0092-a-model-registry.md)). It is a cache of what was seen. A model's settings
/// stay in `config.json`, and its runtime stays the authority on what it serves. Whether a model is available is
/// worked out at listing time; the registry only remembers it. Apple's two models are always there and never recorded.
///
/// The value type here holds the rules, as pure functions over values. `ModelRegistry.Store` reads and writes the file.
public struct ModelRegistry: Codable, Equatable, Sendable {
    /// How wisp came to know a model.
    public enum Origin: String, Codable, Sendable {
        /// A runtime listed it.
        case seen
        /// `wisp models pull` fetched it.
        case pulled
        /// `wisp models add` linked it.
        case added
        /// `config.json` names it, in `model` or `<runtime>.models.<name>`.
        case configured
    }

    /// One model wisp knows.
    public struct Record: Codable, Equatable, Sendable {
        /// The model, as `--model` spells it in canonical form: `ollama:granite4.2:8b`.
        public var model: String
        /// How wisp came to know it.
        public var origin: Origin
        /// The day wisp first knew it, `YYYY-MM-DD`.
        public var firstSeen: String
        /// The day a runtime last listed it, `YYYY-MM-DD`; nil when none has yet.
        public var lastSeen: String?
        /// What its runtime last said of it in a line (size, parameters), so an unavailable model still has one.
        public var detail: String?
        /// The parameter count its runtime last reported, such as `8.8B`.
        public var parameters: String?
        /// Bytes its weights took on disk, as last reported.
        public var bytes: Int?
        /// Its architecture and quantisation, as last reported.
        public var format: String?

        /// Creates a record.
        public init(
            model: String, origin: Origin, firstSeen: String, lastSeen: String? = nil, detail: String? = nil,
            parameters: String? = nil, bytes: Int? = nil, format: String? = nil
        ) {
            self.model = model
            self.origin = origin
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.detail = detail
            self.parameters = parameters
            self.bytes = bytes
            self.format = format
        }

        /// The runtime's scheme, `ollama` in `ollama:granite4.2:8b`.
        public var scheme: String { String(model.prefix { $0 != ":" }) }
    }

    /// The file's format, raised when a change could not be read by an older wisp.
    public var version = 1
    /// The models, ordered by name.
    public private(set) var models: [Record] = []

    /// An empty registry.
    public init() {}

    /// A registry holding `records`, ordered by name.
    ///
    /// - Parameter records: The records.
    init(records: [Record]) {
        models = records.sorted { $0.model < $1.model }
    }

    /// The record of `model`, as `--model` spells it in canonical form.
    ///
    /// - Parameter model: The model.
    /// - Returns: Its record, or nil when wisp does not know it.
    public func record(_ model: String) -> Record? {
        models.first { $0.model == model }
    }

    /// The records of one runtime's models.
    ///
    /// - Parameter scheme: The runtime's scheme, `ollama`.
    /// - Returns: Its records, ordered by name.
    public func records(of scheme: String) -> [Record] {
        models.filter { $0.scheme == scheme }
    }

    /// The day a time falls on, as the registry writes it.
    ///
    /// - Parameter date: The time.
    /// - Returns: `YYYY-MM-DD`.
    static func day(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    /// Whether a selection is one the registry keeps: a local runtime's model, not one of Apple's.
    ///
    /// - Parameter selection: The model.
    /// - Returns: Its canonical name when kept, else nil.
    static func key(_ selection: ModelSelection) -> String? {
        guard case .local = selection else { return nil }
        return selection.description
    }

    // MARK: - The rules

    /// What a runtime that answered served: each model is recorded, a new one as `seen`, with `lastSeen` set to `day`
    /// and the runtime's facts replacing the ones kept. A registered model the runtime did not list is left as it
    /// was: it is not served now, but the person has not said to forget it (ADR 0092, decision 4). Call this only for
    /// a runtime that answered; one that did not leaves its records untouched.
    ///
    /// - Parameters:
    ///   - served: The models the runtime listed.
    ///   - day: The day, `YYYY-MM-DD`.
    /// - Returns: Whether anything changed, so an unchanged registry is not written.
    @discardableResult
    public mutating func merge(served: [InstalledModel], day: String) -> Bool {
        var changed = false
        for installed in served {
            guard let model = Self.key(installed.selection) else { continue }
            var record = self.record(model) ?? Record(model: model, origin: .seen, firstSeen: day)
            record.lastSeen = day
            record.detail = installed.detail.isEmpty ? nil : installed.detail
            record.parameters = installed.parameters
            record.bytes = installed.bytes
            record.format = installed.format
            changed = put(record) || changed
        }
        return changed
    }

    /// A model wisp set up or was told of: pulled, added, or named in `config.json`. A model already known keeps its
    /// first day and its origin, unless it was only `seen`, which a pull or an add replaces, since that says more of
    /// how it came.
    ///
    /// - Parameters:
    ///   - selection: The model.
    ///   - origin: How wisp came to know it.
    ///   - day: The day, `YYYY-MM-DD`.
    /// - Returns: Whether anything changed.
    @discardableResult
    public mutating func register(_ selection: ModelSelection, origin: Origin, day: String) -> Bool {
        guard let model = Self.key(selection) else { return false }
        guard var record = self.record(model) else {
            return put(Record(model: model, origin: origin, firstSeen: day))
        }
        if record.origin == .seen, origin == .pulled || origin == .added { record.origin = origin }
        return put(record)
    }

    /// Forgets a model: the person's word, and the only way a model leaves the registry besides an uninstall
    /// (ADR 0092, decision 4).
    ///
    /// - Parameter selection: The model.
    /// - Returns: Whether it was known.
    @discardableResult
    public mutating func forget(_ selection: ModelSelection) -> Bool {
        guard let model = Self.key(selection), let index = models.firstIndex(where: { $0.model == model }) else {
            return false
        }
        models.remove(at: index)
        return true
    }

    /// Puts a record in its place by name.
    ///
    /// - Parameter record: The record.
    /// - Returns: Whether the registry changed.
    private mutating func put(_ record: Record) -> Bool {
        if let index = models.firstIndex(where: { $0.model == record.model }) {
            guard models[index] != record else { return false }
            models[index] = record
        } else {
            let index = models.firstIndex { $0.model > record.model } ?? models.endIndex
            models.insert(record, at: index)
        }
        return true
    }
}

extension ModelRegistry {
    /// The registry's file under wisp's home. Every change re-reads the file under an advisory `flock` on a lock file
    /// beside it, applies itself, and writes the result atomically, user-only, before the lock is let go, so two `wisp`
    /// processes listing at once lose nothing; a change that alters nothing writes nothing. A missing file is an empty
    /// registry. So is one that cannot be read, which the next change replaces: the registry is a cache of what
    /// listings saw, and the next listing rebuilds it, losing only the days (ADR 0092, decision 2).
    public struct Store: Sendable {
        /// Why a change could not be kept.
        public enum Failure: Error, CustomStringConvertible, Equatable {
            /// Writing the file failed.
            case unwritable(path: String, reason: String)

            /// Human-readable explanation.
            public var description: String {
                switch self {
                case .unwritable(let path, let reason): "could not write \(path): \(reason)"
                }
            }
        }

        /// The file.
        public let url: URL

        /// The store in `home`.
        ///
        /// - Parameter home: wisp's home.
        public init(home: Home) {
            url = home.modelRegistryFile
        }

        /// The store at `url`.
        ///
        /// - Parameter url: The file.
        init(url: URL) {
            self.url = url
        }

        /// The registry as the file holds it now.
        ///
        /// - Returns: The registry; empty when the file is missing or cannot be read.
        public func load() -> ModelRegistry {
            guard let data = try? Data(contentsOf: url),
                let registry = try? JSONDecoder().decode(ModelRegistry.self, from: data)
            else { return ModelRegistry() }
            return registry
        }

        /// Changes the registry as the file holds it now, under the lock, and writes it when `change` says it changed.
        ///
        /// - Parameter change: The change; returns whether it altered anything.
        /// - Returns: The registry after the change.
        /// - Throws: `Failure.unwritable` when the file could not be written.
        @discardableResult
        public func update(_ change: (inout ModelRegistry) -> Bool) throws(Failure) -> ModelRegistry {
            try withFileLock { () throws(Failure) -> ModelRegistry in
                var registry = load()
                guard change(&registry) else { return registry }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                do {
                    let data = try encoder.encode(registry)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } catch {
                    throw Failure.unwritable(path: url.path, reason: error.localizedDescription)
                }
                return registry
            }
        }

        /// Runs `body` holding an exclusive advisory lock on `<url>.lock`, as `SharedFacts` does; when the lock file
        /// cannot be made, `body` runs unlocked and its write reports any failure.
        ///
        /// - Parameter body: What to run.
        /// - Returns: `body`'s result.
        /// - Throws: What `body` throws.
        private func withFileLock<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return try body() }
            defer { _ = close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { return try body() }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }
}

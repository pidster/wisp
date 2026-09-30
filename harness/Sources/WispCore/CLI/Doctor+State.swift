import Foundation

/// The doctor's checks of what wisp keeps and how it is set: the facts store, the subject kinds, saved
/// transcripts, numeric settings, and the context window.
extension Doctor {
    /// `~/.wisp/facts.json`: absent, or parses, is readable by the owner only, and how many current facts it holds.
    func factsStore() -> Finding {
        let name = "facts store"
        let file = home.factsFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            return Finding(name: name, ok: true, detail: "no \(file.path); no permanent facts yet")
        }
        let book: FactBook
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            book = try decoder.decode(FactBook.self, from: Data(contentsOf: file))
            guard book.scope == .permanent else {
                throw CocoaError(
                    .coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "it holds \(book.scope) facts"])
            }
        } catch {
            return Finding(
                name: name, ok: false,
                detail: "\(file.path) does not parse: \(error); wisp starts with no permanent facts until a change "
                    + "replaces it")
        }
        let current = book.current
        var counts = ""
        let bySubject = Dictionary(grouping: current, by: \.identity.subject).mapValues(\.count)
        if !bySubject.isEmpty {
            counts =
                " (" + bySubject.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                + ")"
        }
        let history = book.facts.count - current.count
        let summary = "\(current.count) current permanent facts\(counts), \(history) superseded or deleted"
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int).flatMap {
            $0
        }
        if let mode, mode & 0o077 != 0 {
            let text = String(mode & 0o777, radix: 8)
            return Finding(
                name: name, ok: false,
                detail: "\(file.path) is mode \(text), readable by others; run: chmod 600 \(file.path). \(summary)")
        }
        return Finding(name: name, ok: true, detail: "\(file.path) parses, mode 600; \(summary)")
    }

    /// The subject kinds in force: each names a known temporal class and normaliser.
    func subjectKinds() -> Finding {
        let name = "subject kinds"
        let kinds = resolvedConfig.subjectKinds.kinds
        var problems: [String] = []
        let classes = Set(TemporalClass.allCases.map(\.rawValue))
        for kind in kinds {
            if !classes.contains(kind.temporalClass.rawValue) {
                problems.append("kind \(kind.name): unknown class \(kind.temporalClass.rawValue)")
            }
            if FactNormalisers.named(kind.normaliser) == nil {
                problems.append("kind \(kind.name): unknown normaliser \(kind.normaliser)")
            }
        }
        guard problems.isEmpty else {
            return Finding(
                name: name, ok: false,
                detail: problems.joined(separator: "; ") + "; normalisers are "
                    + FactNormalisers.names.joined(separator: ", "))
        }
        let shipped = Dictionary(uniqueKeysWithValues: SubjectKinds.defaults.kinds.map { ($0.name, $0) })
        let added = kinds.filter { shipped[$0.name] == nil }.map(\.name)
        let changed = kinds.filter { shipped[$0.name] != nil && shipped[$0.name] != $0 }.map(\.name)
        var detail = "\(kinds.count) kinds, each with a known class and normaliser (config decoding rejects others)"
        if !added.isEmpty { detail += "; added by config: " + added.joined(separator: ", ") }
        if !changed.isEmpty { detail += "; changed by config: " + changed.joined(separator: ", ") }
        return Finding(name: name, ok: true, detail: detail)
    }

    /// Saved transcripts: each has a `.store` sidecar that decodes and matches, so it can be resumed.
    func savedTranscripts() -> Finding {
        let name = "saved transcripts"
        let store = TranscriptStore(directory: home.transcripts)
        guard let names = try? store.list() else {
            return Finding(name: name, ok: false, detail: "cannot list \(home.transcripts.path)")
        }
        guard !names.isEmpty else { return Finding(name: name, ok: true, detail: "none saved") }
        let stuck = names.filter { (try? store.loadThread($0)) == nil }
        guard stuck.isEmpty else {
            return Finding(
                name: name, ok: false,
                detail: "\(stuck.count) of \(names.count) cannot be resumed: " + stuck.joined(separator: ", ")
                    + "; they were saved by an older wisp or their .store file is missing or damaged; delete them "
                    + "(in \(home.transcripts.path)) or start new conversations")
        }
        return Finding(name: name, ok: true, detail: "\(names.count) saved, each with a matching .store")
    }

    /// The numeric settings are in range: `inlineOutputBytes` and `shownOutputLines` are clamped at 0 and
    /// `facts.share` must be between 0 and 0.5, which loading the config enforces.
    func settingsInRange() -> Finding {
        let name = "settings"
        var config = Config()
        if FileManager.default.fileExists(atPath: home.configFile.path) {
            // Decoded without validation, so an out-of-range value is reported here, not just refused.
            guard let data = try? Data(contentsOf: home.configFile),
                let decoded = try? JSONDecoder().decode(Config.self, from: data)
            else { return Finding(name: name, ok: true, detail: "not checked: config.json does not parse") }
            config = decoded
        }
        var notes: [String] = []
        var problems: [String] = []
        if let value = config.inlineOutputBytes, value < 0 { notes.append("inlineOutputBytes \(value) is used as 0") }
        if let value = config.shownOutputLines, value < 0 { notes.append("shownOutputLines \(value) is used as 0") }
        if let share = config.facts?.share, !(0...0.5).contains(share) {
            problems.append("facts.share \(share) must be between 0 and 0.5; wisp refuses to load this config")
        }
        guard problems.isEmpty else { return Finding(name: name, ok: false, detail: problems.joined(separator: "; ")) }
        let resolved = resolvedConfig
        let state =
            "inlineOutputBytes \(resolved.inlineOutputBytes), shownOutputLines \(resolved.shownOutputLines), "
            + "facts.share \(resolved.factsShare)"
        let clamped = notes.isEmpty ? "" : " (clamped: " + notes.joined(separator: "; ") + ")"
        return Finding(name: name, ok: true, detail: "in range: " + state + clamped)
    }

    /// The context window wisp would use for the configured model, and how it is known.
    ///
    /// - Parameter unavailable: Why the model cannot be used, when an earlier check found it so.
    /// - Returns: The finding; never not ok.
    func contextWindow(unavailable: String?) -> Finding {
        let name = "context window"
        if unavailable != nil {
            return Finding(name: name, ok: true, detail: "not checked: \(model) is not available")
        }
        guard let reading = probes.contextWindow(model, resolvedConfig, home) else {
            return Finding(name: name, ok: true, detail: "not checked: \(model) did not resolve")
        }
        return Finding(name: name, ok: true, detail: Self.describe(window: reading, model: model))
    }

    /// The window and its source in words.
    ///
    /// - Parameters:
    ///   - window: What the resolved model reported.
    ///   - model: The model it is for.
    /// - Returns: For example `8,192 tokens, reported by the framework`.
    static func describe(window: ContextWindow, model: ModelSelection) -> String {
        guard let size = window.size else {
            return "unknown: the model states no window, so wisp assumes "
                + "\(Agent.assumedWindow.formatted()) tokens until an overflow tells it"
        }
        let tokens = "\(size.formatted()) tokens"
        guard let note = window.note else {
            return model == .system || model == .privateCloud
                ? "\(tokens), reported by the framework" : "\(tokens), declared by the model backend"
        }
        if note.hasPrefix("configured") { return "\(tokens), configured (ollama.contextLength)" }
        if note.contains("the default") { return "\(tokens), the default, not sized: \(note)" }
        return "\(tokens), sized from memory (ADR 0043): \(note)"
    }
}

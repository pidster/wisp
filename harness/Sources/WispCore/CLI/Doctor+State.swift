import Foundation

/// The doctor's checks of what wisp keeps and how it is set: the facts store, the subject kinds, saved
/// transcripts, the thread store, numeric settings, and the context window.
extension Doctor {
    /// `~/.wisp/facts.json`: no unreadable store set aside beside it, absent or parses, is readable by the owner
    /// only, and how many current facts it holds.
    func factsStore() -> Finding {
        let name = "facts store"
        let file = home.factsFile
        // A store wisp could not read is moved aside, never overwritten (`SharedFacts`); it waits for the person.
        let prefix = file.lastPathComponent + SharedFacts.unreadableSuffix
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: home.root.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted()
        if let latest = aside.last {
            let path = home.root.appending(path: latest).path
            return Finding(
                name: name, ok: false,
                detail: "\(path) is a facts store wisp could not read and set aside"
                    + (aside.count > 1 ? " (\(aside.count) such files)" : "")
                    + "; its facts are not in force. Look at it, mend it into \(file.path) or remove it")
        }
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
                detail: "\(file.path) does not parse: \(error); wisp moves it aside, to "
                    + "\(prefix)<time>, when it next reads it, and starts with no permanent facts")
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

    /// The thread store (ADR 0066): how many threads are saved, which a process holds and who, what they take on
    /// disk, and how many the next session's sweep deletes under `threads.keepDays`; a `thread.json` this build cannot
    /// read is a warning naming `wisp threads delete`.
    func threads() -> Finding {
        let name = "threads"
        let store = ThreadStore(home: home)
        let unreadable = store.unreadable
        let saved = store.all
        var parts: [String] = []
        if !saved.isEmpty {
            let held = saved.compactMap { settings in
                store.holder(of: settings.id).map { holder in
                    settings.id + (holder.pid > 0 ? " (pid \(holder.pid)\(holder.owner.map { ", \($0)" } ?? ""))" : "")
                }
            }
            parts.append(
                "\(saved.count) saved, \(ThreadAdmin.bytes(ThreadAdmin.size(of: store.root))) on disk"
                    + (held.isEmpty ? "" : "; open: " + held.joined(separator: ", ")))
            let days = resolvedConfig.threadsKeepDays
            let sweep = ThreadSweep(home: home, days: days)
            if let cutoff = sweep.cutoff {
                let due = saved.filter { $0.lastUsed < cutoff && store.holder(of: $0.id) == nil }.count
                parts.append("the next sweep deletes \(due) (threads.keepDays \(days))")
            } else {
                parts.append("never swept (threads.keepDays 0)")
            }
        }
        guard unreadable.isEmpty else {
            parts.append(
                "\(unreadable.count) cannot be read here: \(unreadable.joined(separator: ", ")); wisp threads show ID "
                    + "says why, and wisp threads delete ID removes one")
            return Finding(name: name, ok: false, detail: parts.joined(separator: "; "))
        }
        guard !parts.isEmpty else { return Finding(name: name, ok: true, detail: "none saved") }
        return Finding(name: name, ok: true, detail: parts.joined(separator: "; "))
    }

    /// The numeric settings are in range: `inlineOutputBytes` and `shownOutputLines` are clamped at 0,
    /// `facts.share` and `facts.summaryShare` must be between 0 and 0.5, and `context.target`,
    /// `context.headroomTurns`, `context.outputDays`, and `commandMaxTimeoutSeconds` within their ranges, which loading the config enforces; a `context.target` above the
    /// budget less `ContextComposer.targetMargin` is accepted and reported as used at that cap. The detail also states
    /// the command time limits and `commandPolicy.sandbox.allowOutsideSandbox` as resolved.
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
        if let share = config.facts?.summaryShare, !(0...0.5).contains(share) {
            problems.append(
                "facts.summaryShare \(share) must be between 0 and 0.5; wisp refuses to load this config")
        }
        if let target = config.context?.target, !Config.ContextConfig.targetRange.contains(target) {
            problems.append("context.target \(target) must be between 0.1 and 0.8; wisp refuses to load this config")
        }
        if let turns = config.context?.headroomTurns, !Config.ContextConfig.headroomRange.contains(turns) {
            problems.append(
                "context.headroomTurns \(turns) must be between 0 and 64; wisp refuses to load this config")
        }
        if let days = config.context?.outputDays, !Config.ContextConfig.outputDaysRange.contains(days) {
            problems.append(
                "context.outputDays \(days) must be between 0 and 3650; wisp refuses to load this config")
        }
        if let seconds = config.commandMaxTimeoutSeconds, !Config.commandMaxTimeoutRange.contains(seconds) {
            problems.append(
                "commandMaxTimeoutSeconds \(seconds) must be between 1 and 86400; wisp refuses to load this config")
        }
        guard problems.isEmpty else { return Finding(name: name, ok: false, detail: problems.joined(separator: "; ")) }
        let resolved = resolvedConfig
        let state =
            "inlineOutputBytes \(resolved.inlineOutputBytes), shownOutputLines \(resolved.shownOutputLines), "
            + "facts.share \(resolved.factsShare), facts.summaryShare \(resolved.summaryShare), "
            + "context.target \(resolved.contextTarget.share), context.headroomTurns \(resolved.contextTarget.headroomTurns), "
            + "commandTimeoutSeconds \(resolved.runner.timeout.components.seconds), "
            + "commandMaxTimeoutSeconds \(resolved.runner.maxTimeout.components.seconds), "
            + "commandPolicy.sandbox.allowOutsideSandbox \(resolved.runner.policy.sandbox.allowOutsideSandbox)"
        let composer = ContextComposer()
        let configured = config.context?.target ?? resolved.contextTarget.share
        let effective = composer.effectiveShare(of: ContextTarget(share: configured))
        if effective < configured {
            notes.append(
                "context.target \(configured) is used as \(effective), the context budget "
                    + "\(composer.budget) less \(ContextComposer.targetMargin), so a condensation leaves room before "
                    + "the next")
        }
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
        if note.hasPrefix(ContextSizing.perModelPrefix) {
            return "\(tokens), configured for this model (\(note.dropFirst(ContextSizing.perModelPrefix.count)))"
        }
        if note.hasPrefix("configured as ") {
            return "\(tokens), configured (\(note.dropFirst("configured as ".count)))"
        }
        if note.hasPrefix("declared") { return "\(tokens), \(note)" }
        if note.contains("the default") { return "\(tokens), the default, not sized: \(note)" }
        return "\(tokens), sized from memory (ADR 0043): \(note)"
    }
}

extension Doctor {
    /// `~/.wisp/pending`, where commands waiting for approval under `wisp mcp` are answered from another face
    /// (ADR 0046): absent until first used, or a directory of this user's that no one else can open, with how
    /// many requests wait and how many are stale.
    func pendingApprovals() -> Finding {
        let name = "pending approvals"
        let channel = PendingApprovals(home: home)
        let path = channel.directory.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Finding(name: name, ok: true, detail: "no \(path) yet; made when wisp mcp first waits for approval")
        }
        if let problem = PendingApprovals.problem(with: path) { return Finding(name: name, ok: false, detail: problem) }
        let waiting = channel.waiting(.command).count
        let facts = channel.waiting(.fact).count
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let stale = files.filter { $0.hasSuffix(".request.json") || $0.hasSuffix(".fact.json") }.count - waiting - facts
        let staleNote = stale > 0 ? "; \(stale) stale, removed by the next 'wisp approvals pending'" : ""
        // Facts a caller asked to keep (ADR 0048) wait in the same directory.
        let factNote = facts > 0 ? ", \(facts) facts to keep (wisp facts pending)" : ""
        return Finding(
            name: name, ok: true,
            detail: "\(path) is mode 700; \(waiting) waiting (wisp approvals pending)\(factNote)\(staleNote)")
    }
}

extension Doctor {
    /// `~/.wisp/output`, where tool outputs larger than the budget are kept whole (ADR 0050): how many sessions it
    /// holds and their size, what the next start's sweep would remove (`context.outputDays` after a session's last
    /// use), and any entries that are not wisp's, which the sweep leaves alone. Never not ok: a store is never wrong,
    /// only large.
    func outputStore() -> Finding {
        let name = "output store"
        let sweep = OutputSweep(home: home, days: resolvedConfig.contextOutputDays)
        let path = sweep.root.path
        guard FileManager.default.fileExists(atPath: path) else {
            return Finding(
                name: name, ok: true, detail: "no \(path) yet; made when a tool output first passes the budget")
        }
        let survey = sweep.survey()
        let total = survey.sessions.reduce(0) { $0 + $1.bytes }
        var detail =
            "\(path) holds \(survey.sessions.count) session\(survey.sessions.count == 1 ? "" : "s"), "
            + ToolOutput.size(total)
        if sweep.days == 0 {
            detail += "; never swept (context.outputDays 0)"
        } else {
            let due = sweep.due(in: survey)
            let bytes = due.reduce(0) { $0 + $1.bytes }
            detail += "; kept \(sweep.days) days after last use (context.outputDays): "
            detail +=
                due.isEmpty
                ? "the next sweep removes nothing"
                : "the next sweep removes \(due.count) (\(ToolOutput.size(bytes)))"
                    + (due.count > OutputSweep.removalLimit
                        ? ", \(OutputSweep.removalLimit) a start" : "")
        }
        if !survey.foreign.isEmpty {
            let shown = survey.foreign.prefix(3).joined(separator: ", ")
            detail +=
                "; \(survey.foreign.count) not wisp's, left alone: \(shown)"
                + (survey.foreign.count > 3 ? ", …" : "")
        }
        return Finding(name: name, ok: true, detail: detail)
    }
}

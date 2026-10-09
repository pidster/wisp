import Foundation

/// `/config`: the effective configuration, the settings that can change, and changes to `config.json`
/// made by the person at the prompt, never by the model ([ADR 0040](../../../../docs/decisions/0040-config-from-chat.md)).
extension ChatLoop {
    /// Handles one `/config` request.
    mutating func config(_ request: ConfigRequest) async {
        switch request {
        case .show:
            await view("config")
        case .get(let path?):
            guard ConfigSettings.setting(path) != nil else {
                io.note(style.ember("error: \(ConfigEdit.Failure.unknownSetting(path))"))
                return
            }
            let set: JSONValue? = (try? ConfigEdit.current(path, in: configData)) ?? nil
            if let set {
                io.print("\(path): \(Self.shown(set))  (set in config.json)")
            } else {
                let fallback = ConfigSettings.defaultValue(path).map(Self.shown) ?? "nothing"
                io.print("\(path): \(fallback)  (the default)")
            }
        case .get(nil):
            guard let path = await ask(settingChoice(title: "Which setting?", onlySet: false)) else {
                return io.note("left as it was")
            }
            await config(.get(path))
        case .list:
            for line in configList() { io.print(line) }
        case .set(let path?, let value?):
            change(path) { try ConfigEdit.set(path, to: value, in: $0) }
        case .set(let path?, nil):
            guard let setting = ConfigSettings.setting(path) else {
                io.note(style.ember("error: \(ConfigEdit.Failure.unknownSetting(path))"))
                return
            }
            guard let value = await ask(await valueChoice(for: setting)) else { return io.note("left as it was") }
            change(path) { try ConfigEdit.set(path, to: value, in: $0) }
        case .set(nil, _):
            guard let path = await ask(settingChoice(title: "Which setting?", onlySet: false)) else {
                return io.note("left as it was")
            }
            await config(.set(path: path, value: nil))
        case .unset(let path?):
            change(path) { try ConfigEdit.unset(path, in: $0) }
        case .unset(nil):
            let choice = settingChoice(title: "Which setting goes back to its default?", onlySet: true)
            guard !choice.options.isEmpty else { return io.note("no setting in config.json can be unset here") }
            guard let path = await ask(choice) else { return io.note("left as it was") }
            change(path) { try ConfigEdit.unset(path, in: $0) }
        case .unknown(let word):
            io.note("unknown /config \(word); use /config, /config list, /config set KEY VALUE, or /config unset KEY")
        }
    }

    /// One of wisp's own views, as the model's `inspect` tool gives it: JSON for the model and scripts,
    /// shown to a person as YAML; the audit view is text already.
    func view(_ what: String) async {
        guard let inspect = context.inspect else {
            io.note("wisp's own state is not shown here")
            return
        }
        let text = await inspect(what)
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        io.print(value.map(YAMLText.render) ?? text)
    }

    /// `/approvals`: the standing approvals, or revoking one.
    func approvals(_ request: ApprovalsRequest) async {
        switch request {
        case .list:
            await view("approvals")
        case .revoke(let id):
            guard let store = context.approvalStore else { return io.note("approvals cannot be revoked here") }
            let entries = await store.all
            guard !entries.isEmpty else { return io.note("no standing approvals") }
            var chosen = id
            if chosen == nil {
                let options = entries.map { entry in
                    ChatChoice.Option(
                        value: entry.id, label: entry.pattern,
                        detail: "\(entry.scope.rawValue), \(entry.workingDirectory ?? "any directory")")
                }
                chosen = await ask(ChatChoice(title: "Which approval goes?", options: options))
            }
            guard let chosen else { return io.note("left as it was") }
            do {
                let removed = try await store.revoke(id: chosen)
                io.note(
                    removed
                        ? "revoked \(chosen); it no longer applies, in this session or any other"
                        : "no approval \(chosen)")
            } catch {
                io.note(style.ember("error: \(error)"))
            }
        case .unknown(let word):
            io.note("unknown /approvals \(word); use /approvals or /approvals revoke [ID]")
        }
    }

    /// Asks through the face's own chooser, or with a numbered list read from the prompt.
    func ask(_ choice: ChatChoice) async -> String? {
        if let choose = io.choose { return await choose(choice) }
        for line in choice.numbered { io.print(line) }
        return io.readLine().flatMap(choice.answer(typed:))
    }

    /// The file's contents now, nil when there is none or it cannot be read.
    var configData: Data? { context.configFile.flatMap { try? Data(contentsOf: $0) } }

    /// The settings to choose from, each with its value; with `onlySet`, only those in the file.
    func settingChoice(title: String, onlySet: Bool) -> ChatChoice {
        let data = configData
        let options = ConfigSettings.listed(in: data).compactMap { setting -> ChatChoice.Option? in
            let current: JSONValue? = (try? ConfigEdit.current(setting.path, in: data)) ?? nil
            if onlySet, current == nil { return nil }
            return ChatChoice.Option(
                value: setting.path, detail: "\(current.map(Self.shown) ?? "(default)")  \(setting.summary)")
        }
        return ChatChoice(title: title, options: options)
    }

    /// The answers for one setting: its fixed choices, true and false, or what the face knows of (models,
    /// Core ML files), with typed text taken wherever the kind allows it.
    func valueChoice(for setting: ConfigSettings.Setting) async -> ChatChoice {
        let current: JSONValue? = (try? ConfigEdit.current(setting.path, in: configData)) ?? nil
        let title = "\(setting.path): \(setting.summary)"
        let known = await context.configOptions?(setting) ?? []
        let shown = current.map(Self.shown)
        switch setting.kind {
        case .choice(let values):
            return ChatChoice(title: title, options: values.map { ChatChoice.Option(value: $0) }, current: shown)
        case .flag:
            return ChatChoice(
                title: title, options: [ChatChoice.Option(value: "true"), ChatChoice.Option(value: "false")],
                current: shown)
        case .model, .coremlModel:
            return ChatChoice(title: title, options: known, current: shown, acceptsText: true)
        case .integer, .number, .text, .models, .tools, .publishers:
            let hint = shown.map { " (now \($0))" } ?? " (now the default)"
            return ChatChoice(title: title + hint, options: known, current: shown, acceptsText: true)
        }
    }

    /// The settings as a table: each path, its value in the file or `(default)`, and what it does.
    func configList() -> [String] {
        let data = configData
        let rows = ConfigSettings.listed(in: data).map { setting -> [String] in
            let current: JSONValue? = (try? ConfigEdit.current(setting.path, in: data)) ?? nil
            return [setting.path, current.map(Self.shown) ?? "(default)", setting.summary]
        }
        return TextTable.render(header: ["setting", "value", "what it does"], rows: rows)
    }

    /// A value as the table and the confirmation show it: strings bare, everything else as JSON.
    public static func shown(_ value: JSONValue) -> String {
        if let text = value.stringValue { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
    }

    /// Applies an edit to the config file, audits it, and says what changed and when it takes effect.
    mutating func change(_ path: String, _ edit: (Data?) throws -> ConfigEdit.Outcome) {
        guard let url = context.configFile else {
            io.note("the configuration cannot be changed here")
            return
        }
        do {
            let outcome = try edit(try ConfigEdit.existing(at: url))
            try ConfigEdit.write(outcome, to: url)
            agent.audit?.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: "chat"))
            let old = outcome.old.map(Self.shown) ?? "(default)"
            let new = outcome.new.map(Self.shown) ?? "(default)"
            io.note("\(path): \(old) → \(new); saved to \(url.path), and used from the next session on")
            if let warning = outcome.warning { io.note(style.amber("note: \(warning)")) }
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }
}

extension ConfigEdit {
    /// Why the config file could not be read for an edit.
    public struct Unreadable: Error, CustomStringConvertible, Equatable {
        /// The file.
        public let path: String
        /// What reading it said.
        public let reason: String

        /// Human-readable explanation.
        public var description: String {
            "cannot read \(path) (\(reason)); nothing was changed, so the settings in it are kept. "
                + "Fix its permissions, or move it aside to start afresh"
        }
    }

    /// The config file's bytes for an edit, or nil when there is no file yet. Only a missing file is absent: a
    /// file that exists but cannot be read (its permissions, a directory in its place) refuses the edit,
    /// because writing as if it were absent would drop every other setting in it.
    ///
    /// - Parameter url: The config file.
    /// - Returns: Its bytes, or nil when it does not exist.
    /// - Throws: `Unreadable`.
    public static func existing(at url: URL) throws(Unreadable) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        } catch {
            let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
            throw Unreadable(path: url.path, reason: reason)
        }
    }
}

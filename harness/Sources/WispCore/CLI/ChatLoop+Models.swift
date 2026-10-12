import Foundation

extension ChatLoop {
    /// `/models` ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md),
    /// [ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)), through the chat's `ModelActions`: the
    /// listing as a table; in a face with choices, as a picker whose rows the person turns on and off and saves
    /// together, with a "pull a model…" row where this build can pull; with `enable` or `disable`, those models turned
    /// on or off, and an enabled model whose capabilities are undeclared checked; with `check`, those models checked
    /// again; with `pull`, a model fetched after the publisher and download questions; with `trust`, a publisher
    /// trusted from now on; with `cancel`, a pull the model asked for stopped.
    ///
    /// - Parameter request: What followed `/models`.
    func models(_ request: ModelsRequest) async {
        guard let actions = context.models else {
            io.note("models are not listed here")
            return
        }
        switch request {
        case .enable(let names): await set(actions, enable: names, disable: [])
        case .disable(let names): await set(actions, enable: [], disable: names)
        case .check(let names): await check(actions, names)
        case .pull(let repository): await pull(actions, repository)
        case .trust(let publisher):
            do {
                io.note(try actions.trust(publisher))
            } catch {
                io.note(style.ember("error: \(error)"))
            }
        case .cancel(let repository):
            let cancelled = actions.session.modelPulls.cancel(repository)
            io.note(
                cancelled.isEmpty
                    ? "no pull is running" + (repository.map { " for \($0)" } ?? "")
                    : "cancelling the pull of \(cancelled.joined(separator: ", ")); what arrived is kept")
        case .unknown(let word):
            io.note("unknown /models argument '\(word)'; \(ModelsRequest.usage)")
        case .list:
            await list(actions)
        }
    }

    /// `/model` with no name: the model in use and its capabilities; then, in a face with a chooser of its own
    /// (`wisp-tui`), the models `/model` can switch to (enabled, and able to serve the conversation's tools), the one
    /// in use marked, as a picker. Choosing one switches as `/model NAME` does; no answer, or the one in use, leaves it
    /// (`model unchanged`). The plain chat, which reads a line at a time, only prints the model.
    mutating func showModel() async {
        let current = agent.model.selection.description
        io.print("model: \(current) (\(agent.model.capabilityNames.joined(separator: ", ")))")
        guard let choose = io.choose, let actions = context.models, context.openModel != nil else { return }
        let options = await actions.list(tools: agent.tools).entries.filter(\.offered).map {
            ChatChoice.Option(value: $0.selection.description, detail: $0.detail)
        }
        guard !options.isEmpty else { return }
        let answer = await choose(ChatChoice(title: "Switch to which model?", options: options, current: current))
        guard let name = answer?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != current else {
            io.note(style.muted("model unchanged"))
            return
        }
        switchModel(to: name)
    }

    /// The listing: a table, or in a face with choices the picker, whose save turns models on and off and whose
    /// "pull a model…" row asks for a repository and pulls it.
    ///
    /// - Parameter actions: The chat's model actions.
    private func list(_ actions: ModelActions) async {
        let listing = await actions.list(tools: agent.tools)
        let current = agent.model.selection
        guard let choose = io.choose, !listing.shown(all: false).isEmpty else {
            let lines =
                context.width().map { ModelTable.terminal(listing, current: current, all: false, width: $0) }
                ?? ModelTable.text(listing, current: current)
            for line in lines { io.print(line) }
            return
        }
        let choice = ModelTable.choice(listing, current: current, pulls: actions.puller != nil)
        let answer = await choose(choice)
        if answer == ModelTable.pullRow {
            let asked = await choose(
                ChatChoice(
                    title: "Pull which repository? <organisation>/<name>, such as mlx-community/Qwen3-1.7B-4bit",
                    options: [], acceptsText: true))
            guard let repository = asked?.trimmingCharacters(in: .whitespaces), !repository.isEmpty else {
                io.note(style.muted("nothing pulled"))
                return
            }
            await pull(actions, repository)
            return
        }
        guard let values = ChatChoice.values(answer: answer) else {
            io.note(style.muted("models unchanged"))
            return
        }
        let on = Set(values)
        let enable = choice.options.filter { on.contains($0.value) && $0.on == false }.map(\.value)
        let disable = choice.options.filter { !on.contains($0.value) && $0.on == true }.map(\.value)
        guard !enable.isEmpty || !disable.isEmpty else {
            io.note(style.muted("models unchanged"))
            return
        }
        await set(actions, enable: enable, disable: disable)
    }

    /// Turns models on and off, then checks those turned on that are undeclared, noting each line as it happens.
    ///
    /// - Parameters:
    ///   - actions: The chat's model actions.
    ///   - enable: The models to turn on.
    ///   - disable: The models to turn off.
    private func set(_ actions: ModelActions, enable: [String], disable: [String]) async {
        let note = io.note
        do {
            try await actions.set(enable: enable, disable: disable, report: note)
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }

    /// Checks what models can do, noting each line of progress as it happens and what was recorded (ADR 0056, refined
    /// 2026-10-04).
    ///
    /// - Parameters:
    ///   - actions: The chat's model actions.
    ///   - names: The models.
    private func check(_ actions: ModelActions, _ names: [String]) async {
        do {
            try await actions.check(names, report: io.note)
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }

    /// Pulls a model as the person asked (ADR 0059): the plan and the questions as notes and the face's choice dialog
    /// (the publisher: refuse, pull once, or trust from now on, refused by default; the download and a directory to
    /// replace: no by default), the download's progress as the activity a face shows in its status line, begun once
    /// the questions are answered, and Ctrl-C
    /// (the face's `interrupt`) stopping it through `Context.interrupt`, as it stops a command the person typed,
    /// keeping what arrived for the next pull to resume.
    ///
    /// - Parameters:
    ///   - actions: The chat's model actions.
    ///   - repository: The repository, as typed.
    private func pull(_ actions: ModelActions, _ repository: String) async {
        let note = io.note
        let style = style
        let activity = context.activity
        let interrupt = context.interrupt
        let stop = CommandStop()
        let dialog = PullDialog(
            interactive: true, show: { note($0) }, notice: { note(style.muted($0)) },
            publisher: { summary in
                for line in PublisherCheck.question(for: summary).dropLast() { note(line) }
                return PublisherCheck.Answer(typed: await ask(PublisherCheck.Answer.choice(for: summary)))
            },
            confirm: { question in
                await ask(
                    ChatChoice(
                        title: question,
                        options: [.init(value: "no", detail: "the default"), .init(value: "yes")], current: "no"))
                    == "yes"
            },
            progress: { step in
                // The activity begins with the download, after the questions, so the working line never draws over one.
                if activity?.current == nil {
                    activity?.begin(doing: step.line, stoppable: interrupt != nil)
                } else {
                    activity?.progress(step.line)
                }
            }, stop: stop)
        interrupt?.arm("models pull \(repository)", stop: stop) { _ in
            activity?.stopping("stopping the pull of \(repository)")
        }
        defer {
            interrupt?.disarm()
            activity?.end()
        }
        do {
            let result = try await actions.pull(repository, dialog: dialog)
            if result.outcome == .cancelled {
                note(
                    style.muted(
                        "stopped the pull of \(repository) after \(PullSummary.size(result.fetched)); what arrived "
                            + "is kept, and /models pull \(repository) resumes it"))
            }
        } catch {
            note(style.ember("error: \(error)"))
        }
    }
}

import Foundation

/// How a pull talks to the person in a face (ADR 0059): the terminal's lines and `[y/N]`, or chat's notes and choice
/// dialog. The questions are asked on the caller's own task; only the fetch runs beside it, so `progress`, `notice`,
/// and `stop` reach it from there. The model's pull has one of its own that asks nothing, its approval having been
/// given first.
public struct PullDialog {
    /// Whether the person can be asked here; without one, an untrusted publisher is refused before any request and
    /// nothing is fetched.
    public var interactive: Bool
    /// Shows a line of the plan or the outcome.
    public var show: (String) -> Void
    /// Shows a line of progress: a cached file being checked, a file starting, one resumed.
    public var notice: @Sendable (String) -> Void
    /// Puts the publisher question (`PublisherCheck.question(for:)`) and returns the answer; anything but an answer
    /// of once or trust refuses.
    public var publisher: (PullSummary) async -> PublisherCheck.Answer
    /// Asks a yes-or-no question (the download, replacing a directory); no is the default.
    public var confirm: (String) async -> Bool
    /// Told how far the download has gone, about twice a second while a file arrives.
    public var progress: @Sendable (PullProgress) -> Void
    /// Stops the fetch when the person asks (Ctrl-C, the face's `interrupt`), as a command they typed is stopped
    /// (`CommandStop`, ADR 0049): the part of the file being fetched is kept. Nil fetches to the end, or until the
    /// task is cancelled.
    public var stop: CommandStop?

    /// Creates a dialog.
    public init(
        interactive: Bool, show: @escaping (String) -> Void, notice: @escaping @Sendable (String) -> Void,
        publisher: @escaping (PullSummary) async -> PublisherCheck.Answer, confirm: @escaping (String) async -> Bool,
        progress: @escaping @Sendable (PullProgress) -> Void = { _ in }, stop: CommandStop? = nil
    ) {
        self.interactive = interactive
        self.show = show
        self.notice = notice
        self.publisher = publisher
        self.confirm = confirm
        self.progress = progress
        self.stop = stop
    }

    /// The dialog of a pull the person already approved: it shows nothing, answers the publisher question `once`
    /// (the approval named the publisher), and refuses to replace a directory, which only the person may agree to.
    ///
    /// - Parameter progress: Told how far the download has gone.
    /// - Returns: The dialog.
    static func approved(progress: @escaping @Sendable (PullProgress) -> Void) -> PullDialog {
        PullDialog(
            interactive: false, show: { _ in }, notice: { _ in }, publisher: { _ in .once }, confirm: { _ in false },
            progress: progress)
    }
}

/// How a pull ended.
public struct PullResult: Equatable, Sendable {
    /// The outcome, as `model.pull` records it.
    public enum Outcome: String, Sendable {
        /// Files were downloaded and the model linked.
        case fetched
        /// Nothing needed downloading; the model was linked.
        case linked
        /// The person refused the publisher or the download.
        case declined
        /// The pull was cancelled part-way; what arrived stays for the next pull to resume.
        case cancelled
    }

    /// How it ended.
    public var outcome: Outcome
    /// The repository.
    public var repository: String
    /// The selection the model becomes, `mlx:<name>`.
    public var selection: String
    /// Bytes this run downloaded (for a cancelled pull, as far as its progress last said).
    public var fetched: Int
    /// The line the person reads at the end; nil when the pull did not get as far as linking.
    public var closing: String?
}

extension ModelActions {
    /// The person's pull (`wisp models pull`, `/models pull`, `wisp-tui`'s "pull a model…" row; ADR 0052, 0059): the
    /// name checked, the publisher screened (`PublisherCheck`), the repository listed, the plan shown, the publisher
    /// question put when it is not trusted, the download asked about unless that answer approved it, the files
    /// fetched with their progress, a real directory at the link's path replaced only if the person agrees, and the
    /// model linked; recorded as `model.publisher` and `model.pull`. Cancelling the task stops the fetch and keeps the
    /// part of the file it was fetching.
    ///
    /// - Parameters:
    ///   - text: The repository, as typed.
    ///   - trustFlag: Whether `--trust-publisher` was given.
    ///   - dialog: How the face asks and shows.
    /// - Returns: How it ended.
    /// - Throws: `Failure.notForTheModel` from the tool (its pull is `requestPull`), `Failure.noPuller`,
    ///   `Failure.notInteractive`, `PublisherCheck.Refusal`, the puller's failure (the name, the listing, the fetch),
    ///   or `ConfigEdit.Failure` when trusting the publisher cannot be written.
    nonisolated(nonsending) public func pull(
        _ text: String, trustFlag: Bool = false, dialog: PullDialog
    ) async throws -> PullResult {
        guard face != .tool else { throw Failure.notForTheModel(Action.pull.rawValue) }
        guard let puller else { throw Failure.noPuller }
        let named = try puller.repository(text).repository
        let check = PublisherCheck(session: session, trustFlag: trustFlag, source: face.rawValue, log: audit)
        let screened = try check.screen(named, interactive: dialog.interactive)
        guard dialog.interactive else { throw Failure.notInteractive }
        let prepared = try await puller.prepare(text, session: session, notice: dialog.notice)
        let summary = prepared.summary
        for line in summary.lines { dialog.show(line) }
        var started = ContinuousClock.now
        let decision: PublisherCheck.Decision
        if let screened {
            decision = check.settled(summary, screened)
        } else {
            let answer = await dialog.publisher(summary)
            started = .now
            decision = try check.answered(summary, answer)
        }
        guard decision.pulls else { return declined(summary, started: started, dialog: dialog) }
        if decision == .trust {
            dialog.show("\(summary.publisher) is trusted from now on (\(TrustedPublishers.setting)).")
        }
        if summary.missing > 0, !decision.approvedDownload {
            let yes = await dialog.confirm(
                "Fetch \(summary.missing) of them, \(PullSummary.size(summary.remaining))?")
            started = .now
            guard yes else { return declined(summary, started: started, dialog: dialog) }
        }
        return try await run(prepared, started: started, approval: nil, dialog: dialog)
    }

    /// Records a declined pull and says nothing was fetched.
    private func declined(_ summary: PullSummary, started: ContinuousClock.Instant, dialog: PullDialog) -> PullResult {
        record(summary, outcome: "declined", fetched: 0, link: nil, reason: nil, started: started, approval: nil)
        dialog.show("Nothing fetched.")
        return PullResult(
            outcome: .declined, repository: summary.repository, selection: summary.selection, fetched: 0, closing: nil)
    }

    /// Fetches and links an approved pull, recording `model.pull`: `fetched` or `linked`, `cancelled` when its task
    /// was cancelled (the part of the file being fetched kept), `failed` with the reason when it failed.
    ///
    /// - Parameters:
    ///   - prepared: The pull.
    ///   - started: When the last answer was given, or the plan made.
    ///   - approval: The approval of the model's request; nil for the person's.
    ///   - dialog: Where progress goes, and who agrees to replace a directory.
    /// - Returns: How it ended.
    /// - Throws: The fetch's or the link's failure, after recording it.
    nonisolated(nonsending) func run(
        _ prepared: PreparedPull, started: ContinuousClock.Instant, approval: String?, dialog: PullDialog
    ) async throws -> PullResult {
        let summary = prepared.summary
        let last = Guarded(0)
        let progress = dialog.progress
        func ended(_ outcome: PullResult.Outcome, fetched: Int, closing: String?) -> PullResult {
            PullResult(
                outcome: outcome, repository: summary.repository, selection: summary.selection, fetched: fetched,
                closing: closing)
        }
        let notice = dialog.notice
        // The fetch runs beside the caller, so the person's stop and the caller's cancellation both reach it.
        let fetching = Task {
            try await prepared.fetch(
                { step in
                    last.update { $0 = step.fetched }
                    progress(step)
                }, notice)
        }
        dialog.stop?.attach { _ in fetching.cancel() }
        defer { dialog.stop?.detach() }
        do {
            let fetched = try await withTaskCancellationHandler {
                try await fetching.value
            } onCancel: {
                fetching.cancel()
            }
            if fetching.isCancelled { throw CancellationError() }
            var replace = false
            if summary.replacesDirectory {
                replace = await dialog.confirm(
                    "\(summary.destination) is a directory of its own, not a link to the cache. Move it to the Trash "
                        + "and link \(summary.snapshot) in its place?")
            }
            let link = try prepared.link(replace)
            record(
                summary, outcome: summary.missing == 0 ? "linked" : "fetched", fetched: fetched, link: link.outcome,
                reason: nil, started: started, approval: approval)
            dialog.show(link.closing)
            return ended(summary.missing == 0 ? .linked : .fetched, fetched: fetched, closing: link.closing)
        } catch {
            if error is CancellationError || Task.isCancelled || fetching.isCancelled {
                let fetched = last.value
                record(
                    summary, outcome: "cancelled", fetched: fetched, link: nil,
                    reason: "cancelled; what arrived is kept for the next pull to resume", started: started,
                    approval: approval)
                return ended(.cancelled, fetched: fetched, closing: nil)
            }
            record(
                summary, outcome: "failed", fetched: 0, link: nil, reason: "\(error)", started: started,
                approval: approval)
            throw error
        }
    }

    /// Records a pull as `model.pull`.
    func record(
        _ summary: PullSummary, outcome: String, fetched: Int, link: String?, reason: String?,
        started: ContinuousClock.Instant, approval: String?
    ) {
        let elapsed = ContinuousClock.now - started
        audit.record(
            .modelPull,
            details: AuditEvent.Details.modelPull(
                model: summary.selection, repository: summary.repository, directory: summary.destination,
                cache: summary.snapshot, files: summary.files, bytes: summary.bytes, reused: summary.reused,
                seeded: outcome == "declined" ? 0 : summary.seeded,
                fetchedFiles: outcome == "fetched" ? summary.missing : 0, fetched: fetched, link: link,
                outcome: outcome, reason: reason,
                seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                source: face.rawValue, approval: approval))
    }
}

extension ModelActions {
    /// The model's pull through its `models` tool (ADR 0059): the repository listed, the person asked through the
    /// conversation's gate with the publisher, the licence, and the download (asked every time, never remembered),
    /// and, once approved, the pull started in the background (`Session.modelPulls`), the tool returning at once. Its
    /// end, or its failure, is posted to the conversation (`Session.notices`) and recorded as `model.pull` with the
    /// approval's id. Approving it pulls a publisher not trusted this once; trusting from now on is the person's alone.
    ///
    /// - Parameters:
    ///   - text: The repository, as the model gave it.
    ///   - gate: The conversation's approval gate.
    ///   - conversation: The conversation's audit session, which the note goes to.
    ///   - workingDirectory: Where the conversation runs.
    /// - Returns: What the tool answers: the pull started and how large it is, or why not.
    public func requestPull(
        _ text: String, gate: ApprovalGate, conversation: String, workingDirectory: String
    ) async -> String {
        guard let puller else { return ToolOutput.error(Failure.noPuller) }
        let summary: PullSummary
        let prepared: PreparedPull
        do {
            let repository = try puller.repository(text).repository
            guard !session.modelPulls.isRunning(repository) else {
                return ToolOutput.error(Failure.alreadyPulling(repository))
            }
            prepared = try await puller.prepare(text, session: session) { _ in }
            summary = prepared.summary
        } catch {
            return ToolOutput.error(error)
        }
        let trusted = TrustedPublishers.trusts(summary.publisher, config: session.config)
        let reasons = [
            summary.missing == 0
                ? "fetches nothing: every file is already on this Mac; links it as \(summary.selection)"
                : "downloads \(PublisherCheck.download(summary)) from Hugging Face, as \(summary.selection)",
            trusted
                ? "publisher \(summary.publisher) is trusted (\(TrustedPublishers.setting))"
                : "publisher \(summary.publisher) is not trusted: approving pulls it this once; only you can trust it "
                    + "(/models trust \(summary.publisher))",
            "licence: \(summary.licence ?? "unknown"); its weights, tokenizer, and chat template would run in wisp",
        ]
        let approval: String
        do {
            approval = try await gate.clear(
                modelAction: Action.pull.rawValue, subject: summary.repository, reasons: reasons,
                workingDirectory: workingDirectory)
        } catch {
            record(
                summary, outcome: "declined", fetched: 0, link: nil, reason: "\(error)", started: .now, approval: nil)
            return ToolOutput.error(error)
        }
        let started = ContinuousClock.now
        let check = PublisherCheck(
            session: session, trustFlag: false, source: face.rawValue, approval: approval, log: audit)
        do {
            _ = trusted ? check.settled(summary, .trusted) : try check.answered(summary, .once)
        } catch {
            return ToolOutput.error(error)
        }
        let notices = session.notices
        let actions = self
        let began = session.modelPulls.start(summary.repository, for: conversation) { progress in
            let note: String
            do {
                let result = try await actions.run(
                    prepared, started: started, approval: approval, dialog: .approved(progress: progress))
                note = Self.note(result, approval: approval)
            } catch {
                note =
                    "[wisp: the pull of \(summary.repository) you asked for (approval \(approval)) failed: \(error); "
                    + "what arrived is kept, and a pull asked for again resumes it]"
            }
            notices.post(note, to: conversation)
        }
        guard began else { return ToolOutput.error(Failure.alreadyPulling(summary.repository)) }
        return
            "pulling \(summary.repository) in the background (approval \(approval)): about "
            + "\(PullSummary.size(summary.remaining)) in \(summary.missing) of \(summary.files) files. Its end will "
            + "arrive as a note in this conversation; do not call models to check on it."
    }

    /// The note a background pull's end posts to its conversation.
    ///
    /// - Parameters:
    ///   - result: How it ended.
    ///   - approval: The approval's id.
    /// - Returns: The note.
    static func note(_ result: PullResult, approval: String) -> String {
        let head = "[wisp: the pull of \(result.repository) you asked for (approval \(approval))"
        switch result.outcome {
        case .fetched, .linked:
            let fetched =
                result.outcome == .fetched ? "fetched \(PullSummary.size(result.fetched))" : "nothing needed fetching"
            return head
                + " finished: \(fetched); it is \(result.selection). Its capabilities are undeclared until it is "
                + "checked: models enable \(result.selection) asks to turn it on and check it]"
        case .cancelled:
            return head + " was cancelled after \(PullSummary.size(result.fetched)); what arrived is kept]"
        case .declined:
            return head + " was declined]"
        }
    }

    /// The model's request to enable, disable, or check models through its `models` tool (ADR 0059): asked through the
    /// conversation's gate as `models <verb> <name>`, rememberable for the session at most, then done as the person's
    /// would be, recorded with the approval's id.
    ///
    /// - Parameters:
    ///   - action: `enable`, `disable`, or `check`.
    ///   - name: The model.
    ///   - gate: The conversation's approval gate.
    ///   - workingDirectory: Where the conversation runs.
    /// - Returns: What the tool answers: the lines saying what changed, or why nothing did.
    public func requestChange(
        _ action: Action, _ name: String, gate: ApprovalGate, workingDirectory: String
    ) async -> String {
        guard [.enable, .disable, .check].contains(action) else {
            return ToolOutput.error(Failure.notForTheModel(action.rawValue))
        }
        do {
            _ = try ModelSelection(parsing: name)
            let reason =
                switch action {
                case .enable: "turns \(name) on in config.json (models.disabled), checking what it can do if undeclared"
                case .disable: "turns \(name) off in config.json (models.disabled): refused until enabled"
                default: "loads \(name) and asks it three short questions, recording what passes in config.json"
                }
            let approval = try await gate.clear(
                modelAction: action.rawValue, subject: name, reasons: [reason], workingDirectory: workingDirectory)
            let lines = Guarded<[String]>([])
            let report: @Sendable (String) -> Void = { line in lines.update { $0.append(line) } }
            switch action {
            case .enable: try await set(enable: [name], disable: [], approval: approval, report: report)
            case .disable: try await set(enable: [], disable: [name], approval: approval, report: report)
            default: try await check([name], force: true, approval: approval, report: report)
            }
            let said = lines.value
            return ToolOutput.bounded(
                said.isEmpty ? "\(name): nothing changed" : said.joined(separator: "\n"), maxBytes: ModelsTool.maxBytes)
        } catch {
            return ToolOutput.error(error)
        }
    }
}

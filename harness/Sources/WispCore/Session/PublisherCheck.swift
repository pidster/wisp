import Foundation

/// Whether a pull may fetch from a repository's publisher
/// ([ADR 0052](../../../../docs/decisions/0052-mlx-on-a-par-with-ollama.md), amended 2026-10-09; every face since
/// [ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)). Any Hugging Face organisation can be
/// pulled. One in `mlx.trustedPublishers` (and `mlx-community`, always) is pulled without this question;
/// `--trust-publisher` skips it once; any other is put to the person, naming the publisher, the repository, its licence,
/// and what it would download, and anything but an answer of once or trust refuses it. Where the person cannot be
/// asked (no terminal) it is refused before any request, with the flag and the setting named. Every decision is
/// recorded as `model.publisher`; trusting from now on also writes the setting, recorded as `config.change`. The pull's
/// own checks (names, files, sizes, digests, the lock, the link) apply to every publisher alike: this decides only
/// whether to go on. Trusting is the person's alone: the model's request is approved once, never "from now on".
public struct PublisherCheck: Sendable {
    /// What was decided, as `model.publisher` records it.
    public enum Decision: String, Equatable, Sendable {
        /// The publisher is trusted: `mlx-community`, or named in `mlx.trustedPublishers`.
        case trusted
        /// Not trusted, and `--trust-publisher` pulls it this once without the question.
        case flag
        /// The person answered to pull it this once (or approved the model's request); the setting is unchanged.
        case once
        /// The person answered to trust the publisher from now on; it was added to `mlx.trustedPublishers`.
        case trust
        /// Not pulled: the person refused, or did not answer, or could not be asked.
        case refused

        /// Whether the pull goes on.
        public var pulls: Bool { self != .refused }
        /// Whether the person approved the download with this answer, so the pull's own download question is not
        /// asked again.
        public var approvedDownload: Bool { self == .once || self == .trust }
    }

    /// The person's answer to the question.
    public enum Answer: Equatable, Sendable {
        /// Pull this once.
        case once
        /// Trust the publisher from now on, and pull.
        case trust
        /// Do not pull: the default.
        case refuse

        /// The answer a typed line means: `o` or `once`, `t` or `trust`, ignoring case and spaces; anything else,
        /// an empty line, and no line at all (end of input) refuse.
        ///
        /// - Parameter typed: The line, nil at end of input.
        public init(typed: String?) {
            switch (typed ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
            case "o", "once": self = .once
            case "t", "trust": self = .trust
            default: self = .refuse
            }
        }

        /// The question as a face's choice dialog (chat, `wisp-tui`), shown after the question's lines as notes: pull
        /// once, trust from now on, or refuse, the refusal first and current so it is what Enter alone picks.
        ///
        /// - Parameter summary: What the pull would fetch.
        /// - Returns: The choice; `Answer(typed:)` reads its value.
        public static func choice(for summary: PullSummary) -> ChatChoice {
            let publisher = summary.publisher
            return ChatChoice(
                title: "\(publisher) is not a trusted publisher: pull \(summary.repository)?",
                options: [
                    .init(value: "refuse", label: "refuse", detail: "nothing is fetched (the default)"),
                    .init(value: "once", label: "pull it once", detail: "the setting is unchanged"),
                    .init(
                        value: "trust", label: "trust \(publisher) from now on",
                        detail: "added to \(TrustedPublishers.setting), then pulled"),
                ], current: "refuse")
        }
    }

    /// A pull refused without asking: the publisher is not trusted, the flag was not given, and there is no terminal
    /// to ask on.
    public struct Refusal: Error, CustomStringConvertible, Equatable {
        /// The repository.
        public var repository: String
        /// Its publisher.
        public var publisher: String

        /// Creates a refusal.
        ///
        /// - Parameters:
        ///   - repository: The repository.
        ///   - publisher: Its publisher.
        public init(repository: String, publisher: String) {
            self.repository = repository
            self.publisher = publisher
        }

        /// What the person reads: why, and the two ways to allow it.
        public var description: String {
            "\(publisher) is not a trusted publisher, and wisp models pull asks before it fetches from one, so "
                + "\(repository) needs a terminal; pass --trust-publisher to pull it this once without that question, "
                + "or add \(publisher) to \(TrustedPublishers.setting) (wisp config set \(TrustedPublishers.setting) "
                + "'[\"\(TrustedPublishers.builtIn)\",\"\(publisher)\"]') to trust it from now on"
        }
    }

    /// The session the pull runs in: its configuration, home, and audit log.
    public let session: Session
    /// Whether `--trust-publisher` was given.
    public let trustFlag: Bool
    /// Where it is decided, for the audit: `cli`, `chat`, or `tool`.
    public let source: String
    /// The id of the approval that allowed the model's request, for the audit; nil for the person's.
    public let approval: String?
    /// Where decisions are recorded: the asking conversation's log; nil for the session's.
    public let log: AuditLog?

    /// Creates a check.
    ///
    /// - Parameters:
    ///   - session: The pull's session.
    ///   - trustFlag: Whether `--trust-publisher` was given.
    ///   - source: Where it is decided, for the audit.
    ///   - approval: The approval of the model's request, for the audit; nil for the person's.
    ///   - log: Where decisions are recorded; nil for the session's log.
    public init(
        session: Session, trustFlag: Bool, source: String, approval: String? = nil, log: AuditLog? = nil
    ) {
        self.session = session
        self.trustFlag = trustFlag
        self.source = source
        self.approval = approval
        self.log = log
    }

    /// Decides what can be decided before the repository is listed: `trusted` or `flag` when no question is needed,
    /// nil when the person is to be asked once the plan says what the pull would fetch. Nothing is recorded but a
    /// refusal; `settle` records the rest.
    ///
    /// - Parameters:
    ///   - repository: The repository, as the puller accepted it.
    ///   - interactive: Whether there is a person to ask.
    /// - Returns: The decision, or nil to ask.
    /// - Throws: `Refusal`, recorded as `model.publisher` `refused`, when the person would be asked and cannot be.
    public func screen(_ repository: String, interactive: Bool) throws -> Decision? {
        let publisher = String(repository.prefix { $0 != "/" })
        if TrustedPublishers.trusts(publisher, config: session.config) { return .trusted }
        if trustFlag { return .flag }
        guard interactive else {
            let refusal = Refusal(repository: repository, publisher: publisher)
            record(
                repository: repository, publisher: publisher, decision: .refused, asked: false, licence: nil,
                bytes: nil, reason: "no terminal")
            throw refusal
        }
        return nil
    }

    /// Settles the publisher once the plan is made: the decision `screen` made, recorded, or, when it made none, the
    /// question put through `ask` and its answer applied (`answered`).
    ///
    /// - Parameters:
    ///   - summary: What the pull would fetch.
    ///   - screened: What `screen` decided; nil to ask.
    ///   - ask: Shows the question's lines, the last of them the prompt, and returns the line typed, nil at end of
    ///     input.
    /// - Returns: The decision.
    /// - Throws: `ConfigEdit.Failure`, or the file system's error, when the setting cannot be written; nothing is
    ///   fetched then.
    public func settle(_ summary: PullSummary, screened: Decision?, ask: ([String]) -> String?) throws -> Decision {
        if let screened { return settled(summary, screened) }
        return try answered(summary, Answer(typed: ask(Self.question(for: summary))))
    }

    /// Records a decision made without the question.
    ///
    /// - Parameters:
    ///   - summary: What the pull would fetch.
    ///   - decision: What `screen` decided.
    /// - Returns: The decision.
    @discardableResult
    public func settled(_ summary: PullSummary, _ decision: Decision) -> Decision {
        record(summary, decision: decision, asked: false)
        return decision
    }

    /// Applies the person's answer to the question (trust adds the publisher to `mlx.trustedPublishers`) and records
    /// it.
    ///
    /// - Parameters:
    ///   - summary: What the pull would fetch.
    ///   - answer: The answer.
    /// - Returns: The decision.
    /// - Throws: `ConfigEdit.Failure`, or the file system's error, when the setting cannot be written.
    public func answered(_ summary: PullSummary, _ answer: Answer) throws -> Decision {
        let decision: Decision
        switch answer {
        case .once: decision = .once
        case .trust:
            try session.trustPublisher(summary.publisher, source: source, log: log)
            decision = .trust
        case .refuse: decision = .refused
        }
        record(summary, decision: decision, asked: true)
        return decision
    }

    /// The question for a publisher not trusted: who publishes the repository, its licence (`unknown` when the Hub
    /// gives none), what it would download and how many files it has, what pulling it means, and the answers, the
    /// last line being the prompt.
    ///
    /// - Parameter summary: What the pull would fetch.
    /// - Returns: The lines.
    public static func question(for summary: PullSummary) -> [String] {
        [
            "\(summary.publisher) is not a trusted publisher (\(TrustedPublishers.setting)).",
            "  Publisher:   \(summary.publisher)",
            "  Repository:  \(summary.repository)",
            "  Licence:     \(summary.licence ?? "unknown")",
            "  Download:    \(download(summary)), \(PullSummary.size(summary.bytes)) in all",
            "Its weights, tokenizer, and chat template would run in wisp's process on this Mac.",
            "Pull it once [o], trust \(summary.publisher) from now on [t], or refuse [N]? ",
        ]
    }

    /// What a pull would download, as the question and the model's approval name it.
    ///
    /// - Parameter summary: What the pull would fetch.
    /// - Returns: Such as `2.3 GB in 3 of 7 files`.
    public static func download(_ summary: PullSummary) -> String {
        summary.missing == 0
            ? "nothing (every file is already on this Mac)"
            : "\(PullSummary.size(summary.remaining)) in \(summary.missing) of \(summary.files) files"
    }

    /// Records a decision on a plan as `model.publisher`, with the licence and the bytes to download.
    private func record(_ summary: PullSummary, decision: Decision, asked: Bool) {
        record(
            repository: summary.repository, publisher: summary.publisher, decision: decision, asked: asked,
            licence: summary.licence, bytes: summary.remaining, reason: nil)
    }

    /// Records a decision as `model.publisher`.
    private func record(
        repository: String, publisher: String, decision: Decision, asked: Bool, licence: String?, bytes: Int?,
        reason: String?
    ) {
        (log ?? session.audit).record(
            .modelPublisher,
            details: AuditEvent.Details.modelPublisher(
                repository: repository, publisher: publisher, decision: decision.rawValue, asked: asked,
                licence: licence, bytes: bytes, reason: reason, source: source, approval: approval))
    }
}

import Foundation
import FoundationModels

/// Every action on the models wisp can run, for the person and the model alike
/// ([ADR 0059](../../../../docs/decisions/0059-one-set-of-model-actions.md)): `wisp models …`, chat's `/models` and
/// `/model`, `wisp-tui`'s picker, and the model's `models` tool all come here, so each rule is written once: a disabled
/// model refused under any spelling (`DisabledModels`, through `Session.setModels`), the capability check on enable
/// (`Session.checkModels`), and the publisher question before a pull (`PublisherCheck`). Each action declares what it
/// reads and changes and whether the model's request for it asks the person (`Action`). A face names itself, which the
/// audit records as `source`; the model's face is `tool`, whose changes are approval requests of their own kind
/// (`ApprovalGate.clear(modelAction:subject:reasons:workingDirectory:)`).
public struct ModelActions: Sendable {
    /// One action, with what it touches.
    public enum Action: String, CaseIterable, Sendable {
        /// The models this Mac can run, judged for the conversation.
        case list
        /// One model's facts.
        case show
        /// Fetch an MLX model from Hugging Face and link it.
        case pull
        /// Trust a publisher from now on.
        case trust
        /// Turn models on, checking what an undeclared one can do.
        case enable
        /// Turn models off.
        case disable
        /// Check what models can do, again.
        case check
        /// Move the conversation to another model.
        case switchModel = "switch"
        /// Remove a model where wisp knows its files, and its settings (ADR 0075).
        case uninstall

        /// What it reads.
        public var reads: String {
            switch self {
            case .list, .show: "every backend's models, config.json's models and declarations"
            case .pull: "Hugging Face's listing, the Hugging Face cache, the models folder"
            case .trust: "config.json's mlx.trustedPublishers"
            case .enable, .disable: "config.json's models.disabled, the Hugging Face cache"
            case .check: "the model itself, loaded and asked three questions"
            case .switchModel: "the model's backend"
            case .uninstall: "the model's runtime or folder, the Hugging Face cache, config.json"
            }
        }

        /// What it changes; nil for nothing.
        public var changes: String? {
            switch self {
            case .list, .show: nil
            case .pull: "the Hugging Face cache and the models folder's link (gigabytes of disk and network)"
            case .trust: "config.json's mlx.trustedPublishers"
            case .enable, .disable: "config.json's models.disabled, and a link for a cached model"
            case .check: "config.json's mlx.models.<name> declaration"
            case .switchModel: "the conversation's model"
            case .uninstall: "removes the model's files (Ollama's copy, a link, a folder to the Bin) and its settings"
            }
        }

        /// Whether the model's `models` tool offers it: `trust` and `uninstall` are the person's alone, and a model
        /// choosing its own successor (`switch`) is a decision not taken.
        public var forModel: Bool { self != .trust && self != .switchModel && self != .uninstall }

        /// Whether the model's request for it asks the person: every action that changes something.
        public var asksPerson: Bool { forModel && changes != nil }

        /// The widest scope an approval of the model's request is kept for: `once` for a pull, which is asked every
        /// time and never covered by an earlier answer; the session for the other changes; nil for an action that
        /// does not ask. `ApprovalRequest.Kind.modelAction` holds the gate to it.
        public var remembered: ApprovalScope? {
            switch self {
            case .pull: .once
            case .enable, .disable, .check: .session
            case .list, .show, .trust, .switchModel, .uninstall: nil
            }
        }
    }

    /// Who is acting, as the audit's `source` names it.
    public enum Face: String, Sendable {
        /// `wisp models …`.
        case cli
        /// `/models`, `/model`, and `wisp-tui`'s picker.
        case chat
        /// The model's `models` tool.
        case tool
    }

    /// Why an action could not be taken.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The model asked for an action that is the person's alone.
        case notForTheModel(String)
        /// This build fetches no models.
        case noPuller
        /// The listing names no such model.
        case unknownModel(String)
        /// The name is not one Hugging Face accepts for an organisation.
        case notAPublisher(String)
        /// A pull of the repository is running already.
        case alreadyPulling(String)
        /// A pull asks the person before it fetches, and there is no one to ask here.
        case notInteractive

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notForTheModel(let action):
                action == Action.trust.rawValue
                    ? "trusting a publisher is the person's alone: they can run /models trust PUBLISHER, or answer t "
                        + "when a pull asks"
                    : "\(action) is not offered to the model"
            case .noPuller: "this build of wisp cannot fetch models"
            case .unknownModel(let name): "no model \(name) is listed; models list shows the names"
            case .notAPublisher(let name):
                "'\(name)' is not a Hugging Face organisation: 1 to \(TrustedPublishers.maxNameLength) of letters, "
                    + "digits, '.', '_', and '-', starting and ending with a letter, a digit, or '_'"
            case .alreadyPulling(let repository):
                "\(repository) is being pulled already; its end will arrive as a note"
            case .notInteractive: "a pull asks the person before it fetches, so it runs only where they can answer"
            }
        }
    }

    /// The session the actions run in: its configuration, home, audit, and disabled models.
    public let session: Session
    /// Who is acting.
    public let face: Face
    /// Where the actions are recorded: the asking conversation's log (an MCP thread's, so its audit resource shows a
    /// pull it asked for), or the session's.
    public let audit: AuditLog
    /// Lists the models for a conversation with these tools; tests replace it.
    var listing: @Sendable ([any Tool]) async -> ModelListing.Listing
    /// How long each of a check's questions may take.
    var limits: ModelVerification.Limits = .standard
    /// The time a check records; tests fix it.
    var now: @Sendable () -> Date = { Date() }

    /// The actions for `face` in `session`.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - face: Who is acting.
    ///   - audit: The asking conversation's log; nil records in the session's.
    public init(session: Session, face: Face, audit: AuditLog? = nil) {
        self.session = session
        self.face = face
        self.audit = audit ?? session.audit
        listing = { tools in
            await ModelListing.entries(
                config: session.declaredModels.applied(to: session.config), home: session.home, tools: tools,
                disabled: session.disabledModels.all)
        }
    }

    /// What fetches models here: the session's, else the registered one.
    var puller: (any ModelPuller)? { session.puller ?? ModelPullers.current }

    /// The models this Mac can run, judged for a conversation with `tools`, with those this session turned off
    /// marked so (ADR 0056).
    ///
    /// - Parameter tools: The conversation's tools; empty judges a conversation with none.
    /// - Returns: The listing.
    public func list(tools: [any Tool]) async -> ModelListing.Listing {
        await listing(tools)
    }

    /// One model's entry in the listing, matched under any spelling of its name.
    ///
    /// - Parameters:
    ///   - name: The model, as `--model` spells it.
    ///   - tools: The conversation's tools.
    /// - Returns: The entry.
    /// - Throws: `ModelSelection.Failure` for a name that does not parse, `Failure.unknownModel` for one not listed.
    public func show(_ name: String, tools: [any Tool]) async throws -> ModelListing.Entry {
        let selection = try ModelSelection(parsing: name)
        let config = session.config
        let home = session.home
        guard
            let entry = await listing(tools).entries.first(where: {
                $0.selection.names(selection, config: config, home: home)
            })
        else { throw Failure.unknownModel(name) }
        return entry
    }

    /// Turns models on and off (`Session.setModels`), then checks what each model turned on can do when its
    /// capabilities are undeclared (`Session.checkModels`), telling `report` each line as it happens.
    ///
    /// - Parameters:
    ///   - enable: The models to turn on.
    ///   - disable: The models to turn off.
    ///   - approval: The approval of the model's request, for the audit; nil for the person's.
    ///   - report: Told each line: what changed, then the check's progress and result.
    /// - Throws: `ModelSelection.Failure`, `ConfigEdit.Failure`, or a backend's or the file system's error.
    public func set(
        enable: [String], disable: [String], approval: String? = nil,
        report: @escaping @Sendable (String) -> Void
    ) async throws {
        for line in try session.setModels(
            enable: enable, disable: disable, source: face.rawValue, checking: true, approval: approval, log: audit)
        {
            report(line)
        }
        if !enable.isEmpty { try await check(enable, force: false, approval: approval, report: report) }
    }

    /// Checks what models can do and records it (`Session.checkModels`); with `force`, a model already declared too.
    ///
    /// - Parameters:
    ///   - names: The models.
    ///   - force: Whether to check a model already declared, replacing what an earlier check recorded.
    ///   - approval: The approval of the model's request, for the audit; nil for the person's.
    ///   - report: Told each line of progress as it happens, then what was recorded.
    /// - Throws: `ModelSelection.Failure`, `ConfigEdit.Failure`, or the file system's error.
    public func check(
        _ names: [String], force: Bool = true, approval: String? = nil, report: @escaping @Sendable (String) -> Void
    ) async throws {
        let lines = try await session.checkModels(
            names, force: force, source: face.rawValue, approval: approval, log: audit, limits: limits, now: now(),
            progress: report)
        for line in lines { report(line) }
    }

    /// Trusts `publisher` from now on: adds it to `mlx.trustedPublishers` (`Session.trustPublisher`), recorded as
    /// `config.change`. The person's alone.
    ///
    /// - Parameter publisher: The organisation.
    /// - Returns: A line for the person.
    /// - Throws: `Failure.notForTheModel` from the tool, `Failure.notAPublisher` for a name Hugging Face would not
    ///   accept, `ConfigEdit.Failure`, or the file system's error.
    public func trust(_ publisher: String) throws -> String {
        guard face != .tool else { throw Failure.notForTheModel(Action.trust.rawValue) }
        guard TrustedPublishers.isHubName(publisher) else { throw Failure.notAPublisher(publisher) }
        if TrustedPublishers.trusts(publisher, config: session.config) || publisher == TrustedPublishers.builtIn {
            return "\(publisher) is trusted already"
        }
        guard try session.trustPublisher(publisher, source: face.rawValue, log: audit) != nil else {
            return "\(publisher) is trusted already"
        }
        return "\(publisher) is trusted from now on (\(TrustedPublishers.setting)): its pulls ask only about the "
            + "download"
    }

    /// The model a switch moves the conversation to, refused when it is disabled under any spelling; the face opens
    /// it (`Session.openAgent`).
    ///
    /// - Parameter name: The model, as `--model` spells it.
    /// - Returns: The selection.
    /// - Throws: `Failure.notForTheModel` from the tool, `ModelSelection.Failure` for a name that does not parse or a
    ///   model that is disabled.
    public func switchTarget(_ name: String) throws -> ModelSelection {
        guard face != .tool else { throw Failure.notForTheModel(Action.switchModel.rawValue) }
        let selection = try ModelSelection(parsing: name)
        try session.disabledModels.check(selection)
        return selection
    }
}

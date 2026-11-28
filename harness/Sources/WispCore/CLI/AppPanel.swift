import Foundation
import Observation

/// What `Wisp.app`'s window shows and does when it is opened from the Finder
/// ([ADR 0091](../../../../docs/decisions/0091-wisp-app-window.md)): whether wisp is on `PATH` and an offer to link it
/// (ADR 0073); the recent releases, the running one marked, with the newest installable (ADR 0074); and the models wisp
/// can run, with enable, disable, check, uninstall, pull, and add (`ModelActions`, as `wisp models` does them). The
/// window is a view of this; everything it does goes through `Services`, and every question to the person through
/// `Prompts`, so tests drive it without AppKit or the network.
@MainActor @Observable public final class AppPanel {
    /// What the panel does, as the executable wires it: the same calls `wisp install`, `wisp update`, and
    /// `wisp models` make.
    public struct Services {
        /// The install dialog's state for the running `wisp` (`AppInstall.welcome`).
        public var welcome: @MainActor () -> AppInstall.Welcome
        /// Links wisp onto `PATH`, returning the lines to show.
        public var install: @MainActor () throws -> [String]
        /// Asks GitHub for the recent releases, kept and recorded as a check (`AppUpdate.checkListing`).
        public var releases: @MainActor () async -> (releases: [AppUpdate.Published], failure: String?)
        /// The last check's state, when `updates.check` is on and none is due; nil otherwise.
        public var lastCheck: @MainActor () -> AppUpdate.State?
        /// Whether a check is due now: `updates.check` is on and the last one is a day old.
        public var checkIsDue: @MainActor () -> Bool
        /// Replaces the app with a release, returning the headline and text to show.
        public var update: @MainActor (AppUpdate.Release) async -> (title: String, text: String)
        /// The install the running `wisp` came from, which decides what can be updated.
        public var source: AppInstall.Source
        /// The models every backend lists, and the backends that could not be asked, as `wisp models list` has them.
        public var models: @MainActor () async -> ModelListing.Listing
        /// Turns a model on or off, telling each line.
        public var setEnabled: @MainActor (String, Bool, @escaping @Sendable (String) -> Void) async throws -> Void
        /// Checks what a model can do, telling each line.
        public var check: @MainActor (String, @escaping @Sendable (String) -> Void) async throws -> Void
        /// Removes a model, through the dialog; true when it was removed.
        public var uninstall: @MainActor (String, ModelActions.UninstallDialog) async throws -> Bool
        /// Pulls a model from Hugging Face through the dialog.
        public var pull: @MainActor (String, PullDialog) async throws -> PullResult
        /// Links a GGUF file for wisp's llama.cpp server, returning the lines to show.
        public var add: @MainActor (URL) throws -> [String]

        /// Creates the services.
        public init(
            welcome: @escaping @MainActor () -> AppInstall.Welcome, install: @escaping @MainActor () throws -> [String],
            releases: @escaping @MainActor () async -> (releases: [AppUpdate.Published], failure: String?),
            lastCheck: @escaping @MainActor () -> AppUpdate.State?, checkIsDue: @escaping @MainActor () -> Bool,
            update: @escaping @MainActor (AppUpdate.Release) async -> (title: String, text: String),
            source: AppInstall.Source, models: @escaping @MainActor () async -> ModelListing.Listing,
            setEnabled: @escaping @MainActor (String, Bool, @escaping @Sendable (String) -> Void) async throws -> Void,
            check: @escaping @MainActor (String, @escaping @Sendable (String) -> Void) async throws -> Void,
            uninstall: @escaping @MainActor (String, ModelActions.UninstallDialog) async throws -> Bool,
            pull: @escaping @MainActor (String, PullDialog) async throws -> PullResult,
            add: @escaping @MainActor (URL) throws -> [String]
        ) {
            self.welcome = welcome
            self.install = install
            self.releases = releases
            self.lastCheck = lastCheck
            self.checkIsDue = checkIsDue
            self.update = update
            self.source = source
            self.models = models
            self.setEnabled = setEnabled
            self.check = check
            self.uninstall = uninstall
            self.pull = pull
            self.add = add
        }
    }

    /// How the panel asks the person: the window's sheets and panels.
    public struct Prompts {
        /// Asks a yes-or-no question with a headline, text, and the button that says yes; no is the default.
        public var confirm: @MainActor (String, String, String) async -> Bool
        /// Asks the person to type, with a headline and text; nil when they cancel.
        public var typed: @MainActor (String, String) async -> String?
        /// Puts the publisher question's lines; anything but once or trust refuses.
        public var publisher: @MainActor ([String]) async -> PublisherCheck.Answer
        /// Asks for a GGUF file; nil when they cancel.
        public var file: @MainActor () async -> URL?
        /// Tells the person something that needs no answer: a headline and text.
        public var tell: @MainActor (String, String) async -> Void

        /// Creates the prompts.
        public init(
            confirm: @escaping @MainActor (String, String, String) async -> Bool,
            typed: @escaping @MainActor (String, String) async -> String?,
            publisher: @escaping @MainActor ([String]) async -> PublisherCheck.Answer,
            file: @escaping @MainActor () async -> URL?, tell: @escaping @MainActor (String, String) async -> Void
        ) {
            self.confirm = confirm
            self.typed = typed
            self.publisher = publisher
            self.file = file
            self.tell = tell
        }
    }

    /// Where the update section stands.
    public enum UpdateState: Equatable, Sendable {
        /// Not asked yet this time; the text says how to ask, or what the last daily check found.
        case idle(String)
        /// Asking GitHub.
        case checking
        /// The recent releases, what can be done, and the release Update installs, if any.
        case listed([AppUpdate.Published], advice: String, installable: AppUpdate.Release?)
        /// The request failed.
        case failed(String)
        /// Downloading, checking, and replacing the app.
        case updating(String)
    }

    /// One model's row.
    public struct ModelRow: Equatable, Identifiable, Sendable {
        /// The model, as `--model` spells it.
        public var name: String
        /// Its size, format, and window, in a line.
        public var detail: String
        /// Whether it is turned on.
        public var enabled: Bool
        /// Why it cannot be used, or nil.
        public var problem: String?
        /// Whether wisp can remove it: a local runtime's model, not one of Apple's.
        public var removable: Bool

        /// The row's identity: its name.
        public var id: String { name }

        /// The row for a listing's entry.
        ///
        /// - Parameter entry: The entry.
        public init(_ entry: ModelListing.Entry) {
            name = entry.selection.description
            var parts: [String] = []
            if let parameters = entry.parameters { parts.append(parameters) }
            if let format = entry.format { parts.append(format) }
            if let bytes = entry.bytes {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            if parts.isEmpty, !entry.detail.isEmpty { parts.append(entry.detail) }
            if entry.capabilities.contains("toolCalling") { parts.append("Uses tools") }
            detail = parts.joined(separator: " · ")
            enabled = entry.enabled
            problem = entry.problem
            if case .local = entry.selection { removable = true } else { removable = false }
        }
    }

    /// The running version.
    public let version: String
    /// The notes this build shipped with, shown on the Updates tab without a request.
    public let notes: AppUpdate.Notes?
    /// The install section.
    public private(set) var welcome: AppInstall.Welcome
    /// What the last install said, if one ran.
    public private(set) var installNote: String?
    /// The update section.
    public private(set) var update: UpdateState
    /// The models, as last listed.
    public private(set) var models: [ModelRow] = []
    /// One line per backend that could not be asked, so a model missing from the list has a reason beside it.
    public private(set) var unreachable: [String] = []
    /// Whether the models are being listed.
    public private(set) var listing = false
    /// What a model action is doing, while one runs; the model buttons wait for it.
    public private(set) var busy: String?
    /// How far a pull has got, while one runs.
    public private(set) var progress: PullProgress?
    /// What the model actions said, the latest last, at most `logLimit` lines.
    public private(set) var log: [String] = []
    /// How many lines `log` keeps.
    static let logLimit = 200

    /// What the panel does.
    private let services: Services
    /// How it asks.
    private let prompts: Prompts
    /// Stops the running pull.
    private var stop: CommandStop?

    /// A panel over `services`, asking through `prompts`.
    ///
    /// - Parameters:
    ///   - services: What it does.
    ///   - prompts: How it asks.
    ///   - version: The running version.
    ///   - notes: The notes this build shipped with.
    public init(
        services: Services, prompts: Prompts, version: String = WispVersion.current,
        notes: AppUpdate.Notes? = AppUpdate.shipped
    ) {
        self.services = services
        self.prompts = prompts
        self.version = version
        self.notes = notes
        welcome = services.welcome()
        update = .idle(Self.idleText(services.lastCheck(), current: version))
    }

    /// What the update section says before it is asked: what the daily check last found, or that it has not run.
    ///
    /// - Parameters:
    ///   - state: The last check's state, when `updates.check` is on.
    ///   - current: The running version.
    /// - Returns: The text.
    static func idleText(_ state: AppUpdate.State?, current: String) -> String {
        guard let state, state.failure == nil else { return "Not checked yet." }
        let day = state.checkedAt.formatted(.iso8601.year().month().day())
        if let newer = state.newer(than: current) { return "Last checked \(day): Wisp \(newer) is available." }
        return "Last checked \(day): up to date."
    }

    /// A backend that could not be asked, as the window says it: without the scheme the listing puts first, which the
    /// text names again, and starting with a capital, such as `No Ollama server at http://127.0.0.1:11434: …`.
    ///
    /// - Parameter line: The listing's line, `ollama: no Ollama server at …`.
    /// - Returns: The note.
    static func unreachableNote(_ line: String) -> String {
        var text = Substring(line)
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains(" ") {
            text = text[text.index(after: colon)...].drop { $0 == " " }
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// What Update installs: the newest release, when it is newer than `current`, has a disk image, and this install
    /// can replace itself; nil otherwise. Only the newest is installed (ADR 0091, decision 2).
    ///
    /// - Parameters:
    ///   - releases: The releases, newest first.
    ///   - current: The running version.
    ///   - source: The install.
    /// - Returns: The release.
    static func installable(
        _ releases: [AppUpdate.Published], current: String, source: AppInstall.Source
    ) -> AppUpdate.Release? {
        guard let newest = releases.first?.release, newest.image != nil,
            let found = AppUpdate.Version(newest.version), let running = AppUpdate.Version(current), running < found,
            (try? AppUpdate.app(of: source)) != nil
        else { return nil }
        return newest
    }

    // MARK: - Opening

    /// What opening the window starts: the models listed, and, with `updates.check` on and a check due, the releases
    /// asked for, as the Finder dialog did before (ADR 0074, decision 6).
    public func start() async {
        if services.checkIsDue() { await checkForUpdates() }
        await refreshModels()
    }

    // MARK: - Install

    /// Links wisp onto `PATH`, and shows what was done.
    public func install() {
        do {
            installNote = try services.install().joined(separator: "\n")
        } catch {
            installNote = "Wisp could not be installed: \(error)"
        }
        welcome = services.welcome()
    }

    // MARK: - Update

    /// Asks GitHub for the recent releases and shows them, with what can be done.
    public func checkForUpdates() async {
        guard update != .checking, !isUpdating else { return }
        update = .checking
        let result = await services.releases()
        if let failure = result.failure {
            update = .failed("GitHub could not be asked: \(failure).")
            return
        }
        update = .listed(
            result.releases,
            advice: AppUpdate.advice(result.releases, current: version, source: services.source, command: "Update"),
            installable: Self.installable(result.releases, current: version, source: services.source))
    }

    /// Whether an update is running.
    public var isUpdating: Bool {
        if case .updating = update { true } else { false }
    }

    /// Installs the newest release, after the person confirms what it does.
    public func installUpdate() async {
        guard case .listed(let releases, let advice, let release?) = update else { return }
        let yes = await prompts.confirm(
            "Update to Wisp \(release.version)?",
            "This is \(version). Update downloads \(release.imageName) to your Downloads folder, checks that it is "
                + "signed by wisp's developer and notarised by Apple, and replaces this app with the one inside.",
            "Update")
        guard yes else { return }
        update = .updating("Downloading and checking Wisp \(release.version)…")
        let outcome = await services.update(release)
        update = .listed(releases, advice: advice, installable: release)
        await prompts.tell(outcome.title, outcome.text)
    }

    // MARK: - Models

    /// Lists the models again.
    public func refreshModels() async {
        listing = true
        defer { listing = false }
        let listing = await services.models()
        models = listing.shown(all: false).map(ModelRow.init)
        unreachable = listing.unreachable.map(Self.unreachableNote)
    }

    /// Turns a model on or off; turning one on checks what it can do when that is undeclared.
    ///
    /// - Parameter row: The model.
    public func toggle(_ row: ModelRow) async {
        await run(row.enabled ? "Turning \(row.name) off…" : "Turning \(row.name) on…") { say in
            try await self.services.setEnabled(row.name, !row.enabled, say)
        }
    }

    /// Checks what a model can do: it is loaded and asked three questions.
    ///
    /// - Parameter row: The model.
    public func check(_ row: ModelRow) async {
        await run("Checking \(row.name)…") { say in try await self.services.check(row.name, say) }
    }

    /// Removes a model after the person types its name, as `wisp models uninstall` asks (ADR 0075, decision 3).
    ///
    /// - Parameter row: The model.
    public func uninstall(_ row: ModelRow) async {
        await run("Uninstalling \(row.name)…") { say in
            var plan: [String] = []
            let dialog = ModelActions.UninstallDialog(
                interactive: true,
                show: { line in
                    plan.append(line)
                    say(line)
                },
                typed: { prompt in
                    await self.prompts.typed(
                        "Uninstall \(row.name)?", (plan + ["", prompt + "."]).joined(separator: "\n"))
                })
            _ = try await self.services.uninstall(row.name, dialog)
        }
    }

    /// Pulls a model from Hugging Face, after the questions `wisp models pull` asks (ADR 0052).
    ///
    /// - Parameter repository: The repository, as typed.
    public func pull(_ repository: String) async {
        let text = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let stop = CommandStop()
        self.stop = stop
        defer {
            self.stop = nil
            progress = nil
        }
        await run("Pulling \(text)…") { say in
            let dialog = PullDialog(
                interactive: true, show: { say($0) }, notice: say,
                publisher: { summary in await self.prompts.publisher(PublisherCheck.question(for: summary)) },
                confirm: { question in await self.prompts.confirm("Pull \(text)?", question, "Download") },
                progress: { step in Task { @MainActor in self.progress = step } }, stop: stop)
            let result = try await self.services.pull(text, dialog)
            if let closing = result.closing { say(closing) }
        }
    }

    /// Whether a pull is running that `stopPull` can stop.
    public var canStop: Bool { stop != nil }

    /// Stops the running pull; what arrived is kept for the next pull to resume.
    public func stopPull() {
        _ = stop?.request()
    }

    /// Links a GGUF file the person chooses for wisp's llama.cpp server.
    public func add() async {
        guard let file = await prompts.file() else { return }
        await run("Adding \(file.lastPathComponent)…") { say in
            for line in try self.services.add(file) { say(line) }
        }
    }

    /// Runs one model action at a time: says what it is doing, keeps what it says, shows a failure, and lists the
    /// models again afterwards.
    ///
    /// - Parameters:
    ///   - doing: What it is doing, for the person.
    ///   - body: The action, given how to say a line.
    private func run(_ doing: String, _ body: (@escaping @Sendable (String) -> Void) async throws -> Void) async {
        guard busy == nil else { return }
        busy = doing
        append(doing)
        let say: @Sendable (String) -> Void = { line in Task { @MainActor in self.append(line) } }
        do {
            try await body(say)
        } catch {
            await Task { @MainActor in }.value
            append("Error: \(error)")
            await prompts.tell("The Action Couldn’t Be Completed", "\(error)")
        }
        // The lines said from other tasks arrive before this one, which the main actor runs after them.
        await Task { @MainActor in }.value
        busy = nil
        await refreshModels()
    }

    /// Keeps a line of what the model actions said.
    ///
    /// - Parameter line: The line.
    private func append(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}

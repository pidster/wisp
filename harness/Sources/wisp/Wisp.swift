import ArgumentParser
import Foundation
import FoundationModels
import Synchronization
import WispCore
import WispCoreAI
import WispMCP
import WispMLX

@main
/// The `wisp` command: `respond` by default, plus `chat`, `tools`, and `mcp`.
struct Wisp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wisp",
        abstract: "An on-device, tool-using AI microharness over Apple's Foundation Models.",
        version: WispVersion.display,
        subcommands: [
            Respond.self, Chat.self, Tools.self, Models.self, Mcp.self, Logs.self, ConfigCommand.self,
            DoctorCommand.self,
            Approvals.self, FactsCommand.self, Notify.self, Scan.self, Redact.self, Watch.self, Draft.self,
            ClassifierCommand.self, CompletionsCommand.self,
        ],
        defaultSubcommand: Respond.self
    )

    /// Registers the model backends this build carries, then parses and runs.
    static func main() async {
        ModelBackends.register(CoreAIBackend())
        ModelBackends.register(MLXBackend())
        await main(nil)
    }
}

/// The flags every session-starting subcommand shares, declared once.
struct SessionOptions: ParsableArguments {
    @Option(
        name: [.short, .customLong("instructions")],
        help: "Instructions for this conversation, added under wisp's system prompt and config.json's extension.")
    var instructions: String?

    @Option(
        name: .customLong("tool"), help: "Tool to enable (repeatable). All tools are enabled when omitted.",
        completion: DynamicCompletions.tools)
    var toolNames: [String] = []

    @Flag(name: .customLong("no-tools"), help: "Give the model no tools: a text-only conversation any model can run.")
    var noTools = false

    @Flag(help: "Disable the run_command policy and sandbox.")
    var unsafe = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model: system, private-cloud, or <backend>:<name> (see wisp models). Defaults to config.json.",
        completion: DynamicCompletions.models)
    var model: String?

    /// The session request these flags describe.
    ///
    /// - Throws: `ValidationError` for an unknown model name.
    func request(
        entryPoint: EntryPoint, autoApprove: Bool = false, resume: String? = nil, carriedFrom: [String] = []
    ) throws -> Session.Request {
        .init(
            entryPoint: entryPoint, instructions: instructions, model: try model.map(Wisp.parseModel),
            tools: noTools ? .none : ToolSelection(toolNames), unsafe: unsafe, autoApprove: autoApprove,
            resume: resume, carriedFrom: carriedFrom)
    }
}

/// One prompt in, one reply out, in the shape of `fm respond`.
struct Respond: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate a response to a prompt, calling tools as needed.")

    @Argument(help: "Prompt for the model. Read from stdin when omitted and stdin is a pipe.")
    var prompt: String?

    @OptionGroup var options: SessionOptions

    @Flag(inversion: .prefixedNo, help: "Stream the output as it is generated.")
    var stream = true

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking (non-interactive).")
    var yes = false

    @Option(
        name: .customLong("schema"),
        help: "Path to a JSON Schema; the reply is JSON of that shape (not streamed).")
    var schemaPath: String?

    mutating func run() async throws {
        let text = try prompt ?? Self.readStdin()
        let schema = try schemaPath.map { path in
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                return try OutputSchema(json: try JSONDecoder().decode(JSONValue.self, from: data))
            } catch let failure as OutputSchema.Failure {
                throw ValidationError("\(failure)")
            } catch {
                throw ValidationError("cannot read the schema at \(path): \(error.localizedDescription)")
            }
        }
        let session = try Wisp.begin(try options.request(entryPoint: .respond, autoApprove: yes))
        defer { session.end() }
        let agent = try session.openAgent(
            host: session.host(
                approver: DenyingApprover(
                    reason:
                        "approval required; re-run with --yes, use wisp chat to be asked, or lower approval.threshold"),
                face: .terminal))
        if let schema {
            print(try await agent.respond(to: text, schema: schema).text)
        } else if stream {
            try await agent.stream(text) { delta in
                print(delta, terminator: "")
                fflush(stdout)
            }
            print()
        } else {
            print(try await agent.respond(to: text).text)
        }
    }

    /// The whole of piped stdin, trimmed; a usage error if empty. When stdin is a terminal there is
    /// nothing to read and waiting would look like a hang, so the help is shown instead.
    private static func readStdin() throws -> String {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { throw CleanExit.helpRequest(Wisp.self) }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ValidationError("No prompt given and stdin is empty.") }
        return text
    }
}

/// Prints the registered tools, laid out like `--help` on a terminal and as `name<TAB>description` when
/// piped, or the full catalogue as JSON or Markdown.
struct Tools: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the tools available to the model.")

    @Flag(name: .long, help: "Print the full catalogue (schemas, limits, example prompts) as JSON.")
    var json = false

    @Flag(
        name: .long, help: "Print the full catalogue as Markdown, the same text as the MCP resource wisp://tools.md.")
    var markdown = false

    func run() throws {
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        let registry = ToolRegistry(runner: config.runner, disabled: config.disabledTools, custom: config.customTools)
        if json {
            print(registry.descriptionsJSON)
        } else if markdown {
            print(registry.descriptionsMarkdown)
        } else {
            let tools = registry.all.map { (name: $0.name, description: $0.description) }
            for line in ListingLayout.tools(tools, width: TerminalTable.detectWidth()) { print(line) }
        }
    }
}

extension Wisp {
    /// The user's home directory for wisp state, honouring `WISP_HOME`.
    static let home = Home.resolve()

    /// Sets up a session, turning set-up failures into usage errors and printing its notes to stderr.
    static func begin(_ request: Session.Request) throws -> Session {
        let session = try usage { try Session.begin(request, home: home) }
        for note in session.notes {
            FileHandle.standardError.write(Data((note + "\n").utf8))
        }
        return session
    }

    /// The files given, read whole, or standard input when there are none.
    ///
    /// - Throws: A usage error for a file that cannot be read.
    static func inputs(_ paths: [String]) throws -> [(source: Triage.Source?, text: String)] {
        guard !paths.isEmpty else {
            return [(nil, String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))]
        }
        return try paths.map { path in
            do {
                return (.path(path), String(decoding: try Data(contentsOf: URL(filePath: path)), as: UTF8.self))
            } catch {
                throw ValidationError("cannot read \(path): \(error.localizedDescription)")
            }
        }
    }

    /// A judge for a condensing command's model pass: each chunk in a fresh tool-less turn on a
    /// conversation `<prefix>-<id>` of `session`, shaped by the model sweep's schema.
    ///
    /// - Parameters:
    ///   - session: The command's session.
    ///   - prefix: The conversation id's prefix.
    ///   - model: The model for the pass; the session's when nil.
    /// - Returns: The judge.
    /// - Throws: `Session.Failure` if the conversation cannot be set up.
    static func judge(session: Session, prefix: String, model: ModelSelection? = nil) throws -> Triage.Judge {
        let thread = try session.thread(
            id: "\(prefix)-" + ShortID.make(),
            host: session.host(approver: DenyingApprover(reason: "no commands run here"), face: .terminal),
            tools: .none, model: model)
        let schema = try OutputSchema(json: ModelSweep.schemaJSON)
        return { prompt in try await thread.openAgent().respond(to: prompt, schema: schema).text }
    }

    /// A judge for the thorough pass of `wisp scan` and `wisp redact`: on the model named with
    /// `--model`, else the `secrets` task's model, recorded as `model.routed`.
    ///
    /// - Throws: `Session.Failure` if the conversation cannot be set up.
    static func secretsJudge(
        session: Session, prefix: String, explicit: String?, inputBytes: Int
    ) throws
        -> Triage.Judge
    {
        let routed = ModelRouting.forTask(
            "secrets", explicit: try explicit.map(parseModel), models: session.config.taskModels)
        if let routed {
            session.audit.record(
                .modelRouted,
                details: AuditEvent.Details.modelRouted(task: "secrets", inputBytes: inputBytes, decision: routed))
        }
        return try judge(session: session, prefix: prefix, model: routed?.model)
    }

    /// A line for the user on stderr.
    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Handles Ctrl-C: the first calls `finish` so the work in progress can end cleanly, the second exits
    /// at once with status 130. Cancel the returned source to restore the default.
    static func stopOnInterrupt(_ finish: @escaping @Sendable () -> Void) -> any DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let presses = Mutex(0)
        source.setEventHandler {
            let count = presses.withLock { count in
                count += 1
                return count
            }
            if count > 1 { Darwin.exit(130) }
            note("stopping after the current run; Ctrl-C again to stop now")
            finish()
        }
        source.setCancelHandler { signal(SIGINT, SIG_DFL) }
        source.resume()
        return source
    }

    /// Parses a `--model` value into a usage error on failure.
    static func parseModel(_ text: String) throws -> ModelSelection {
        try usage { try ModelSelection(parsing: text) }
    }

    /// Runs `operation`, turning a bad-input failure from the core into a usage error (exit 64) and
    /// letting everything else through.
    static func usage<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let failure as Session.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as ModelSelection.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as TranscriptStore.Failure {
            throw ValidationError("\(failure)")
        }
    }
}

/// Serves MCP over stdio until the client closes the pipe.
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve wisp's tools to an MCP client over stdio.",
        discussion: "Exposes 'respond' (run a task on the model, on a named thread), \(Mcp.toolNames), with "
            + "resources for wisp's tools, config, status, approvals, measurements, and audit, each thread's context, "
            + "output, audit, and facts, and the permanent and session facts (docs/mcp.md). Stdout carries the "
            + "protocol; diagnostics go to stderr.")

    /// Every tool `ToolCatalog` declares but `respond`, named for the help text so it cannot go stale.
    static var toolNames: String {
        ToolCatalog.all.map(\.name).filter { $0 != "respond" }.map { "'\($0)'" }.joined(separator: ", ")
    }

    @OptionGroup var options: SessionOptions

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking the client's user.")
    var yes = false

    func run() async throws {
        let session = try Wisp.begin(try options.request(entryPoint: .mcp, autoApprove: yes))
        defer { session.end() }
        try await WispServer(session: session).run()
    }
}

/// A line-oriented REPL: messages go to the model, `/` lines are commands.
struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive chat session.",
        discussion: "Type /help for commands. Transcripts save to ~/.wisp/transcripts and resume with --resume.")

    @OptionGroup var options: SessionOptions

    @Flag(name: [.short, .customLong("yes")], help: "Approve risky commands without asking.")
    var yes = false

    @Option(name: [.short, .long], help: "Resume a saved transcript by name.")
    var resume: String?

    @Option(name: .long, help: "Save the transcript under this name on exit. Defaults to the resumed name.")
    var save: String?

    @Flag(name: .long, help: "List saved transcripts (for --resume) and exit.")
    var list = false

    @Flag(name: .long, help: "Headless: JSON Lines on stdin and stdout, for a front end such as wisp-tui.")
    var json = false

    @Flag(name: .long, help: "The plain line-based chat, even when wisp-tui is installed beside wisp.")
    var plain = false

    /// The front end to hand a terminal session to: `wisp-tui` where `FrontEnd` finds it, when the session is
    /// interactive and not already headless or asked to stay plain.
    static func frontEnd(
        besides executable: URL, json: Bool, plain: Bool, interactive: Bool,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        guard !json, !plain, interactive else { return nil }
        return FrontEnd.locate(besides: executable, exists: exists)
    }

    /// Replaces this process with `wisp-tui`, which spawns `wisp chat --json` on this same binary.
    /// Returns only if the exec failed.
    private static func handOff(to frontEnd: URL, executable: URL) {
        let passthrough = Array(CommandLine.arguments.dropFirst(2))  // after `wisp chat`
        setenv("WISP_BIN", executable.path, 1)
        let argv: [UnsafeMutablePointer<CChar>?] = ([frontEnd.path] + passthrough).map { strdup($0) } + [nil]
        execv(frontEnd.path, argv)
        for pointer in argv { free(pointer) }
    }

    mutating func run() async throws {
        let store = TranscriptStore(directory: Wisp.home.transcripts)
        if list {
            for name in try store.list() { print(name) }
            return
        }
        let executable = FrontEnd.runningExecutable
        let interactive =
            isatty(FileHandle.standardInput.fileDescriptor) != 0
            && isatty(FileHandle.standardOutput.fileDescriptor) != 0
        if let frontEnd = Self.frontEnd(besides: executable, json: json, plain: plain, interactive: interactive) {
            Self.handOff(to: frontEnd, executable: executable)
            Self.note("could not start \(frontEnd.path); continuing with the plain chat")
        }
        // Read before the session starts, so `session.start` can name the sessions the transcript links to.
        let saved = try resume.map { name in try Wisp.usage { try store.loadThread(name) } }
        let session = try Wisp.begin(
            try options.request(
                entryPoint: .chat, autoApprove: yes, resume: resume, carriedFrom: saved?.links.sessions ?? []))
        defer { session.end() }
        try Wisp.home.ensure()
        if json {
            try await runJSON(session: session, store: store, saved: saved)
            return
        }
        let style = Style.detect(isTerminal: isatty(FileHandle.standardOutput.fileDescriptor) != 0)
        let tap = ChatEvents.Tap()
        let host = session.host(approver: TerminalApprover(style: style), face: .terminal)
        // The configured model falls back to system when it is unavailable, so the person reaches /model (ADR 0056).
        let (agent, fallback) = try session.openChatAgent(
            host: host, transcript: saved?.transcript, links: saved?.links, observer: tap)
        if let resume, saved != nil { Self.note("resumed '\(resume)' (\(agent.transcript.turnCount) turns)") }
        let directory = FileManager.default.currentDirectoryPath
        let views = session.introspection
        let activity = ChatActivity()
        let banner =
            "wisp \(WispVersion.display) · \(agent.model.selection) · \(agent.tools.count) tools · "
            + "audit \(ChatStatus.abbreviated(Wisp.home.auditFile.path)) session \(session.audit.session)"
        var loop = ChatLoop(
            agent: agent, store: store, saveName: save ?? resume, tap: tap,
            context: .init(
                directory: directory,
                approval: ChatStatus.approvalMode(threshold: session.config.approvalThreshold, autoApprove: yes),
                git: GitState.read(in:),
                inspect: { what in await InspectTool(introspection: views).show(what) },
                banner: banner,
                models: Chat.models(session: session), setModels: Chat.setModels(session: session),
                checkModels: Chat.checkModels(session: session),
                width: { TerminalTable.detectWidth() }, notices: fallback.map { [$0.message] } ?? [],
                openModel: { selection, store in
                    try session.openAgent(host: host, store: store, observer: tap, model: selection)
                }, stats: session.stats, configFile: Wisp.home.configFile,
                configOptions: Chat.configOptions(session: session), approvalStore: session.store,
                activity: activity, shownOutputLines: session.config.shownOutputLines),
            style: style,
            io: .init(
                readLine: { readLine() },
                print: { text in
                    Self.onScreen {
                        Self.midLine.withLock { $0 = false }
                        print(text)
                    }
                },
                write: { text in
                    Self.onScreen {
                        Self.midLine.withLock { $0 = !text.hasSuffix("\n") }
                        print(text, terminator: "")
                        fflush(stdout)
                    }
                },
                note: Self.note,
                prompt: { status in
                    Self.onScreen {
                        Self.freshLine()
                        let text =
                            status.rendered(style: style, width: Self.terminalWidth()) + "\n"
                            + style.prompt("›") + " "
                        FileHandle.standardError.write(Data(text.utf8))
                    }
                },
                turn: { mark in
                    if let footer = mark.footer(style: style) { Self.note(footer) }
                },
                command: { line in
                    // The typed line was echoed by the terminal; its marker turns the command colour.
                    guard isatty(FileHandle.standardInput.fileDescriptor) != 0,
                        let marker = ChatLoop.commandMarker(for: line, width: Self.terminalWidth(), style: style)
                    else { return }
                    Self.onScreen { FileHandle.standardError.write(Data(marker.utf8)) }
                }))
        let ticker =
            isatty(FileHandle.standardError.fileDescriptor) != 0 ? Self.showWorking(activity, style: style) : nil
        defer { ticker?.cancel() }
        try await loop.run()
    }

    /// The terminal's width in columns, or nil when stderr is not a terminal.
    private static func terminalWidth() -> Int? {
        var size = winsize()
        guard ioctl(FileHandle.standardError.fileDescriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else {
            return nil
        }
        return Int(size.ws_col)
    }

    /// Whether the working line is on screen now, guarded with every terminal write so they never interleave.
    private static let working = Mutex(false)

    /// Runs `write` with the working line erased first, so output always starts on a clean line.
    private static func onScreen(_ write: () -> Void) {
        working.withLock { drawn in
            if drawn {
                FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
                drawn = false
            }
            write()
        }
    }

    /// Redraws the working line (`… 12 s · running git status (8 s)`) each second while a turn runs,
    /// when the cursor is at the start of a line and no one is being asked. When the activity turns to
    /// an approval or the turn ends, the line is erased at once, before the dialog or the footer.
    private static func showWorking(_ activity: ChatActivity, style: Style) -> Task<Void, Never> {
        activity.onChange { state in
            if state == nil || state?.asking == true { onScreen {} }
        }
        return Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                working.withLock { drawn in
                    guard let state = activity.current, !state.asking, !midLine.withLock({ $0 }) else { return }
                    let line = style.muted("… " + ChatActivity.line(state))
                    FileHandle.standardError.write(Data(("\r\u{1B}[2K" + line).utf8))
                    drawn = true
                }
            }
        }
    }

    /// The headless face: JSON Lines in and out, for `wisp-tui` and other front ends (`docs/wisp.md`).
    private func runJSON(session: Session, store: TranscriptStore, saved: TranscriptStore.Saved?) async throws {
        let router = LineRouter()
        let out = Mutex(FileHandle.standardOutput)
        let send: @Sendable (String) -> Void = { line in
            out.withLock { $0.write(Data((line + "\n").utf8)) }
        }
        // Completion answers beside the loop, which may be waiting for input; the slow options (the
        // models, which ask each backend) are fetched once per session.
        let options = CompletionOptions(fetch: Chat.configOptions(session: session))
        router.onComplete { id, text, cursor in
            Task {
                let known = await options.all()
                let ids = await session.store.all.map(\.id)
                // The log is read only when an /audit argument is being completed.
                let sessions =
                    text.hasPrefix("/audit ") ? (try? session.introspection.sessions().map(\.id)) ?? [] : []
                // The models were fetched once; those turned off since are left out now (ADR 0056).
                let disabled = session.disabledModels.all.map(\.description)
                let result = ChatCompletion.complete(
                    text, cursor: cursor, options: { (known[$0.path] ?? []).filter { !disabled.contains($0) } },
                    approvalIDs: ids, sessionIDs: sessions, subjects: session.config.subjectKinds.kinds.map(\.name),
                    disabledModels: disabled)
                send(ChatProtocol.encode("completions", ChatProtocol.completions(id: id, result)))
            }
        }
        let audit = session.audit
        router.onHello { audit.record(.hostHello, details: AuditEvent.Details.hostHello($0)) }
        let reader = Thread {
            while let line = readLine() { router.receive(line) }
            router.close()
        }
        reader.start()
        // A front end that declares approve-mcp is shown the commands waiting in wisp mcp servers (ADR 0046),
        // and one that declares keep-facts the facts their callers asked to keep (ADR 0048).
        let relay = Task {
            while router.hello == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            let kinds = PendingRelay.kinds(declared: router.declares)
            guard !kinds.isEmpty else { return }
            await PendingRelay(
                channel: PendingApprovals(home: Wisp.home), router: router, audit: audit, kinds: kinds, send: send
            )
            .run()
        }
        defer { relay.cancel() }
        let tap = ChatEvents.Tap()
        // The front end posts notifications itself when its hello declared notify (ADR 0044); wisp never
        // writes to the terminal it owns.
        let host = session.host(
            approver: JSONApprover(router: router, timeout: session.config.approvalTimeout, send: send),
            face: .frontEnd(
                .init(
                    declared: { router.declares("notify") },
                    send: { send(ChatProtocol.encode("notify", ChatProtocol.notify($0))) })))
        let (agent, fallback) = try session.openChatAgent(
            host: host, transcript: saved?.transcript, links: saved?.links, observer: tap)
        let views = session.introspection
        let activity = ChatActivity()
        activity.onChange { send(ChatProtocol.encode("activity", ChatProtocol.activity($0))) }
        var loop = ChatLoop(
            agent: agent, store: store, saveName: save ?? resume, tap: tap,
            context: .init(
                directory: FileManager.default.currentDirectoryPath,
                approval: ChatStatus.approvalMode(threshold: session.config.approvalThreshold, autoApprove: yes),
                git: GitState.read(in:),
                inspect: { what in await InspectTool(introspection: views).show(what) },
                banner: "wisp \(WispVersion.display) · \(agent.model.selection) · \(agent.tools.count) tools",
                models: Chat.models(session: session), setModels: Chat.setModels(session: session),
                checkModels: Chat.checkModels(session: session),
                notices: fallback.map { [$0.message] } ?? [],
                openModel: { selection, store in
                    try session.openAgent(host: host, store: store, observer: tap, model: selection)
                }, stats: session.stats, configFile: Wisp.home.configFile,
                configOptions: Chat.configOptions(session: session), approvalStore: session.store,
                activity: activity, shownOutputLines: session.config.shownOutputLines),
            io: .init(
                readLine: { router.nextMessage() },
                print: { send(ChatProtocol.encode("output", ["text": .string($0)])) },
                write: { send(ChatProtocol.encode("delta", ["text": .string($0)])) },
                note: { send(ChatProtocol.encode("note", ["text": .string($0)])) },
                prompt: { send(ChatProtocol.encode("status", ChatProtocol.status($0))) },
                turn: { send(ChatProtocol.encode("turn", ChatProtocol.turn($0))) },
                choose: { choice in
                    await ChatProtocol.ask(choice, router: router, timeout: session.config.approvalTimeout, send: send)
                }, view: { send(ChatProtocol.encode("view", ChatProtocol.view($0))) }))
        // Events for the front end, raw and with the terminal's line, instead of the notes the loop would write.
        let shownLines = session.config.shownOutputLines
        tap.onEvent { event in
            activity.apply(event)
            send(ChatProtocol.encode("event", ChatProtocol.event(event, shownLines: shownLines)))
        }
        try await loop.run()
        send(ChatProtocol.encode("exit"))
    }

    /// The answers `/config set` offers beyond a setting's own: the models this Mac can run, and the Core
    /// ML models under `~/.wisp/models/coreml`.
    static func configOptions(session: Session) -> @Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option] {
        let config = session.config
        let disabled = session.disabledModels
        let declared = session.declaredModels
        return { setting in
            switch setting.kind {
            case .model, .models:
                // A disabled model is not offered (ADR 0056); a cached one not linked cannot be chosen until enabled.
                return await ModelListing.entries(
                    config: declared.applied(to: config), home: Wisp.home, tools: [], disabled: disabled.all
                )
                .entries.filter(\.offered)
                .map { ChatChoice.Option(value: $0.selection.description, detail: $0.detail) }
            case .coremlModel:
                let store = ClassifierStore(home: Wisp.home)
                _ = try? store.installDefault()
                let versions = store.versions().map { manifest in
                    ChatChoice.Option(
                        value: ClassifierStore.reference(manifest.version),
                        detail: "\(manifest.examples) examples, \(manifest.examplesSource)")
                }
                let dir = Wisp.home.models.appending(path: "coreml")
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                return versions
                    + names.filter { $0.hasSuffix(".mlmodel") || $0.hasSuffix(".mlmodelc") }.sorted()
                    .map { ChatChoice.Option(value: $0, detail: "a file in ~/.wisp/models/coreml") }
            default:
                return []
            }
        }
    }

    /// What `/models` lists: every model judged for the conversation's tools, with the session's disabled models
    /// as this chat has left them.
    static func models(session: Session) -> @Sendable ([any Tool]) async -> ModelListing.Listing {
        let config = session.config
        let disabled = session.disabledModels
        let declared = session.declaredModels
        return { tools in
            await ModelListing.entries(
                config: declared.applied(to: config), home: Wisp.home, tools: tools, disabled: disabled.all)
        }
    }

    /// How chat checks what models can do after enabling them, and for `/models check`: through the session,
    /// audited as from chat, each line of progress a note as it happens (ADR 0056, refined 2026-10-04).
    static func checkModels(
        session: Session
    ) -> @Sendable ([String], Bool, @escaping @Sendable (String) -> Void) async throws -> [String] {
        { names, force, progress in
            try await session.checkModels(names, force: force, source: "chat", progress: progress)
        }
    }

    /// How `/models enable|disable` and `wisp-tui`'s picker turn models on and off: through the session, audited as
    /// from chat.
    static func setModels(session: Session) -> @Sendable ([String], [String]) throws -> [String] {
        { enable, disable in
            try session.setModels(enable: enable, disable: disable, source: "chat", checking: true)
        }
    }

    /// Whether the last stdout write left the cursor mid-line, so a note can start on a fresh one.
    private static let midLine = Mutex(false)

    /// Ends a streamed line before anything else is written.
    private static func freshLine() {
        fflush(stdout)
        if Self.midLine.withLock({
            let was = $0; $0 = false; return was
        }) {
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    /// Writes a status line to stderr so stdout stays clean for replies.
    private static func note(_ text: String) {
        onScreen {
            Self.freshLine()
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }
        Diagnostics.chat.info(Style.stripped(text))
    }
}

/// Reads the audit log back, filtered, as summaries or raw JSON Lines.
struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the audit log.",
        discussion: "Reads ~/.wisp/logs/audit.jsonl (and rotated files). Filters combine with AND.")

    @Option(name: .long, help: "Only this session id.")
    var session: String?

    @Option(name: .long, help: "Only these event kinds (repeatable), e.g. tool.call, policy.decision.")
    var kind: [String] = []

    @Option(name: .long, help: "Only tool events for this tool name.")
    var tool: String?

    @Option(name: .shortAndLong, help: "Only the last N matching events.")
    var last: Int?

    @Flag(name: .long, help: "Print raw JSON Lines instead of one-line summaries.")
    var json = false

    @Flag(
        name: [.short, .long],
        help: ArgumentHelp(
            "Keep printing matching events as they are written, MCP calls included, until Ctrl-C. Starts with the "
                + "last 10 unless --last says otherwise."))
    var follow = false

    func run() throws {
        var kinds: [AuditEvent.Kind] = []
        for raw in kind {
            guard let parsed = AuditEvent.Kind(rawValue: raw) else {
                throw ValidationError(
                    "Unknown kind '\(raw)'. Kinds: \(AuditEvent.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            kinds.append(parsed)
        }
        let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
        let query = AuditQuery(session: session, kinds: kinds, tool: tool, last: last ?? (follow ? 10 : nil))
        var tail = AuditTail.atEnd(of: Wisp.home.auditFile)
        for event in try Introspection(home: Wisp.home, config: config).audit(query) { try show(event) }
        guard follow else { return }
        let matching = AuditQuery(session: session, kinds: kinds, tool: tool)
        while true {
            for event in matching.filter(try tail.read()) { try show(event) }
            fflush(stdout)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Prints one event, as JSON or its summary.
    private func show(_ event: AuditEvent) throws {
        if json {
            print(String(decoding: try AuditEvent.encoder.encode(event), as: UTF8.self))
        } else {
            print(event.summary)
        }
    }
}

/// Prints the effective configuration: every default applied, and where the file is.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Show or change the configuration.",
        discussion:
            "config.json lives in ~/.wisp. 'set' and 'unset' change the settings 'list' shows, checking that the "
            + "file still loads; the rest of the file is kept as it is. Changes apply from the next session.",
        subcommands: [Show.self, List.self, Get.self, SetValue.self, Unset.self], defaultSubcommand: Show.self)

    /// Prints one setting's effective value.
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print one setting's value, and whether it is set or the default.")

        @Argument(help: "The setting, as 'wisp config list' names it.", completion: DynamicCompletions.settings)
        var path: String

        func run() throws {
            guard ConfigSettings.setting(path) != nil else {
                throw ValidationError("\(ConfigEdit.Failure.unknownSetting(path))")
            }
            let data = try? Data(contentsOf: Wisp.home.configFile)
            if let set = (try? ConfigEdit.current(path, in: data)) ?? nil {
                print("\(ChatLoop.shown(set))\tset in config.json")
            } else {
                print("\(ConfigSettings.defaultValue(path).map(ChatLoop.shown) ?? "")\tthe default")
            }
        }
    }

    /// Prints the effective configuration.
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the effective configuration as JSON.",
            discussion: "Defaults applied; the same view the model's inspect tool and the wisp://config resource give.")

        func run() throws {
            let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
            print(Introspection.render(Introspection(home: Wisp.home, config: config).configuration))
        }
    }

    /// Lists the settings that can be changed.
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the settings 'set' can change.")

        func run() throws {
            let data = try? Data(contentsOf: Wisp.home.configFile)
            for setting in ConfigSettings.listed(in: data) {
                let current: JSONValue? = (try? ConfigEdit.current(setting.path, in: data)) ?? nil
                print("\(setting.path)\t\(current.map(ChatLoop.shown) ?? "(default)")\t\(setting.summary)")
            }
        }
    }

    /// Sets one setting.
    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Set a setting, such as: approval.classifier coreml")

        @Argument(help: "The setting, as 'wisp config list' names it.", completion: DynamicCompletions.settings)
        var path: String

        @Argument(parsing: .remaining, help: "The value; a list may be JSON or words separated by spaces.")
        var value: [String]

        func run() throws {
            try ConfigCommand.apply(path) { try ConfigEdit.set(path, to: value.joined(separator: " "), in: $0) }
        }
    }

    /// Removes one setting so its default applies.
    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a setting so its default applies.")

        @Argument(help: "The setting, as 'wisp config list' names it.", completion: DynamicCompletions.settings)
        var path: String

        func run() throws {
            try ConfigCommand.apply(path) { try ConfigEdit.unset(path, in: $0) }
        }
    }

    /// Edits the file, audits the change, and says what changed.
    ///
    /// - Throws: A usage error when the edit is refused; `ExitCode.failure` when the file exists but cannot be
    ///   read, and nothing is written.
    static func apply(_ path: String, _ edit: (Data?) throws -> ConfigEdit.Outcome) throws {
        let url = Wisp.home.configFile
        let outcome: ConfigEdit.Outcome
        do {
            outcome = try edit(try ConfigEdit.existing(at: url))
            try ConfigEdit.write(outcome, to: url)
        } catch let failure as ConfigEdit.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as ConfigEdit.Unreadable {
            // Not a usage mistake: the file is there and cannot be read, so nothing is written.
            Wisp.note("Error: \(failure)")
            throw ExitCode.failure
        }
        let session = try Wisp.begin(.init(entryPoint: .config))
        session.audit.record(.configChange, details: AuditEvent.Details.configChange(outcome, source: "cli"))
        session.end()
        let old = outcome.old.map(ChatLoop.shown) ?? "(default)"
        let new = outcome.new.map(ChatLoop.shown) ?? "(default)"
        print("\(path): \(old) → \(new); used from the next session on")
        if let warning = outcome.warning { FileHandle.standardError.write(Data("note: \(warning)\n".utf8)) }
    }
}

/// The models a session can run on: listing them, turning them on and off, and fetching an MLX one with the
/// person's approval.
struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, enable, or disable the models usable with --model and config.json, or fetch an MLX model.",
        subcommands: [List.self, Enable.self, Disable.self, Check.self, Pull.self], defaultSubcommand: List.self)

    /// Lists the models a session can run on: Apple's two, whatever each local backend serves, and the cached MLX
    /// models enabling would link, with every fact wisp knows about each (ADR 0056).
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the models usable with --model and config.json.",
            discussion:
                "A model is listed when it resolves and declares tool calling (or, with --no-tools, when it can "
                + "hold a conversation at all), and so is every disabled model and every complete mlx-community "
                + "model in the Hugging Face cache that enabling would link. --all adds the rest with the reason "
                + "each is excluded.")

        @Flag(name: .long, help: "Also list the models that cannot be used, with the reason.")
        var all = false

        @Flag(name: .customLong("no-tools"), help: "List the models usable for a conversation with no tools.")
        var noTools = false

        @Flag(name: .long, help: "Print the listing as JSON, a field per column.")
        var json = false

        func run() async throws {
            let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
            let tools: [any Tool] =
                noTools
                ? []
                : ToolRegistry(runner: config.runner, disabled: config.disabledTools, custom: config.customTools).all
            if json {
                let listing = await ModelListing.entries(config: config, home: Wisp.home, tools: tools)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let document = ModelTable.json(listing, current: config.model, all: all)
                print(String(decoding: try encoder.encode(document), as: UTF8.self))
                return
            }
            let lines = await ModelListing.lines(
                config: config, home: Wisp.home, current: config.model, tools: tools, all: all,
                width: TerminalTable.detectWidth())
            for line in lines { print(line) }
        }
    }

    /// Turns models on: a disabled model is offered and accepted again, a cached MLX model is linked, fetching
    /// nothing (ADR 0056), and an MLX model whose capabilities `config.json` does not declare is checked and what
    /// passes recorded (refined 2026-10-04).
    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enable models: offered by /model again; a cached MLX model is linked, with no download.",
            discussion:
                "An MLX model whose capabilities config.json does not declare is then checked: wisp loads it and "
                + "asks three short questions (a reply, a tool call, a structured reply), each once and within a "
                + "time limit, and records the capabilities that pass in config.json. 'wisp models check' checks "
                + "again.")

        @Argument(help: "The models, as --model names them.", completion: DynamicCompletions.disabledModels)
        var names: [String]

        func run() async throws {
            try await Models.set(enable: names, disable: [])
        }
    }

    /// Checks what models can do and records it, replacing what an earlier check recorded and keeping, with a
    /// note, a capability declared by hand whose check fails (ADR 0056, refined 2026-10-04).
    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Check what MLX and llama.cpp models can do, on the models themselves, and record it in config.json.",
            discussion:
                "Loads each model and asks three short questions, each once, greedily, within a time limit (3 min "
                + "for the first, which loads the weights; 1 min for the others): a plain reply (if it fails, "
                + "nothing is recorded), a call of one trivial tool with a given word (toolCalling), and a small "
                + "schema reply (guidedGeneration). The capabilities that pass are recorded under "
                + "mlx.models.<name> with the day of the check; one an earlier check recorded and this one fails "
                + "is taken out, and one declared by hand that fails is kept and reported. reasoning and vision "
                + "are not checked. Ollama and Core AI models report their own capabilities.")

        @Argument(help: "The models, as --model names them.")
        var names: [String]

        func run() async throws {
            let session = try Wisp.begin(.init(entryPoint: .models))
            defer { session.end() }
            try await Models.check(names, force: true, session: session)
        }
    }

    /// Turns models off: hidden from `/model` and Tab, and refused by `/model`, `--model`, `config.json`'s `model`,
    /// and an MCP caller's `model` (ADR 0056).
    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Disable models: hidden from /model and refused everywhere; not the default model.")

        @Argument(help: "The models, as --model names them.")
        var names: [String]

        func run() async throws {
            try await Models.set(enable: [], disable: names)
        }
    }

    /// Changes `models.disabled` through a session of entry point `models`, which records it, and prints what
    /// happened.
    ///
    /// - Throws: `ValidationError` for a name that does not parse, the default being disabled, or a file that would
    ///   not load.
    static func set(enable: [String], disable: [String]) async throws {
        let session = try Wisp.begin(.init(entryPoint: .models))
        defer { session.end() }
        do {
            for line in try session.setModels(enable: enable, disable: disable, source: "cli", checking: true) {
                print(line)
            }
        } catch let failure as ConfigEdit.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as ModelSelection.Failure {
            throw ValidationError("\(failure)")
        }
        if !enable.isEmpty { try await check(enable, force: false, session: session) }
    }

    /// Checks what models can do through `session`, printing each line of progress as it happens and what was
    /// recorded.
    ///
    /// - Throws: `ValidationError` for a name that does not parse or a file that would not load.
    static func check(_ names: [String], force: Bool, session: Session) async throws {
        do {
            let lines = try await session.checkModels(names, force: force, source: "cli") { line in
                print(line)
                fflush(stdout)
            }
            for line in lines { print(line) }
        } catch let failure as ConfigEdit.Failure {
            throw ValidationError("\(failure)")
        } catch let failure as ModelSelection.Failure {
            throw ValidationError("\(failure)")
        }
    }

    /// Fetches an `mlx-community` model from Hugging Face into the Hugging Face cache and links the MLX models
    /// directory to its snapshot, after saying what it will fetch and asking (ADR 0052, refined 2026-10-04). Files
    /// already in the cache are reused, and a complete snapshot is only linked, without a download question.
    /// Only from a terminal: the questions are the person's to answer.
    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Fetch an mlx-community model into the Hugging Face cache and link it, after asking.",
            discussion:
                "Lists the repository, checks which files the Hugging Face cache already holds (HF_HUB_CACHE, "
                + "$HF_HOME/hub, or ~/.cache/huggingface/hub), says how many files and bytes it would fetch, and "
                + "asks before fetching. Only the configuration, weights, and tokenizer files are fetched; each is "
                + "checked against the listing's size and, for weights, its SHA-256. The models directory's "
                + "<name> then links to the cache's snapshot; a directory already there is replaced only if you "
                + "agree. Runs only from a terminal.")

        @Argument(help: "The repository, such as mlx-community/Qwen3-1.7B-4bit (mlx: before it is accepted).")
        var repository: String

        func run() async throws {
            guard isatty(STDIN_FILENO) != 0 else {
                throw ValidationError(
                    "wisp models pull asks the person before it fetches, so it runs only from a terminal")
            }
            let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
            let directory = MLXBackend.modelsDirectory(config: config, home: Wisp.home)
            let pull = ModelPull()
            let plan: ModelPull.Plan
            do {
                plan = try await pull.plan(repository, into: directory) { file in
                    Self.note("checking \(file.path) (\(Self.size(file.size))) against the listing's SHA-256")
                }
            } catch let failure as ModelPull.Failure {
                throw ValidationError("\(failure)")
            }
            print(Self.summary(of: plan))
            var started = ContinuousClock.now
            if !plan.missing.isEmpty {
                print("Fetch \(plan.missing.count) of them, \(Self.size(plan.remaining))? [y/N] ", terminator: "")
                started = ContinuousClock.now
                guard Self.answeredYes() else {
                    record(plan, fetched: 0, outcome: "declined", link: nil, reason: nil, started: started)
                    print("Nothing fetched.")
                    return
                }
            }
            let fetched: Int
            let linked: ModelPull.LinkOutcome
            do {
                fetched = try await pull.fetch(
                    plan,
                    progress: { file, index in
                        Self.note("[\(index)/\(plan.missing.count)] \(file.path) (\(Self.size(file.size)))")
                    }, notice: { Self.note($0) })
                var replace = false
                if plan.link == .directory {
                    print(
                        "\(plan.destination.path) is a directory of its own, not a link to the cache. Move it to the "
                            + "Trash and link \(plan.snapshot.path) in its place? [y/N] ", terminator: "")
                    replace = Self.answeredYes()
                }
                linked = try pull.link(plan, replacingDirectory: replace)
            } catch {
                record(plan, fetched: 0, outcome: "failed", link: nil, reason: "\(error)", started: started)
                throw ValidationError("\(error)")
            }
            record(
                plan, fetched: fetched, outcome: plan.missing.isEmpty ? "linked" : "fetched", link: linked,
                reason: nil, started: started)
            print(Self.closing(plan, linked))
        }

        /// Bytes for people.
        static func size(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }

        /// A progress line, on stderr.
        static func note(_ text: String) {
            FileHandle.standardError.write(Data("\(text)\n".utf8))
        }

        /// Reads a line and says whether it was yes.
        static func answeredYes() -> Bool {
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return answer == "y" || answer == "yes"
        }

        /// What the pull would do, for the question: each file and whether the cache has it, where the snapshot
        /// is, and what happens at the link's path.
        static func summary(of plan: ModelPull.Plan) -> String {
            func padded(_ text: String, _ width: Int) -> String {
                text.padding(toLength: width, withPad: " ", startingAt: 0)
            }
            let width = plan.files.map(\.path.count).max() ?? 0
            let sizeWidth = plan.files.map { size($0.size).count }.max() ?? 0
            var lines = [
                "\(plan.repository) at \(plan.revision.prefix(12)): \(plan.files.count) files, \(size(plan.bytes))"
            ]
            for file in plan.files {
                let state =
                    plan.reused.contains(file.path)
                    ? "already in the Hugging Face cache"
                    : plan.seeded.contains(file.path)
                        ? "to copy from \(plan.destination.lastPathComponent)/" : "to fetch"
                lines.append("  \(padded(file.path, width))  \(padded(size(file.size), sizeWidth))  \(state)")
            }
            lines.append("Snapshot: \(plan.snapshot.path)")
            let destination = plan.destination.path
            switch plan.link {
            case .absent: lines.append("Link: \(destination) to the snapshot, as mlx:\(plan.name)")
            case .current: lines.append("Link: \(destination) already points at the snapshot")
            case .stale(let target):
                lines.append("Link: \(destination) points at another snapshot (\(target)); it will point at this one")
            case .directory:
                lines.append(
                    "Link: \(destination) is a directory of its own (an earlier copy); it stays unless you agree to "
                        + "replace it")
            }
            if plan.missing.isEmpty {
                lines.append(
                    plan.seeded.isEmpty
                        ? "Every file is already in the Hugging Face cache; nothing to fetch."
                        : "Every file is in the Hugging Face cache or \(plan.destination.path); nothing to fetch.")
            }
            return lines.joined(separator: "\n")
        }

        /// What the person reads at the end.
        static func closing(_ plan: ModelPull.Plan, _ linked: ModelPull.LinkOutcome) -> String {
            let declare =
                "declare what it can do in config.json (mlx.models.\(plan.name).capabilities), only what you have "
                + "verified."
            switch linked {
            case .keptDirectory:
                return "The model is in the Hugging Face cache at \(plan.snapshot.path). \(plan.destination.path) "
                    + "stays as it was, so mlx:\(plan.name) still runs that copy; run the pull again and answer yes "
                    + "to replace it with a link."
            case .replacedDirectory:
                return "The directory is in the Trash and \(plan.destination.path) links to the snapshot. Use it as "
                    + "--model mlx:\(plan.name); \(declare)"
            case .created, .replacedLink, .unchanged:
                return "\(plan.destination.path) links to the snapshot. Use it as --model mlx:\(plan.name); \(declare)"
            }
        }

        /// Records the pull in the audit log as `model.pull`.
        func record(
            _ plan: ModelPull.Plan, fetched: Int, outcome: String, link: ModelPull.LinkOutcome?, reason: String?,
            started: ContinuousClock.Instant
        ) {
            guard let session = try? Wisp.begin(.init(entryPoint: .models)) else { return }
            let elapsed = ContinuousClock.now - started
            session.audit.record(
                .modelPull,
                details: AuditEvent.Details.modelPull(
                    model: "mlx:\(plan.name)", repository: plan.repository, directory: plan.destination.path,
                    cache: plan.snapshot.path, files: plan.files.count, bytes: plan.bytes, reused: plan.reused.count,
                    seeded: outcome == "declined" ? 0 : plan.seeded.count,
                    fetchedFiles: outcome == "fetched" ? plan.missing.count : 0, fetched: fetched, link: link?.rawValue,
                    outcome: outcome, reason: reason,
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            session.end()
        }
    }
}

/// Posts a macOS notification from the command line, through the same notifier the model's `notify`
/// tool uses and the terminal face's routes: bounded, rate-limited, audited as `notification` with source
/// `user` and the route taken.
struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a macOS notification.",
        discussion: "The same path as the model's notify tool: bounded text, a per-minute limit, audited.")

    @Argument(help: "The message.")
    var message: String

    @Option(name: [.short, .long], help: "The title (default: wisp).")
    var title = "wisp"

    @Option(name: .long, help: "A second line under the title.")
    var subtitle: String?

    @Flag(name: .long, help: "Play the default notification sound.")
    var sound = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Use only this route: host, terminal, app, or osascript. app is tried even when "
                + "notifications.viaTerminalApp is off, to probe which app the banner is attributed to.",
            valueName: "route"))
    var route: String?

    func validate() throws {
        if let route, NotificationRoute(rawValue: route) == nil {
            throw ValidationError("--route must be host, terminal, app, or osascript")
        }
    }

    func run() throws {
        let session = try Wisp.begin(.init(entryPoint: .notify))
        defer { session.end() }
        let host = session.host(
            approver: DenyingApprover(reason: "wisp notify runs no commands"), face: .terminal,
            only: route.flatMap(NotificationRoute.init(rawValue:)))
        let outcome = host.notify(
            .init(title: title, body: message, subtitle: subtitle, sound: sound), source: .user, audit: session.audit)
        switch outcome {
        case .posted(let route): if self.route != nil { Wisp.note("posted via \(route.rawValue)") }
        case .refused(let reason):
            // A route that cannot post is not a usage mistake: say why, without the usage text.
            Wisp.note("notification not shown: \(reason)")
            throw ExitCode.failure
        }
    }
}

/// Reports credentials and personal data in files or standard input, masked; exits 1 when it finds any.
struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan text for credentials and personal data.",
        discussion:
            "Reads the files given, or standard input. A unified diff is scanned by its added lines, so "
            + "'git diff --cached | wisp scan' checks a commit before it is made. Values are shown masked. "
            + "Exits 1 when anything is found.")

    @Argument(help: "Files to scan. Standard input when omitted.")
    var paths: [String] = []

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Report personal data too: emails, phone and card numbers, public IPs, addresses, private hostnames, "
                + "user names, and lines the personal-data classifier flags."))
    var personal = false

    @Flag(
        name: .long,
        help: "Also have the model look for what rules cannot recognise: up to three turns of about 2 s per 4 KiB.")
    var thorough = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model for --thorough. Defaults to routing.tasks.secrets, else the measured default (system).")
    var model: String?

    @Flag(name: .long, help: "Print the reports as JSON, one per line.")
    var json = false

    func run() async throws {
        let session = try Wisp.begin(.init(entryPoint: .scan, model: try model.map(Wisp.parseModel)))
        defer { session.end() }
        let options = SecretScan.Options(categories: personal ? [.secret, .personal] : [.secret], thorough: thorough)
        var found = false
        for input in try Wisp.inputs(paths) {
            let judge =
                thorough
                ? try Wisp.secretsJudge(
                    session: session, prefix: "scan", explicit: model, inputBytes: input.text.utf8.count) : nil
            let report = try await SecretScan(
                options: options, judge: judge, classifier: PersonalDataClassifier.shipped
            )
            .run(input.text, from: input.source)
            session.audit.record(.secretScan, details: AuditEvent.Details.secretScan(report))
            print(json ? ChatProtocol.encode("scan", report.json.objectValue ?? [:]) : report.rendered)
            found = found || !report.findings.isEmpty
        }
        if found { throw ExitCode.failure }
    }
}

/// Prints a file or standard input with credentials and personal data replaced by numbered markers.
struct Redact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Redact credentials and personal data from text.",
        discussion:
            "Reads a file, or standard input, and prints it with each value replaced by a marker such as "
            + "[REDACTED:email#1]; the same value gets the same marker. A summary goes to stderr.")

    @Argument(help: "The file to redact. Standard input when omitted.")
    var path: String?

    @Flag(name: .long, help: "Replace credentials only and keep personal data.")
    var secretsOnly = false

    @Flag(
        name: .long,
        help: "Also have the model find names, addresses, and identifiers: up to three turns of about 2 s per 4 KiB.")
    var thorough = false

    @Option(
        name: [.short, .customLong("model")],
        help: "Model for --thorough. Defaults to routing.tasks.secrets, else the measured default (system).")
    var model: String?

    func run() async throws {
        let session = try Wisp.begin(.init(entryPoint: .redact, model: try model.map(Wisp.parseModel)))
        defer { session.end() }
        guard let input = try Wisp.inputs(path.map { [$0] } ?? []).first else { return }
        let options = Redaction.Options(
            categories: secretsOnly ? [.secret] : [.secret, .personal], thorough: thorough, maxOutputBytes: .max)
        let judge =
            thorough
            ? try Wisp.secretsJudge(
                session: session, prefix: "redact", explicit: model, inputBytes: input.text.utf8.count) : nil
        let report = try await Redaction(options: options, judge: judge).run(input.text, from: input.source)
        session.audit.record(.redaction, details: AuditEvent.Details.redaction(report))
        print(report.text, terminator: "")
        FileHandle.standardError.write(Data((report.summary + "\n").utf8))
    }
}

extension Watcher.NotifyPolicy: ExpressibleByArgument {}
extension RiskClassifierChoice: ExpressibleByArgument {}
extension ChangeDraft.Kind: ExpressibleByArgument {}

/// Drafts a commit message, PR description, or changelog line from the staged diff or a piped one.
struct Draft: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draft a commit message, a PR description, or a changelog line from a diff.",
        discussion:
            "Reads a diff piped to it, or runs git diff --cached here. The model summarises it per file, then "
            + "writes from the summary. Review the draft; a commit body ends with a line for the reason to replace. For example: "
            + "wisp draft > /tmp/msg && $EDITOR /tmp/msg && git commit -F /tmp/msg")

    @Argument(help: "commit (default), pr, or changelog.")
    var kind: ChangeDraft.Kind = .commit

    @Option(name: [.short, .customLong("model")], help: "Model to write with. Defaults to config.json.")
    var model: String?

    @Flag(name: [.short, .long], help: "Approve running git diff without asking.")
    var yes = false

    func run() async throws {
        let session = try Wisp.begin(
            .init(entryPoint: .draft, model: try model.map(Wisp.parseModel), autoApprove: yes))
        defer { session.end() }
        let thread = try session.thread(
            id: "draft-" + ShortID.make(),
            host: session.host(approver: TerminalApprover(style: .plain), face: .terminal),
            tools: .none)
        let directory = FileManager.default.currentDirectoryPath
        let source: Triage.Source
        let captured: Triage.Captured
        if isatty(STDIN_FILENO) == 0 {
            source = .path("standard input")
            captured = Triage.Captured(
                text: String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
        } else {
            source = .command("git diff --cached", workingDirectory: directory)
            let runner = CommandRunner(
                options: session.config.runner, audit: thread.audit, approval: thread.gate)
            captured = Triage.Captured(try await runner.run("git diff --cached", in: directory))
        }
        let summarySchema = try OutputSchema(json: DiffSummary.schemaJSON)
        let draftSchema = try OutputSchema(json: ChangeDraft.schemaJSON)
        let bytes = captured.text.utf8.count
        let routed = ChangeDraft.route(
            explicit: try model.map(Wisp.parseModel), inputBytes: bytes, ladder: session.config.routingLadder,
            opens: { model in
                do {
                    _ = try thread.openAgent(model: model)
                    return nil
                } catch {
                    return "\(error)"
                }
            })
        if let routed {
            thread.audit.record(
                .modelRouted,
                details: AuditEvent.Details.modelRouted(
                    task: ChangeDraft.routingTask, inputBytes: bytes, decision: routed))
            Wisp.note("model: \(routed.model) (\(routed.reason))")
        }
        let chosen = routed?.model
        do {
            let draft = try await ChangeDraft.draft(
                kind, from: captured, source: source,
                summarise: {
                    try await thread.openAgent(model: chosen).respond(to: $0, schema: summarySchema).text
                },
                write: { try await thread.openAgent(model: chosen).respond(to: $0, schema: draftSchema).text })
            print(draft.text)
        } catch let failure as ChangeDraft.Failure {
            throw ValidationError("\(failure)")
        }
    }
}

/// Reruns a command as files change or on an interval, and notifies when its outcome turns.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rerun a command when files change, and notify when it starts or stops failing.",
        discussion:
            "Runs the command at once, then again after each change under the watched paths (build output and "
            + ".git ignored) and, with --every, on an interval. A failing run is triaged by the model into its "
            + "failures; when the outcome turns, a notification says so. The command runs under the policy, "
            + "sandbox, and approval like any other. Ctrl-C stops after the current run; a second Ctrl-C at once.")

    @Argument(help: "The command line to run, such as 'swift test 2>&1'.")
    var command: String

    @Option(name: [.customShort("C"), .long], help: "Directory to run the command in. Default: the current one.")
    var directory: String?

    @Option(name: .customLong("path"), help: "A directory to watch for changes (repeatable). Default: --directory.")
    var paths: [String] = []

    @Flag(name: .customLong("no-files"), help: "Do not watch files; run on the interval only.")
    var noFiles = false

    @Option(name: .long, help: "Also run every this many seconds.")
    var every: Double?

    @Option(
        name: .long,
        help: "Seconds without a file change before a run starts; 0 runs on every change. Default: watch.settle, 1.")
    var settle: Double?

    @Option(name: .long, help: "When to notify: change (default), failure, always, never.")
    var notify: Watcher.NotifyPolicy = .change

    @Flag(name: .customLong("no-triage"), help: "Do not have the model triage a failing run.")
    var noTriage = false

    @Option(name: .long, help: "Stop after this many runs.")
    var maxRuns: Int?

    @Option(name: [.short, .customLong("model")], help: "Model for triage. Defaults to config.json.")
    var model: String?

    @Flag(name: [.short, .long], help: "Approve risky commands without asking.")
    var yes = false

    func validate() throws {
        if noFiles && every == nil { throw ValidationError("--no-files needs --every, or nothing would rerun it") }
        if let every, every < 1 { throw ValidationError("--every must be at least 1 second") }
        if let settle, !Config.WatchConfig.settleRange.contains(settle) {
            throw ValidationError("--settle must be between 0 and 60 seconds")
        }
        if let maxRuns, maxRuns < 1 { throw ValidationError("--max-runs must be at least 1") }
    }

    func run() async throws {
        let session = try Wisp.begin(
            .init(entryPoint: .watch, model: try model.map(Wisp.parseModel), autoApprove: yes))
        defer { session.end() }
        let host = session.host(approver: TerminalApprover(style: .plain), face: .terminal)
        let thread = try session.thread(id: "watch-" + ShortID.make(), host: host, tools: .none)
        let directory = directory ?? FileManager.default.currentDirectoryPath
        let source = Triage.Source.command(command, workingDirectory: directory)
        var runner = CommandRunner(
            options: session.config.runner, audit: thread.audit, approval: thread.gate)
        runner.options.maxOutputBytes = Triage.Options().maxOutputBytes
        let schema = try OutputSchema(json: Triage.schemaJSON)
        let triage = Triage { prompt in try await thread.openAgent().respond(to: prompt, schema: schema).text }
        // The command line never changes, so it is classified and approved once, here; every run after
        // still passes the policy and the sandbox and is audited.
        let authorized = try await runner.authorize(command, in: directory)
        let (triggers, continuation) = AsyncStream.makeStream(
            of: Watcher.Trigger.self, bufferingPolicy: .bufferingNewest(1))
        // Bursts of file changes settle into one trigger; the start and the interval are never delayed.
        let settler = TriggerSettler(
            settle: .seconds(settle ?? session.config.watchSettle), clock: ContinuousClock(),
            continuation: continuation)
        settler.start()
        let watcher =
            noFiles
            ? nil
            : FileWatcher(paths: paths.isEmpty ? [directory] : paths) {
                settler.fileChanged()
            }
        if !noFiles && watcher == nil { throw ValidationError("cannot watch \(paths.isEmpty ? [directory] : paths)") }
        let interval = every.map { seconds in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds))
                    settler.interval()
                }
            }
        }
        defer { interval?.cancel() }
        let stop = Wisp.stopOnInterrupt { settler.finish() }
        defer { stop.cancel() }
        let command = command
        let clock = Date.FormatStyle(date: .omitted, time: .standard)
        Wisp.note(
            "watching \(watcher == nil ? "" : "\(paths.isEmpty ? directory : paths.joined(separator: ", ")) ")"
                + "\(every.map { "every \($0) s " } ?? "")for: \(command)")
        // The file watcher must outlive the loop; nothing else refers to it after this point.
        defer { withExtendedLifetime(watcher) {} }
        try await Watcher(
            command: command,
            options: .init(notify: notify, triage: !noTriage, maxRuns: maxRuns),
            execute: { Triage.Captured(try await authorized.run()) },
            triage: { captured in try await triage.run(captured, from: source).findings },
            notify: { message in _ = host.notify(message, source: .watch, audit: thread.audit) },
            report: { run in
                print("[\(Date().formatted(clock))] \(run.summary)")
                for finding in run.findings ?? [] {
                    print("  \(finding.kind)  \(finding.location ?? "-")  \(finding.message)")
                }
                fflush(stdout)
                thread.audit.record(.watchRun, details: AuditEvent.Details.watchRun(run, command: command))
            }
        ).run(triggers)
    }
}

/// Checks that this install can work: OS version, model availability, sandbox, config, home directory.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check that wisp can run on this Mac.",
        discussion: "Exits non-zero if any check fails. The first thing to run when something is wrong.")

    func run() throws {
        let config = try? Session.loadConfig(home: Wisp.home)
        let findings = Doctor(home: Wisp.home, model: config?.model ?? .default, config: config ?? Config().resolved)
            .run()
        print("wisp \(WispVersion.display)")
        print(Doctor.render(findings))
        guard Doctor.allPassed(findings) else { throw ExitCode.failure }
    }
}

/// Lists and revokes standing command approvals in ~/.wisp/approvals.json, and answers commands waiting for
/// approval under `wisp mcp` (ADR 0046).
struct Approvals: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or revoke standing command approvals, and answer commands waiting for approval.",
        discussion:
            "Project and always approvals outlive the process. They are remembered by program and verb (git push *), expire, and never cover dangerous commands. "
            + "A command the model runs under wisp mcp that needs approval waits in ~/.wisp/pending: 'pending' lists "
            + "them, and 'approve' or 'deny' answers one from a terminal.",
        subcommands: [List.self, Revoke.self, Clear.self, Pending.self, Approve.self, Deny.self],
        defaultSubcommand: List.self)

    /// Prints live approvals, newest first.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List standing approvals.")

        func run() async throws {
            let store = ApprovalStore(url: Wisp.home.approvalsFile)
            let entries = await store.all
            if entries.isEmpty {
                print("no standing approvals")
                return
            }
            for line in ListingLayout.approvals(entries, width: TerminalTable.detectWidth()) { print(line) }
        }
    }

    /// Removes one approval by id.
    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke one standing approval by id.")

        @Argument(help: "The id shown by 'wisp approvals'.", completion: DynamicCompletions.approvals)
        var id: String

        func run() async throws {
            let store = ApprovalStore(url: Wisp.home.approvalsFile)
            guard try await store.revoke(id: id) else { throw ValidationError("no approval with id \(id)") }
            print("revoked \(id)")
        }
    }

    /// Removes every approval.
    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke every standing approval.")

        func run() async throws {
            try await ApprovalStore(url: Wisp.home.approvalsFile).clear()
            print("cleared")
        }
    }

    /// Lists the commands waiting for approval under `wisp mcp`, removing stale ones first.
    struct Pending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List commands waiting for approval in wisp mcp servers.")

        func run() async throws {
            let channel = PendingApprovals(home: Wisp.home)
            Approvals.sweep(channel)
            let requests = channel.waiting()
            guard !requests.isEmpty else {
                print("no commands waiting for approval")
                return
            }
            for line in ListingLayout.pending(requests, width: TerminalTable.detectWidth()) { print(line) }
        }
    }

    /// Approves one waiting command.
    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Approve a command waiting for approval, from a terminal.",
            discussion:
                "The scope is how long the approval lasts, as in chat: once (the rest of the turn), session (the "
                + "server's process), project (30 days, this command in this directory), or always (30 days). "
                + "A dangerous command is never remembered beyond the session.")

        @Argument(
            help: "The id shown by 'wisp approvals pending' and in the notification.",
            completion: DynamicCompletions.pendingCommands)
        var id: String

        @Option(name: .long, help: "once, session, project, or always.")
        var scope: ApprovalScope = .once

        func run() async throws {
            try Approvals.answer(id, decision: scope.rawValue)
        }
    }

    /// Denies one waiting command.
    struct Deny: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Deny a command waiting for approval.")

        @Argument(
            help: "The id shown by 'wisp approvals pending' and in the notification.",
            completion: DynamicCompletions.pendingCommands)
        var id: String

        func run() async throws {
            try Approvals.answer(id, decision: "no")
        }
    }

    /// Removes stale requests and records each as settled `stale`, under a session of its own.
    static func sweep(_ channel: PendingApprovals) {
        let removed = channel.sweep()
        guard !removed.isEmpty, let session = try? Wisp.begin(.init(entryPoint: .approvals)) else { return }
        for request in removed {
            session.audit.record(
                .approvalSettled,
                details: AuditEvent.Details.approvalSettled(
                    request, outcome: "stale", reason: "its server stopped or its wait expired"))
        }
        session.end()
    }

    /// Writes the person's answer to request `id` and reports whether the waiting server took it. Only from a
    /// terminal: an agent's shell, which has none, cannot answer for the person.
    ///
    /// - Throws: A validation error when not at a terminal or for a decision that is not one; `ExitCode.failure`
    ///   when the request cannot be answered or the answer came too late (`PendingAnswer`).
    static func answer(_ id: String, decision: String) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(
                "wisp approvals approve and deny answer for the person, so they run only from a terminal; "
                    + "answer in the terminal, or in wisp-tui")
        }
        let channel = PendingApprovals(home: Wisp.home)
        sweep(channel)
        let session = try Wisp.begin(.init(entryPoint: .approvals))
        defer { session.end() }
        let request: PendingApprovals.Request
        do {
            request = try channel.answer(id, decision: decision, via: "cli")
        } catch let failure as PendingApprovals.Failure {
            session.audit.record(
                .approvalAnswered,
                details: AuditEvent.Details.approvalAnswered(
                    request: id, try? channel.request(id: id), decision: decision, via: "cli", delivery: "refused",
                    reason: "\(failure)"))
            try end(PendingAnswer.ending(for: failure))
            return
        }
        // The server looks every 200 ms; give it a few seconds to take the answer.
        var delivery = channel.delivery(of: id)
        for _ in 0..<15 where delivery == .waiting {
            usleep(200_000)
            delivery = channel.delivery(of: id)
        }
        let text: String =
            switch delivery {
            case .taken: "taken"
            case .tooLate: "too-late"
            case .waiting: "waiting"
            }
        session.audit.record(
            .approvalAnswered,
            details: AuditEvent.Details.approvalAnswered(
                request: id, request, decision: decision, via: "cli", delivery: text))
        try end(PendingAnswer.ending(of: request, decision: decision, delivery: delivery))
    }

    /// Ends an answering command as `PendingAnswer` decided: the line on stdout, a usage error (exit 64), or
    /// the message on stderr and exit 1 for an answer the request's state kept from being used.
    ///
    /// - Throws: `ValidationError` or `ExitCode.failure`.
    static func end(_ ending: PendingAnswer.Ending) throws {
        switch ending {
        case .printed(let line): print(line)
        case .usage(let message): throw ValidationError(message)
        case .failed(let message):
            Wisp.note("Error: \(message)")
            throw ExitCode.failure
        }
    }
}

extension ApprovalScope: ExpressibleByArgument {}

/// Trains and measures the fast, specialised classifiers the approval gate can use (ADR 0038).
struct ClassifierCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "classifier", abstract: "Train, measure, and choose risk classifiers for the approval gate.",
        discussion:
            "A classifier judges every command the model runs, so it must be fast: a model trained here answers "
            + "in well under a millisecond, the on-device language model in one to two seconds. Versions live in "
            + "~/.wisp/classifiers/risk: the default each release ships, never changed, and those trained here, "
            + "never overwritten.",
        subcommands: [List.self, Train.self, Measure.self, Use.self, Remove.self, Ship.self, Split.self, Baseline.self])

    /// The store under wisp's home.
    static var store: ClassifierStore { ClassifierStore(home: Wisp.home) }

    /// The version `approval.coremlModel` names, or the default when it names none.
    static func inUse(_ config: Config.Resolved) -> String? {
        guard let configured = config.coremlModel else { return ClassifierStore.defaultVersion() }
        return ClassifierStore.version(of: configured)
    }

    /// Every audit event on this Mac, oldest first: the rotated files, then the current one.
    static func auditEvents(session: Session) -> [AuditEvent] {
        let current = Wisp.home.auditFile
        let files =
            FileAuditSink.rotatedFiles(for: current, keep: session.config.auditLimits.keepFiles).reversed() + [current]
        return files.flatMap { url in (try? Data(contentsOf: url)).map(AuditQuery.events(in:)) ?? [] }
    }

    /// Labelled commands from a file, or the bundled training examples.
    ///
    /// - Throws: A usage error naming the file and the bad line.
    static func examples(_ path: String?) throws -> (examples: [RiskExample], source: String) {
        guard let path else { return (RiskExamples.bundled, "bundled") }
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        do {
            return (try RiskExamples.load(url), url.path)
        } catch {
            throw ValidationError("\(url.path): \(error)")
        }
    }

    /// Lists the versions.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the risk classifier versions on this Mac.")

        func run() async throws {
            let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
            _ = try? ClassifierCommand.store.installDefault()
            let active = config.approvalClassifier == .coreml ? ClassifierCommand.inUse(config) : nil
            for manifest in ClassifierCommand.store.versions() {
                let mark = manifest.version == active ? "*" : " "
                let last =
                    manifest.measurements.last.map { m in
                        String(
                            format: "%d/%d exact, %d under, p50 %.2f ms", m.correct, m.total, m.under, m.p50Milliseconds
                        )
                    } ?? "not measured"
                print(
                    "\(mark) \(ClassifierStore.reference(manifest.version))\t\(manifest.created.prefix(10))\t"
                        + "\(manifest.examples) examples (\(manifest.examplesSource))\t\(last)")
            }
            if active == nil {
                print("approval.classifier is \(config.approvalClassifier.rawValue); 'use' switches to one")
            }
        }
    }

    /// Trains a new version with Create ML on this Mac.
    struct Train: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Train a new risk classifier version on this Mac from labelled commands.",
            discussion:
                "Examples are lines of level<TAB>command, level being safe, moderate, or dangerous; '#' starts a "
                + "comment. Without --examples, the examples bundled with wisp are used. Each run adds a version "
                + "and changes nothing in use; 'wisp classifier use' switches to it.")

        @Option(name: .long, help: "Labelled commands to learn from. Defaults to the bundled examples.")
        var examples: String?

        @Flag(
            name: .long,
            help: "Also learn from the on-device model's verdicts in this Mac's audit log, secrets redacted.")
        var fromAudit = false

        @Flag(name: .long, help: "Use the new version at once, as 'wisp classifier use' would.")
        var use = false

        @Option(name: .long, help: "Labelled commands to leave out of training, such as a test set; repeatable.")
        var exclude: [String] = []

        func run() async throws {
            let session = try Wisp.begin(.init(entryPoint: .classifier))
            defer { session.end() }
            var (examples, source) = try ClassifierCommand.examples(examples)
            if fromAudit {
                let harvest = RiskExamples.fromAudit(ClassifierCommand.auditEvents(session: session))
                print(
                    "from the audit log: \(harvest.examples.count) commands from \(harvest.verdicts) model verdicts, "
                        + "\(harvest.fallbacks) fallbacks left out, \(harvest.raised) raised after a refusal, "
                        + "\(harvest.redacted) redacted")
                examples = RiskExamples.merged(examples, with: harvest.examples)
                source += " + audit"
            }
            let held = ClassifierCommand.store.withoutHeldOut(
                examples, also: exclude.map { URL(filePath: ($0 as NSString).expandingTildeInPath) })
            if held.removed > 0 {
                print("left out \(held.removed) examples that overlap held-out commands")
                examples = held.kept
            }
            let parent = session.config.approvalClassifier == .coreml ? ClassifierCommand.inUse(session.config) : nil
            let trained: (manifest: ClassifierStore.Manifest, outcome: RiskClassifierTraining.Outcome)
            do {
                trained = try ClassifierCommand.store.train(examples, source: source, parent: parent)
            } catch let failure as RiskClassifierTraining.Failure {
                throw ValidationError("\(source): \(failure)")
            }
            session.audit.record(
                .classifierTrained,
                details: AuditEvent.Details.classifierTrained(trained.outcome, examplesSource: source))
            let levels = RiskLevel.allCases.map { "\(trained.outcome.perLevel[$0, default: 0]) \($0.rawValue)" }
            let reference = ClassifierStore.reference(trained.manifest.version)
            print(
                "trained \(reference) on \(trained.outcome.examples) examples (\(levels.joined(separator: ", "))) in "
                    + String(format: "%.1f s; ", trained.outcome.seconds)
                    + String(format: "%.0f%% of them labelled back correctly", trained.outcome.trainingAccuracy * 100))
            if use {
                try ClassifierCommand.use(reference)
            } else {
                print("to use it: wisp classifier use \(reference)")
            }
            print("measure it on commands it has not seen: wisp classifier measure \(reference) --examples <file>")
        }
    }

    /// Points the approval gate at a version: `approval.classifier` coreml and `approval.coremlModel` it.
    ///
    /// - Throws: A usage error for an unknown version or a refused change.
    static func use(_ reference: String) throws {
        guard let version = ClassifierStore.version(of: reference) else {
            throw ValidationError("\(ClassifierStore.Failure.notAReference(reference))")
        }
        if version == ClassifierStore.defaultVersion() { _ = try? store.installDefault() }
        guard store.manifest(version) != nil else {
            throw ValidationError("\(ClassifierStore.Failure.unknownVersion(version))")
        }
        try ConfigCommand.apply("approval.coremlModel") {
            try ConfigEdit.set("approval.coremlModel", to: reference, in: $0)
        }
        try ConfigCommand.apply("approval.classifier") {
            try ConfigEdit.set("approval.classifier", to: "coreml", in: $0)
        }
    }

    /// Switches the approval gate to a version.
    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Use a risk classifier version for the approval gate, from the next session.")

        @Argument(help: "The version, as 'wisp classifier list' shows it: risk@<version>.")
        var reference: String

        func run() async throws {
            try ClassifierCommand.use(reference)
        }
    }

    /// Removes a local version.
    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove a risk classifier version trained here; not the default, not the one in use.")

        @Argument(help: "The version: risk@<version>.")
        var reference: String

        func run() async throws {
            guard let version = ClassifierStore.version(of: reference) else {
                throw ValidationError("\(ClassifierStore.Failure.notAReference(reference))")
            }
            let config = try Wisp.usage { try Session.loadConfig(home: Wisp.home) }
            let inUse = config.approvalClassifier == .coreml ? ClassifierCommand.inUse(config) : nil
            do {
                try ClassifierCommand.store.remove(version, inUse: inUse)
            } catch let failure as ClassifierStore.Failure {
                throw ValidationError("\(failure)")
            }
            print("removed \(reference)")
        }
    }

    /// Labels each line as wisp's rules do today, for comparing a trained classifier with them.
    struct Baseline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Print the label wisp's rules give each line: risk by the risk rules (none when no rule matches), "
                + "failures by KnownFailures, log-severity by LogDigest, secrets by SecretScanner.",
            shouldDisplay: false)

        @Option(name: .long, help: "risk, failures, log-severity, or secrets.")
        var task: String

        @Option(name: .long, help: "Labelled lines; the output is the rules' label, a tab, and the line.")
        var examples: String

        @Flag(name: .long, help: "For risk, add the matching rules' reasons after the line.")
        var reasons = false

        @Flag(name: .long, help: "For secrets, add the shipped personal-data classifier, as wisp scan --personal does.")
        var classifier = false

        func run() async throws {
            for example in TrainingSplit.parse(try String(contentsOfFile: examples, encoding: .utf8)) {
                let label: String
                switch task {
                case "risk":
                    let verdict = await RuleRiskClassifier.standard.classify(
                        command: example.text, workingDirectory: ".")
                    label = verdict.reasons == [RuleRiskClassifier.noSignals] ? "none" : verdict.level.rawValue
                    if reasons {
                        print("\(label)\t\(example.text)\t\(verdict.reasons.joined(separator: "; "))")
                        continue
                    }
                case "failures": label = KnownFailures.scan(example.text).findings.first?.kind ?? "none"
                case "log-severity": label = LogDigest.severity(of: example.text).rawValue
                case "secrets":
                    let rules = SecretScanner.label(of: example.text)
                    let flagged =
                        if classifier, rules == "none", case .success(let model) = PersonalDataClassifier.shipped {
                            model.flags(example.text)
                        } else { false }
                    label = flagged ? "personal" : rules
                default: throw ValidationError("no baseline for \(task)")
                }
                print("\(label)\t\(example.text)")
            }
        }
    }

    /// Splits a labelled set into parts no family spans, for the training sets in `training/`.
    struct Split: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Split a labelled set into train and dev (and test) parts by family.", shouldDisplay: false)

        @Option(name: .long, help: "The labelled set to split.")
        var input: String

        @Option(name: .long, help: "The directory to write the parts into.")
        var out: String

        @Option(name: .long, help: "Part names and shares, such as train=0.85,dev=0.15.")
        var parts: String = "train=0.85,dev=0.15"

        @Option(
            name: .long,
            help: "A set whose overlaps are removed from the input first, such as a fixed dev set; repeat for more.")
        var exclude: [String] = []

        @Option(name: .long, help: "The seed that deals the families.")
        var seed: UInt64 = 1

        @Option(name: .long, help: "Keep at most this many examples of any one family, so no template dominates.")
        var cap: Int?

        func run() async throws {
            var examples = TrainingSplit.parse(try String(contentsOfFile: input, encoding: .utf8))
            var seen = Set<String>()
            let before = examples.count
            examples = examples.filter { seen.insert(TrainingSplit.canonical($0.text)).inserted }
            if examples.count < before { print("dropped \(before - examples.count) repeated examples") }
            for exclude in exclude {
                let fixed = TrainingSplit.parse(try String(contentsOfFile: exclude, encoding: .utf8))
                let clashing = Set(TrainingSplit.overlaps(fixed, examples).map(\.second))
                examples.removeAll { clashing.contains($0.text) }
                print("removed \(clashing.count) examples that overlap \(exclude)")
            }
            if let cap {
                let before = examples.count
                let kept = Set(TrainingSplit.clusters(examples).values.flatMap { $0.prefix(cap) })
                examples = examples.filter(kept.contains)
                print("capped families at \(cap): kept \(examples.count) of \(before)")
            }
            let named = parts.split(separator: ",").compactMap { part -> (String, Double)? in
                let pieces = part.split(separator: "=")
                return pieces.count == 2 ? Double(pieces[1]).map { (String(pieces[0]), $0) } : nil
            }
            let split = TrainingSplit.split(examples, fractions: named.map(\.1), seed: seed)
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            for ((name, _), part) in zip(named, split) {
                let header = [
                    "The \(name) part of \(URL(filePath: input).lastPathComponent), split by family with seed \(seed)",
                    "(wisp classifier split); see training/README.md for the labels and rules.",
                ]
                try Data(TrainingSplit.write(part, header: header).utf8).write(
                    to: URL(filePath: out).appending(path: "\(name).tsv"))
                let labels = Dictionary(grouping: part, by: \.label).mapValues(\.count).sorted { $0.key < $1.key }
                print(
                    "\(name): \(part.count) examples (\(labels.map { "\($0.value) \($0.key)" }.joined(separator: ", ")))"
                )
            }
        }
    }

    /// Trains the default a release ships, for the release preparation; not for everyday use.
    struct Ship: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Train the default classifier a release ships into a resource file.", shouldDisplay: false)

        @Option(
            name: .long, help: "The resource to write, such as harness/Sources/WispCore/Resources/risk-default.json.")
        var resource: String

        @Option(name: .long, help: "risk (the default, retrained each release) or personal (trained by hand).")
        var task = "risk"

        @Option(name: .long, help: "For personal: the labelled lines, training/secrets/train.tsv.")
        var examples: String?

        @Option(name: .long, help: "For personal: the lines that decide when training stops, training/secrets/dev.tsv.")
        var validation: String?

        @Option(name: .long, help: "For personal: the version to give it, one more than the embedded one.")
        var classifierVersion: String?

        func run() async throws {
            switch task {
            case "risk": try shipRisk()
            case "personal": try shipPersonal()
            default: throw ValidationError("no shipped classifier for \(task)")
            }
        }

        /// Trains the personal-data classifier into `resource`.
        private func shipPersonal() throws {
            guard let examples, let validation, let version = classifierVersion else {
                throw ValidationError("--task personal needs --examples, --validation, and --classifier-version")
            }
            let lines = TrainingSplit.parse(try String(contentsOfFile: examples, encoding: .utf8))
            let held = TrainingSplit.parse(try String(contentsOfFile: validation, encoding: .utf8))
            let staging = FileManager.default.temporaryDirectory.appending(
                path: "wisp-ship-\(UUID().uuidString).mlmodel")
            defer { try? FileManager.default.removeItem(at: staging) }
            let manifest = try PersonalDataTraining.train(
                lines, validation: held,
                source: (examples as NSString).lastPathComponent == "train.tsv"
                    ? "training/secrets/train.tsv" : examples,
                writingTo: staging, version: version)
            let model = try Data(contentsOf: staging)
            let text = try PersonalDataClassifier.resource(manifest: manifest, model: model)
            try Data(text.utf8).write(to: URL(filePath: resource), options: .atomic)
            print("wrote personal@\(version) (\(model.count) bytes, \(manifest.examples) examples) to \(resource)")
        }

        /// Trains the risk default this release ships into `resource`.
        private func shipRisk() throws {
            let version = ClassifierStore.defaultVersion()
            let staging = FileManager.default.temporaryDirectory.appending(path: "wisp-ship-\(UUID().uuidString)")
            let store = ClassifierStore(home: Home(root: staging))
            let trained = try store.train(RiskExamples.bundled, source: "bundled", version: version)
            let model = try Data(contentsOf: store.model(version))
            let text = try ShippedClassifier.resource(manifest: trained.manifest, model: model)
            try Data(text.utf8).write(to: URL(filePath: resource), options: .atomic)
            try? FileManager.default.removeItem(at: staging)
            print("wrote \(ClassifierStore.reference(version)) (\(model.count) bytes) to \(resource)")
        }
    }

    /// Runs a classifier over labelled commands for accuracy and speed.
    struct Measure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure a risk classifier's accuracy and speed on labelled commands.",
            discussion:
                "The rules always run beside a classifier, as the approval gate runs them. Exits 1 when a dangerous "
                + "command is rated safe. Measure a trained version on examples it was not trained on; the result is "
                + "recorded in the version's manifest.")

        @Argument(help: "A version to measure, risk@<version>; without it, what the configuration uses.")
        var reference: String?

        @Option(name: .long, help: "Labelled commands. Defaults to the bundled training examples.")
        var examples: String?

        @Option(name: .long, help: "rules, system-model, or coreml. Defaults to approval.classifier.")
        var classifier: RiskClassifierChoice?

        @Option(name: .long, help: "A Core ML model file for --classifier coreml, instead of a version.")
        var coremlModel: String?

        func run() async throws {
            let session = try Wisp.begin(.init(entryPoint: .classifier))
            defer { session.end() }
            let (examples, source) = try ClassifierCommand.examples(examples)
            var config = session.config
            if let reference {
                config.approvalClassifier = .coreml
                config.coremlModel = reference
            }
            if let classifier { config.approvalClassifier = classifier }
            if let coremlModel { config.coremlModel = coremlModel }
            let measured = Session.Dependencies.live.makeClassifier(config, Wisp.home)
            let report = await RiskMeasurement.run(measured, on: examples)
            let version = config.approvalClassifier == .coreml ? ClassifierCommand.inUse(config) : nil
            print(
                "\(version.map(ClassifierStore.reference) ?? config.approvalClassifier.rawValue) on \(examples.count) examples from \(source):"
            )
            for line in report.lines { print("  \(line)") }
            if let version, ClassifierCommand.store.manifest(version) != nil {
                try? ClassifierCommand.store.record(.init(report, examplesSource: source), for: version)
            }
            if !report.holdsTheHardRequirement { throw ExitCode.failure }
        }
    }
}

/// The options completion offers per setting, fetched on first use and kept for the session.
final class CompletionOptions: Sendable {
    private let fetch: @Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option]
    private let cache = Mutex<[String: [String]]?>(nil)

    /// Creates a cache over `fetch`.
    init(fetch: @escaping @Sendable (ConfigSettings.Setting) async -> [ChatChoice.Option]) {
        self.fetch = fetch
    }

    /// Every setting's options by path, fetching them the first time.
    func all() async -> [String: [String]] {
        if let cached = cache.withLock({ $0 }) { return cached }
        var found: [String: [String]] = [:]
        for setting in ConfigSettings.all {
            let values = await fetch(setting).map(\.value)
            if !values.isEmpty { found[setting.path] = values }
        }
        cache.withLock { $0 = found }
        return found
    }
}

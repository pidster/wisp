import Foundation
import FoundationModels
import Logging
import MCP
import Synchronization
import WispCore

/// Serves wisp's capabilities to MCP clients over stdio.
///
/// Conversations are kept as threads in a `ThreadRegistry` for the life of the
/// process. Stdout is the protocol channel; nothing else in the process may
/// write to it while the server runs.
public struct WispServer: Sendable {
    /// Server name reported during the MCP handshake.
    public static let name = "wisp"
    /// Server version reported during the MCP handshake; the same single source as `--version`.
    public static let version = WispVersion.current

    /// The session every thread shares: policy, store, session approvals, audit, and the elicitation approver.
    let session: Session
    /// Live conversations by `thread_id`, each with its gate and audit log.
    let threads: ThreadRegistry<OpenThread>
    /// What the server remembers of every thread it has opened, for `wisp://threads`.
    let directory = ThreadDirectory()
    /// The MCP server; created up front so the approver can reach the client.
    private let server: Server
    /// Set from the initialize hook when the client advertises elicitation.
    private let client = ClientCapabilityFlags()
    /// The approval dialogs in flight, so one answered another way can be withdrawn.
    private let tracker = ElicitationTracker()
    /// Builds the record for a new `thread_id` from the conversation the session sets up for it.
    public typealias ThreadFactory =
        @Sendable (
            _ session: Session, _ host: SessionHost, _ id: String, _ instructions: String?,
            _ tools: ToolSelection, _ model: ModelSelection?
        ) throws -> OpenThread
    private let makeThread: ThreadFactory
    /// The MCP face's effects (ADR 0044): commands are asked through elicitation (`--yes` sessions approve
    /// inside the gate instead); notifications take the process routes, since the client owns the terminal
    /// and MCP has no notification.
    let host: SessionHost
    /// Opens the agent that judges one chunk for a condensing tool; tests inject one over a scripted model.
    private let makeTriageAgent: @Sendable (WispThread, ModelSelection?) throws -> Agent

    /// Creates a server over a session begun by the CLI. Threads are opened through
    /// `Session.thread` with an elicitation approver, so every face of wisp shares one
    /// set-up path and differs only in how it asks.
    ///
    /// - Parameters:
    ///   - session: The session from `Session.begin`.
    ///   - makeThread: How threads are built; tests inject a fake that needs no model.
    ///   - makeTriageAgent: How a condensing tool's agent is opened on its conversation, on a routed model
    ///     when one was chosen and the conversation's own otherwise; tests inject a
    ///     scripted model.
    public init(
        session: Session,
        makeThread: @escaping ThreadFactory = { session, host, id, instructions, tools, model in
            let thread = try session.thread(
                id: id, host: host, instructions: instructions, tools: tools, model: model)
            return OpenThread(
                thread: ThreadActor(id: id, agent: try thread.openAgent()), gate: thread.gate,
                audit: thread.audit, receipts: thread.receipts, relay: thread.relay,
                model: thread.model.description, tools: thread.tools.map(\.name))
        },
        makeTriageAgent: @escaping @Sendable (WispThread, ModelSelection?) throws -> Agent = {
            try $0.openAgent(model: $1)
        }
    ) {
        server = Server(
            name: Self.name, version: Self.version,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        self.session = session
        let elicitation = ElicitationApprover(
            server: server, client: client, timeout: session.config.approvalTimeout, tracker: tracker)
        let client = client
        // ADR 0046: the client's dialog, and the pending channel that wisp approvals and wisp-tui answer, at
        // once; without either, the elicitation approver's denial says why.
        host = session.host(
            approver: session.mcpApprover(
                elicitation: { elicitation.ask }, fallback: elicitation, client: { client.name.withLock { $0 } }),
            face: .mcp)
        threads = ThreadRegistry(capacity: session.config.maxThreads)
        self.makeThread = makeThread
        self.makeTriageAgent = makeTriageAgent
    }

    var config: Config.Resolved { session.config }
    private var audit: AuditLog { session.audit }

    /// Starts serving on stdin/stdout and returns when the client disconnects.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    public func run() async throws {
        Diagnostics.mcp.info("serving on stdio")
        try await serve(transport: StdioTransport(logger: DiagnosticsLogHandler.logger()))
        await server.waitUntilCompleted()
        Diagnostics.mcp.info("client disconnected")
        // Requests this process filed and never settled (a call still waiting at disconnect) are stale now.
        let pid = getpid()
        PendingApprovals(home: session.home).sweep { $0 != pid && PendingApprovals.isAlive($0) }
    }

    /// Registers the method handlers and starts the server on `transport`, wrapped in
    /// `CompatibilityTransport`; returns once the transport is up. Tests call this with an in-memory
    /// transport and a real client.
    ///
    /// - Throws: Transport errors from the MCP SDK.
    func serve(transport: any Transport) async throws {
        let transport = CompatibilityTransport(transport, tracker: tracker)
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.all) }
        await server.withMethodHandler(CallTool.self) { params in try await self.call(params) }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: ToolCatalog.resources, nextCursor: nil)
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: ToolCatalog.resourceTemplates, nextCursor: nil)
        }
        await server.withMethodHandler(ReadResource.self) { params in try await self.read(params) }
        let client = client
        try await server.start(transport: transport) { info, capabilities in
            let supported = capabilities.elicitation != nil
            client.elicitation.withLock { $0 = supported }
            client.name.withLock { $0 = info.name }
            Diagnostics.mcp.info(
                "client \(info.name) \(info.version); elicitation \(supported ? "supported" : "unsupported")")
        }
    }

    /// Stops the server; tests call this after `serve`.
    func stop() async {
        await server.stop()
    }

    /// The progress token of the call being handled, when its caller asked for progress
    /// (`_meta.progressToken`); read by `relaying`.
    @TaskLocal static var progressToken: ProgressToken?

    /// Dispatches one `tools/call`, with the caller's progress token in scope for `relaying`.
    func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        try await Self.$progressToken.withValue(params._meta?.progressToken) { try await handle(params) }
    }

    /// Runs `body` and, when the caller asked for progress, sends it each line chat would show for the
    /// conversation's events meanwhile (`ChatEvents.progress`): tool calls, the gate's decisions, a wait
    /// for approval, command outcomes. The notifications go in order, numbered from 1, and all are sent
    /// before the result.
    ///
    /// - Parameters:
    ///   - relay: The conversation's live events.
    ///   - body: The call's work.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func relaying<T>(_ relay: EventRelay, _ body: () async throws -> T) async rethrows -> T {
        guard let token = Self.progressToken else { return try await body() }
        let (lines, continuation) = AsyncStream<String>.makeStream()
        let listener = relay.listen { event in
            if let line = ChatEvents.progress(event) { continuation.yield(line) }
        }
        let server = self.server
        let sender = Task {
            var step = 0.0
            for await line in lines {
                step += 1
                try? await server.notify(
                    ProgressNotification.message(.init(progressToken: token, progress: step, message: line)))
            }
        }
        let finish = {
            relay.stop(listener)
            continuation.finish()
            await sender.value
        }
        do {
            let result = try await body()
            await finish()
            return result
        } catch {
            await finish()
            throw error
        }
    }

    /// Dispatches one `tools/call`. Argument errors surface as MCP protocol
    /// errors; execution failures come back as tool results with `isError`.
    private func handle(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let call = ShortID.make()
        let arguments = params.arguments.map { Self.render($0) } ?? "{}"
        audit.record(
            .mcpRequest, call: call, details: AuditEvent.Details.mcpRequest(tool: params.name, arguments: arguments))
        Diagnostics.mcp.debug("request \(call) \(params.name) \(arguments)")
        let started = Date()
        let result: CallTool.Result
        do {
            switch params.name {
            case ToolCatalog.respond.name:
                let request = try RespondRequest(arguments: params.arguments)
                result = await respond(request)
            case ToolCatalog.triage.name:
                let request = try TriageRequest(arguments: params.arguments)
                result = await triage(request)
            case ToolCatalog.summariseDiff.name:
                let request = try SummariseDiffRequest(arguments: params.arguments)
                result = await summariseDiff(request)
            case ToolCatalog.draftChange.name:
                let request = try DraftChangeRequest(arguments: params.arguments)
                result = await draftChange(request)
            case ToolCatalog.scanSecrets.name:
                let request = try ScanSecretsRequest(arguments: params.arguments)
                result = await scanSecrets(request)
            case ToolCatalog.redact.name:
                let request = try RedactRequest(arguments: params.arguments)
                result = await redact(request)
            case ToolCatalog.condenseLog.name:
                let request = try CondenseLogRequest(arguments: params.arguments)
                result = await condenseLog(request)
            case ToolCatalog.jsonShape.name:
                let request = try JSONShapeRequest(arguments: params.arguments)
                result = await jsonShape(request)
            case ToolCatalog.dependencyAudit.name:
                result = await dependencyAudit(try CondensingRequest(arguments: params.arguments).source)
            case ToolCatalog.flakyTests.name:
                result = await flakyTests(try FlakyTestsRequest(arguments: params.arguments))
            case ToolCatalog.hotPaths.name:
                result = await hotPaths(try CondensingRequest(arguments: params.arguments).source)
            case ToolCatalog.setFactScope.name:
                let request = try SetFactScopeRequest(arguments: params.arguments)
                result = await setFactScope(request)
            case ToolCatalog.closeThread.name:
                let request = try CloseThreadRequest(arguments: params.arguments)
                result = await closeThread(request)
            default:
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
        } catch {
            audit.error(error, call: call, context: "mcp \(params.name)")
            throw error
        }
        let text = result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined(
            separator: "\n")
        audit.record(
            .mcpResult, call: call,
            details: AuditEvent.Details.mcpResult(
                tool: params.name, isError: result.isError ?? false, text: text,
                seconds: Date().timeIntervalSince(started)))
        return result
    }

    /// Serves the resources: the tool catalogue from the live registry, and the introspection views.
    ///
    /// - Throws: `MCPError.invalidParams` for an unknown URI; file errors reading the audit log.
    func read(_ params: ReadResource.Parameters) async throws -> ReadResource.Result {
        let registry = ToolRegistry(runner: config.runner, disabled: config.disabledTools, custom: config.customTools)
        let views = session.introspection
        func json(_ value: JSONValue) -> ReadResource.Result {
            .init(contents: [.text(Introspection.render(value), uri: params.uri, mimeType: "application/json")])
        }
        func lines(_ events: [AuditEvent]) throws -> ReadResource.Result {
            let text = try events.map { String(decoding: try AuditEvent.encoder.encode($0), as: UTF8.self) }
                .joined(separator: "\n")
            return .init(contents: [.text(text, uri: params.uri, mimeType: "application/x-ndjson")])
        }
        switch params.uri {
        case ToolCatalog.toolsResourceURI:
            return .init(contents: [.text(registry.descriptionsJSON, uri: params.uri, mimeType: "application/json")])
        case ToolCatalog.toolsMarkdownResourceURI:
            return .init(contents: [.text(registry.descriptionsMarkdown, uri: params.uri, mimeType: "text/markdown")])
        case ToolCatalog.measurementsResourceURI:
            return .init(
                contents: [
                    .text(Measurements.encode(Measurements.embedded), uri: params.uri, mimeType: "application/json")
                ])
        case ToolCatalog.configResourceURI:
            return json(views.configuration)
        case ToolCatalog.statusResourceURI:
            var status = views.status()
            status["threadCount"] = .int(await threads.ids.count)
            status["threadsURI"] = .string(ToolCatalog.threadsResourceURI)
            status["standingApprovals"] = .int(await session.store.all.count)
            return json(.object(status))
        case ToolCatalog.approvalsResourceURI:
            return json(await views.approvals())
        case ToolCatalog.auditResourceURI:
            return try lines(try views.audit(AuditQuery(last: 100)))
        case let uri where uri.hasPrefix(ToolCatalog.auditResourceURI + "/"):
            let id = String(uri.dropFirst(ToolCatalog.auditResourceURI.count + 1))
            guard SafeName.isValid(id) else { throw MCPError.invalidParams("session id must be \(SafeName.rule)") }
            guard directory.record(id) == nil else {
                throw MCPError.invalidParams(
                    "\(id) is a respond thread; read \(ToolCatalog.threadURI(id))/audit for its events")
            }
            return try lines(try views.audit(AuditQuery(session: id)))
        default:
            if let result = try readFactStores(params.uri) { return result }
            if let result = try await readThread(params.uri) { return result }
            throw MCPError.invalidParams("Unknown resource: \(params.uri)")
        }
    }

    /// Whether `text` has the form of an audit event id: 16 lowercase hex characters.
    static func isEventID(_ text: Substring) -> Bool {
        text.count == 16 && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The reply's JSON as an MCP value, or the text itself if it does not parse (it always should:
    /// guided generation produced it).
    private static func parse(_ text: String) -> Value {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .string(text) }
        return Value(json: value)
    }

    /// A compact JSON rendering of MCP arguments for the audit log.
    private static func render(_ value: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds or creates the thread, runs the prompt, and reports the thread id, whether it was condensed,
    /// the gate's refusals, the turn's receipt, and its tool calls with their output inline or by reference
    /// (D9 of the layered-context proposal).
    private func respond(_ request: RespondRequest) async -> CallTool.Result {
        let id = request.threadID ?? UUID().uuidString.lowercased()
        let opened: ThreadRegistry<OpenThread>.Opened
        do {
            opened = try await threads.findOrCreate(id: id) {
                try makeThread(
                    session, host, id, request.instructions, request.tools, request.model)
            }
        } catch {
            return failure(String(describing: error))
        }
        if opened.created {
            directory.opened(
                id: id, model: opened.thread.model, tools: opened.thread.tools,
                instructions: request.instructions != nil)
        }
        if let evicted = opened.evicted {
            directory.ended(id: evicted.id, as: .evicted)
            evicted.thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "evicted"))
            Diagnostics.mcp.info("evicted thread \(evicted.id) to make room for \(id)")
        }
        if !opened.created, request.instructions != nil || request.tools != .all || request.model != nil {
            return failure("instructions, tools, and model apply only when a thread is created; \(id) already exists")
        }
        let schema: OutputSchema?
        do {
            schema = try request.schema.map { try OutputSchema(json: $0) }
        } catch {
            return failure(String(describing: error))
        }
        if let task = request.task {
            do {
                try await opened.thread.thread.setTask(task)
            } catch {
                return failure("could not set the task of \(id): \(error)")
            }
        }
        do {
            let reply = try await relaying(opened.thread.relay) {
                try await opened.thread.thread.respond(to: request.prompt, schema: schema)
            }
            let refusals = await opened.thread.gate.takeRefusals()
            let turn = opened.thread.audit.currentTurn
            directory.used(id: id, turns: turn)
            let events = opened.thread.receipts.takeEvents(turn: turn)
            let receipt = Receipt(events: events, turn: turn)
            let auditEnabled = config.auditEnabled
            let calls = TurnCalls(events: events, turn: turn).json(inlineBytes: config.inlineOutputBytes) {
                auditEnabled ? ToolCatalog.outputURI(thread: id, id: $0) : nil
            }
            return .init(
                content: [.text(text: reply.text, annotations: nil, _meta: nil)],
                structuredContent: .object([
                    "thread_id": .string(id), "created": .bool(opened.created), "condensed": .bool(reply.condensed),
                    "text": .string(reply.text),
                    "refusals": .array(
                        refusals.map { .object(["command": .string($0.command), "reason": .string($0.reason)]) }),
                    "receipt": Value(json: receipt.json), "calls": Value(json: calls),
                    "facts": Value(json: Self.turnFacts(reply.facts, thread: id)),
                    "notifications": Value(json: Self.notifications(in: events)),
                    "output": schema == nil ? .null : Self.parse(reply.text),
                    "contextNote": reply.contextNote.map { .string($0) } ?? .null,
                ]),
                isError: false
            )
        } catch LanguageModelError.contextSizeExceeded {
            return failure("thread \(id) has exhausted the model's context window; close it and start a new one")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// The notifications a turn posted, or tried to, from its `notification` events: MCP has no notification
    /// primitive, so the caller learns of them here (ADR 0046). Each is `{title, body, source, outcome,
    /// route, reason, time}`; `route` is null when nothing was posted, `reason` null when something was.
    ///
    /// - Parameter events: The turn's audit events.
    /// - Returns: The list, in order.
    static func notifications(in events: [AuditEvent]) -> JSONValue {
        .array(
            events.filter { $0.kind == .notification }.map { event in
                let d = event.details
                return .object([
                    "title": d["title"] ?? .null, "body": d["body"] ?? .null, "source": d["source"] ?? .null,
                    "outcome": d["outcome"] ?? .null, "route": d["route"] ?? .null, "reason": d["reason"] ?? .null,
                    "time": .string(event.time.ISO8601Format()),
                ])
            })
    }

    /// Captures the output on a conversation of its own (so the command, the file read, and every
    /// judging turn are audited under one session), judges it chunk by chunk, and returns the findings.
    private func triage(_ request: TriageRequest) async -> CallTool.Result {
        let id = "triage-" + ShortID.make()
        do {
            let thread = try session.thread(id: id, host: host, tools: .none, model: request.model)
            defer { thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed")) }
            let schema = try OutputSchema(json: Triage.schemaJSON)
            let makeAgent = makeTriageAgent
            let triage = Triage(options: .init(maxFindings: request.maxFindings)) { prompt in
                try await makeAgent(thread, nil).respond(to: prompt, schema: schema).text
            }
            let runner = CommandRunner(
                options: session.config.runner, audit: thread.audit, approval: thread.gate)
            let captured = try await triage.capture(request.source, runner: runner, gate: thread.gate)
            let report = try await triage.run(captured, from: request.source)
            let structured: Value? = Value(json: report.json)  // the typed init, not the throwing generic one
            return .init(
                content: [.text(text: report.rendered, annotations: nil, _meta: nil)], structuredContent: structured,
                isError: false)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Captures the diff on a conversation of its own, judges it chunk by chunk, and returns the summary.
    private func summariseDiff(_ request: SummariseDiffRequest) async -> CallTool.Result {
        let id = "summarise-" + ShortID.make()
        do {
            let thread = try session.thread(id: id, host: host, tools: .none, model: request.model)
            defer { thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed")) }
            let schema = try OutputSchema(json: DiffSummary.schemaJSON)
            let makeAgent = makeTriageAgent
            let summary = DiffSummary(options: .init(maxFiles: request.maxFiles)) { prompt in
                try await makeAgent(thread, nil).respond(to: prompt, schema: schema).text
            }
            let runner = CommandRunner(
                options: session.config.runner, audit: thread.audit, approval: thread.gate)
            let captured = try await summary.capture(request.source, runner: runner, gate: thread.gate)
            let report = try await summary.run(captured, from: request.source)
            let structured: Value? = Value(json: report.json)
            return .init(
                content: [.text(text: report.rendered, annotations: nil, _meta: nil)], structuredContent: structured,
                isError: false)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Captures the output on a conversation of its own, scans it, and returns the findings masked; the
    /// conversation records `secrets.scan` with the kinds found and never a value.
    private func scanSecrets(_ request: ScanSecretsRequest) async -> CallTool.Result {
        let routed = request.options.thorough ? secretsModel(explicit: request.model) : nil
        return await condense(prefix: "scan", source: request.source, model: routed?.model ?? request.model) {
            thread, captured in
            let text = captured.text
            if let routed {
                thread.audit.record(
                    .modelRouted,
                    details: AuditEvent.Details.modelRouted(
                        task: "secrets", inputBytes: text.utf8.count, decision: routed))
            }
            let judge = request.options.thorough ? self.judge(on: thread, schema: ModelSweep.schemaJSON) : nil
            let report = try await SecretScan(
                options: request.options, judge: judge, classifier: PersonalDataClassifier.shipped
            ).run(text, from: request.source)
            thread.audit.record(.secretScan, details: AuditEvent.Details.secretScan(report))
            return (report.rendered, report.json)
        }
    }

    /// Captures the output on a conversation of its own and returns it redacted; the conversation records
    /// `redaction` with the counts replaced.
    private func redact(_ request: RedactRequest) async -> CallTool.Result {
        let routed = request.options.thorough ? secretsModel(explicit: request.model) : nil
        return await condense(prefix: "redact", source: request.source, model: routed?.model ?? request.model) {
            thread, captured in
            let text = captured.text
            if let routed {
                thread.audit.record(
                    .modelRouted,
                    details: AuditEvent.Details.modelRouted(
                        task: "secrets", inputBytes: text.utf8.count, decision: routed))
            }
            let judge = request.options.thorough ? self.judge(on: thread, schema: ModelSweep.schemaJSON) : nil
            let report = try await Redaction(options: request.options, judge: judge).run(text, from: request.source)
            thread.audit.record(.redaction, details: AuditEvent.Details.redaction(report))
            return (report.summary + "\n\n" + report.text, report.json)
        }
    }

    /// The model for a thorough scan or redaction when the caller named none: the `secrets` task
    /// default; nil when the caller named one.
    private func secretsModel(explicit: ModelSelection?) -> ModelRouting.Decision? {
        ModelRouting.forTask("secrets", explicit: explicit, models: config.taskModels)
    }

    /// Summarises the diff per file, then drafts from the summary, on one conversation `draft-<id>`.
    private func draftChange(_ request: DraftChangeRequest) async -> CallTool.Result {
        await condense(prefix: "draft", source: request.source, model: request.model) { thread, captured in
            let bytes = captured.text.utf8.count
            let routed = ChangeDraft.route(
                explicit: request.model, inputBytes: bytes, ladder: config.routingLadder,
                opens: { model in
                    do {
                        _ = try makeTriageAgent(thread, model)
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
            }
            let draft = try await ChangeDraft.draft(
                request.kind, from: captured, source: request.source,
                summarise: judge(on: thread, schema: DiffSummary.schemaJSON, model: routed?.model),
                write: judge(on: thread, schema: ChangeDraft.schemaJSON, model: routed?.model))
            var fields = draft.json.objectValue ?? [:]
            fields["model"] = .string((routed?.model ?? thread.model).description)
            fields["routing"] = routed.map { .string($0.reason) } ?? .null
            return (draft.text, .object(fields))
        }
    }

    /// Digests a log, or reads a crash report, without a model: a command's output or a file through the
    /// usual capture, or the unified log read in process.
    private func condenseLog(_ request: CondenseLogRequest) async -> CallTool.Result {
        let digest: @Sendable (Triage.Captured) -> (text: String, json: JSONValue) = { captured in
            if let crash = CrashReport(captured.text) { return (crash.rendered, crash.json) }
            let report = LogDigest(options: .init(maxGroups: request.maxGroups)).run(captured.text)
            var fields = report.json.objectValue ?? [:]
            fields["truncated"] = .bool(captured.truncated)
            let note = captured.truncated ? "\n(input cut to its last \(CondenseLogRequest.maxBytes) bytes)" : ""
            return (report.rendered + note, .object(fields))
        }
        switch request.origin {
        case .captured(let source):
            return await condense(prefix: "log", source: source, model: nil, maxBytes: CondenseLogRequest.maxBytes) {
                _, captured in digest(captured)
            }
        case .unified(let query):
            do {
                let thread = try session.thread(
                    id: "log-" + ShortID.make(), host: host, tools: .none)
                defer {
                    thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed"))
                }
                let read = try UnifiedLog.read(query, maxBytes: CondenseLogRequest.maxBytes)
                let result = digest(Triage.Captured(text: read.text, truncated: read.truncated))
                let structured: Value? = Value(json: result.json)
                return .init(
                    content: [.text(text: result.text, annotations: nil, _meta: nil)], structuredContent: structured,
                    isError: false)
            } catch {
                return failure(String(describing: error))
            }
        }
    }

    /// Outlines a JSON document or JSON Lines without a model; input cut to fit is refused, since a
    /// document without its head does not parse.
    private func jsonShape(_ request: JSONShapeRequest) async -> CallTool.Result {
        await condense(
            prefix: "shape", source: request.source, model: nil, maxBytes: JSONShapeRequest.maxBytes
        ) { _, captured in
            guard !captured.truncated else {
                throw JSONShape.Failure.notJSON("larger than \(JSONShapeRequest.maxBytes) bytes; narrow it first")
            }
            let report = try JSONShape(options: request.options).run(captured.text)
            return (report.rendered, report.json)
        }
    }

    /// A dependency audit reduced without a model. The audit's own non-zero exit is how it says it found
    /// something, so it is not flagged as a failed command.
    private func dependencyAudit(_ source: Triage.Source) async -> CallTool.Result {
        await condense(
            prefix: "deps", source: source, model: nil, maxBytes: JSONShapeRequest.maxBytes, flagFailure: false
        ) { _, captured in
            guard !captured.truncated else {
                throw DependencyAudit.Failure.unrecognised("larger than \(JSONShapeRequest.maxBytes) bytes")
            }
            let report = try DependencyAudit().run(captured.text)
            return (report.rendered, report.json)
        }
    }

    /// A profile's folded stacks reduced to hot paths without a model.
    private func hotPaths(_ source: Triage.Source) async -> CallTool.Result {
        await condense(prefix: "profile", source: source, model: nil, maxBytes: CondenseLogRequest.maxBytes) {
            _, captured in
            let report = try HotPaths().run(captured.text)
            return (report.rendered, report.json)
        }
    }

    /// Test runs compared for flaky tests without a model: saved runs read through the gate, or a command
    /// run several times in one conversation, so an approval given for the first run covers the rest.
    private func flakyTests(_ request: FlakyTestsRequest) async -> CallTool.Result {
        do {
            let thread = try session.thread(id: "flaky-" + ShortID.make(), host: host, tools: .none)
            defer { thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed")) }
            let runner = CommandRunner(
                options: session.config.runner, audit: thread.audit, approval: thread.gate)
            let sources: [Triage.Source]
            switch request.runs {
            case .paths(let paths): sources = paths.map { .path($0) }
            case .command(let source, let count): sources = Array(repeating: source, count: count)
            }
            var outputs: [String] = []
            for source in sources {
                let captured = try await Triage.capture(
                    source, runner: runner, gate: thread.gate, maxOutputBytes: CondenseLogRequest.maxBytes)
                outputs.append(captured.text)
            }
            let report = try FlakyTests().run(outputs)
            let structured: Value? = Value(json: report.json)
            return .init(
                content: [.text(text: report.rendered, annotations: nil, _meta: nil)], structuredContent: structured,
                isError: false)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Opens a conversation `<prefix>-<id>` with no tools, captures `source` through its runner and gate,
    /// and hands the capture to `body`, which returns the text and structured content of the result.
    /// The result always carries the command's exit status; with `flagFailure`, a command that exits
    /// non-zero also gets a warning ahead of the result.
    private func condense(
        prefix: String, source: Triage.Source, model: ModelSelection?,
        maxBytes: Int = Triage.Options().maxOutputBytes, flagFailure: Bool = true,
        _ body: (WispThread, Triage.Captured) async throws -> (text: String, json: JSONValue)
    ) async -> CallTool.Result {
        do {
            let thread = try session.thread(
                id: "\(prefix)-" + ShortID.make(), host: host, tools: .none, model: model)
            defer { thread.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed")) }
            let runner = CommandRunner(
                options: session.config.runner, audit: thread.audit, approval: thread.gate)
            let result = try await relaying(thread.relay) {
                let captured = try await Triage.capture(
                    source, runner: runner, gate: thread.gate, maxOutputBytes: maxBytes)
                return Self.withExitStatus(try await body(thread, captured), of: captured, warn: flagFailure)
            }
            let structured: Value? = Value(json: result.json)
            return .init(
                content: [.text(text: result.text, annotations: nil, _meta: nil)], structuredContent: structured,
                isError: false)
        } catch {
            return failure(String(describing: error))
        }
    }

    /// A condensing result with the command's exit status and timeout added, and a warning ahead of the
    /// text when the command failed: a failing command's output is usually its error message, which a
    /// condenser would otherwise report as an empty diff or a one-line log.
    static func withExitStatus(
        _ result: (text: String, json: JSONValue), of captured: Triage.Captured, warn: Bool = true
    ) -> (text: String, json: JSONValue) {
        guard let status = captured.exitStatus else { return result }
        var fields = result.json.objectValue ?? [:]
        fields["exitStatus"] = .int(Int(status))
        fields["timedOut"] = .bool(captured.timedOut)
        guard warn, status != 0 || captured.timedOut else { return (result.text, .object(fields)) }
        let why = captured.timedOut ? "timed out" : "exited \(status)"
        let head = captured.text.split(separator: "\n").first.map { ": \($0.prefix(200))" } ?? ""
        return (
            "warning: the command \(why), so this may describe its error rather than its output\(head)\n\n"
                + result.text, .object(fields)
        )
    }

    /// A judge that answers each prompt in a fresh turn on `conversation`, shaped by `schema`, on `model`
    /// when routing chose one and the conversation's own otherwise.
    private func judge(on thread: WispThread, schema: JSONValue, model: ModelSelection? = nil) -> Triage.Judge {
        let makeAgent = makeTriageAgent
        return { prompt in
            try await makeAgent(thread, model).respond(to: prompt, schema: try OutputSchema(json: schema)).text
        }
    }

    /// Moves a fact of the thread, or a session fact, to `thread` or `session` on behalf of the caller
    /// (`fact.scope.changed`, `by: caller`); a thread that is not open, an unknown fact, or a fact already
    /// there are tool errors.
    private func setFactScope(_ request: SetFactScopeRequest) async -> CallTool.Result {
        guard let open = await threads.peek(request.threadID) else {
            return failure("no open thread \(request.threadID); respond starts one")
        }
        do {
            let fact = try await open.thread.setFactScope(request.factID, to: request.scope)
            let rows = Self.turnFacts([fact], thread: request.threadID).arrayValue ?? []
            return .init(
                content: [
                    .text(
                        text: "moved \(request.factID) to \(request.scope.rawValue)"
                            + (fact.id == request.factID ? "" : " as \(fact.id)"), annotations: nil, _meta: nil)
                ],
                structuredContent: .object([
                    "thread_id": .string(request.threadID), "from": .string(request.factID),
                    "fact": Value(json: rows.first ?? .null),
                ]), isError: false)
        } catch {
            return failure("\(error)")
        }
    }

    /// Frees a thread; unknown ids are tool errors.
    private func closeThread(_ request: CloseThreadRequest) async -> CallTool.Result {
        do {
            let closed = try await threads.close(request.threadID)
            directory.ended(id: request.threadID, as: .closed)
            closed.audit.record(.sessionEnd, details: AuditEvent.Details.sessionEnd(reason: "closed"))
            return success("closed \(request.threadID)")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// A text result with `isError: false`.
    private func success(_ text: String) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    }

    /// A text result with `isError: true`, the MCP shape for execution failures.
    private func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }
}

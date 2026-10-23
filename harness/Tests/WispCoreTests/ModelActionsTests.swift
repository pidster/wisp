import Foundation
import Synchronization
import Testing
import WispTestSupport

@testable import WispCore

/// A puller over a repository held in memory, for `ModelActions` without a network or the Hugging Face cache
/// (ADR 0059): its plan says what it is told, its fetch reports progress and, when `blocks`, waits until it is
/// cancelled, and its link records whether it was told to replace a directory.
final class FakePuller: ModelPuller {
    /// Why a fetch failed.
    struct NetworkDropped: Error, CustomStringConvertible, Equatable {
        var description: String { "the network dropped" }
    }

    /// Why a name was refused.
    struct NotAllowed: Error, CustomStringConvertible, Equatable {
        let text: String
        var description: String { "'\(text)' is not a Hugging Face repository" }
    }

    let missing: Int
    let remaining: Int
    let licence: String?
    let replacesDirectory: Bool
    let blocks: Bool
    /// Whether the fetch fails (the network dropped) after reporting its first progress.
    let fails: Bool
    /// Each repository prepared, in order.
    let prepared = Guarded<[String]>([])
    /// Each link's `replacingDirectory`, in order.
    let linked = Guarded<[Bool]>([])

    init(
        missing: Int = 2, remaining: Int = 2_000_000_000, licence: String? = "apache-2.0",
        replacesDirectory: Bool = false, blocks: Bool = false, fails: Bool = false
    ) {
        self.fails = fails
        self.missing = missing
        self.remaining = remaining
        self.licence = licence
        self.replacesDirectory = replacesDirectory
        self.blocks = blocks
    }

    func repository(_ text: String) throws -> (repository: String, name: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy(TrustedPublishers.isHubName) else { throw NotAllowed(text: text) }
        return (text, parts[1])
    }

    func prepare(
        _ text: String, session: Session, notice: @escaping @Sendable (String) -> Void
    ) async throws
        -> PreparedPull
    {
        let (repository, name) = try repository(text)
        prepared.update { $0.append(repository) }
        notice("checking weights.safetensors against the listing's SHA-256")
        let summary = PullSummary(
            repository: repository, name: name, revision: "0123456789ab", licence: licence, files: 3,
            bytes: remaining + 1000, missing: missing, remaining: remaining, destination: "/models/\(name)",
            snapshot: "/hub/\(name)", replacesDirectory: replacesDirectory, reused: 3 - missing, seeded: 0,
            lines: ["\(repository) at 0123456789ab: 3 files"])
        let (missing, remaining, blocks, fails, linked) = (missing, remaining, blocks, fails, linked)
        return PreparedPull(
            summary: summary,
            fetch: { progress, notice in
                guard missing > 0 else { return 0 }
                progress(
                    PullProgress(
                        repository: repository, file: "weights.safetensors", size: remaining, index: 1,
                        files: missing, fetched: remaining / 4, total: remaining))
                if fails { throw NetworkDropped() }
                if blocks {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    throw CancellationError()
                }
                notice("resuming weights.safetensors")
                progress(
                    PullProgress(
                        repository: repository, file: "weights.safetensors", size: remaining, index: 1,
                        files: missing, fetched: remaining, total: remaining))
                return remaining
            },
            link: { replacing in
                linked.update { $0.append(replacing) }
                return ("created", "/models/\(name) links to the snapshot. Use it as --model mlx:\(name)")
            })
    }
}

@Suite struct ModelActionsTests {
    /// A temporary home with `config` and the session a face would run in.
    struct Place {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-actions-\(UUID().uuidString)")
        let sink = MemoryAuditSink()
        var home: Home { Home(root: root) }

        init(config: String? = nil) throws {
            try Home(root: root).ensure()
            if let config { try Data(config.utf8).write(to: Home(root: root).configFile) }
        }

        /// A session of `entryPoint` pulling with `puller`.
        func session(_ entryPoint: EntryPoint = .chat, puller: (any ModelPuller)? = FakePuller()) throws -> Session {
            var dependencies = Session.Dependencies.testing(sink: sink)
            dependencies.puller = puller
            return try Session.begin(.init(entryPoint: entryPoint), home: home, dependencies: dependencies)
        }

        /// The events of `kind`.
        func events(_ kind: AuditEvent.Kind) -> [AuditEvent] { sink.events.filter { $0.kind == kind } }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A face's dialog that answers from a script and keeps what it was shown and asked.
    final class Script: Sendable {
        let answer: PublisherCheck.Answer
        let yes: Bool
        let shown = Mutex<[String]>([])
        let asked = Mutex<[String]>([])
        let steps = Mutex<[PullProgress]>([])

        init(answer: PublisherCheck.Answer = .refuse, yes: Bool = false) {
            self.answer = answer
            self.yes = yes
        }

        func dialog(interactive: Bool = true, stop: CommandStop? = nil) -> PullDialog {
            PullDialog(
                interactive: interactive, show: { line in self.shown.withLock { $0.append(line) } },
                notice: { line in self.shown.withLock { $0.append(line) } },
                publisher: { summary in
                    self.asked.withLock { $0.append("publisher \(summary.publisher)") }
                    return self.answer
                },
                confirm: { question in
                    self.asked.withLock { $0.append(question) }
                    return self.yes
                }, progress: { step in self.steps.withLock { $0.append(step) } }, stop: stop)
        }
    }

    @Test func eachActionDeclaresWhatItTouchesAndWhetherTheModelMayAskForIt() {
        typealias Action = ModelActions.Action
        #expect(
            Action.allCases.map(\.rawValue) == [
                "list", "show", "pull", "trust", "enable", "disable", "check", "switch", "uninstall",
            ])
        #expect(Action.allCases.filter(\.forModel) == [.list, .show, .pull, .enable, .disable, .check])
        #expect(Action.allCases.filter(\.asksPerson) == [.pull, .enable, .disable, .check])
        #expect(Action.list.changes == nil && Action.show.changes == nil)
        #expect(Action.allCases.allSatisfy { !$0.reads.isEmpty })
        #expect(Action.pull.remembered == .once && Action.enable.remembered == .session)
        #expect(Action.check.remembered == .session && Action.trust.remembered == nil)
        // The gate holds a model's request to these scopes.
        #expect(ApprovalRequest.Kind.modelAction(pull: true).scopes == [.once])
        #expect(ApprovalRequest.Kind.modelAction(pull: false).scopes == [.once, .session])
        #expect(ApprovalRequest.Kind.command.scopes == ApprovalScope.allCases)
    }

    @Test func thePersonsPullPutsThePublisherQuestionAndRecordsWhatWasDecided() async throws {
        let place = try Place()
        defer { place.remove() }
        let actions = ModelActions(session: try place.session(), face: .chat)
        // Refused, the default: nothing fetched, recorded as declined from chat.
        let refusing = Script(answer: .refuse)
        let refused = try await actions.pull("ornith-ai/q", dialog: refusing.dialog())
        #expect(refused.outcome == .declined && refused.fetched == 0)
        #expect(refusing.asked.withLock { $0 } == ["publisher ornith-ai"])
        #expect(refusing.shown.withLock { $0 }.contains("Nothing fetched."))
        let publisher = try #require(place.events(.modelPublisher).last)
        #expect(publisher.details["decision"] == "refused" && publisher.details["source"] == "chat")
        #expect(Set(publisher.details.keys) == AuditEvent.fields(for: .modelPublisher))
        let declined = try #require(place.events(.modelPull).last)
        #expect(declined.details["outcome"] == "declined" && declined.details["source"] == "chat")
        #expect(declined.details["approval"] == .null)
        #expect(Set(declined.details.keys) == AuditEvent.fields(for: .modelPull))
        // Once: the answer approves the download, so it is not asked again; the progress reaches the face.
        let once = Script(answer: .once)
        let fetched = try await actions.pull("ornith-ai/q", dialog: once.dialog())
        #expect(fetched.outcome == .fetched && fetched.fetched == 2_000_000_000 && fetched.selection == "mlx:q")
        #expect(once.asked.withLock { $0 } == ["publisher ornith-ai"])
        #expect(once.steps.withLock { $0 }.map(\.fetched) == [500_000_000, 2_000_000_000])
        #expect(once.steps.withLock { $0 }.first?.line == "pulling ornith-ai/q: 500 MB of 2 GB, file 1 of 2")
        #expect(once.shown.withLock { $0 }.contains("/models/q links to the snapshot. Use it as --model mlx:q"))
        #expect(once.shown.withLock { $0 }.contains("resuming weights.safetensors"))
        let pull = try #require(place.events(.modelPull).last)
        #expect(pull.details["outcome"] == "fetched" && pull.details["link"] == "created")
        #expect(pull.details["fetched"] == .int(2_000_000_000) && pull.details["model"] == "mlx:q")
        // A trusted publisher is not asked about; the download is, and no refuses it.
        let trusted = Script(answer: .once, yes: false)
        let no = try await actions.pull("mlx-community/q", dialog: trusted.dialog())
        #expect(no.outcome == .declined)
        #expect(trusted.asked.withLock { $0 } == ["Fetch 2 of them, 2 GB?"])
        #expect(place.events(.modelPublisher).last?.details["decision"] == "trusted")
    }

    @Test func trustingFromThePullsQuestionAddsThePublisherAndARealDirectoryStaysUnlessThePersonAgrees() async throws {
        let place = try Place()
        defer { place.remove() }
        let puller = FakePuller(replacesDirectory: true)
        let actions = ModelActions(session: try place.session(puller: puller), face: .chat)
        let script = Script(answer: .trust, yes: false)
        let result = try await actions.pull("ornith-ai/q", dialog: script.dialog())
        #expect(result.outcome == .fetched)
        #expect(script.shown.withLock { $0 }.contains("ornith-ai is trusted from now on (mlx.trustedPublishers)."))
        #expect(script.asked.withLock { $0 }.last?.hasPrefix("/models/q is a directory of its own") == true)
        #expect(puller.linked.value == [false])
        let change = try #require(place.events(.configChange).last)
        #expect(change.details["path"] == "mlx.trustedPublishers" && change.details["source"] == "chat")
        #expect(place.events(.modelPublisher).last?.details["decision"] == "trust")
    }

    @Test func aPullWhereNobodyCanBeAskedIsRefusedBeforeAnyRequest() async throws {
        let place = try Place()
        defer { place.remove() }
        let puller = FakePuller()
        let actions = ModelActions(session: try place.session(.models, puller: puller), face: .cli)
        let script = Script(answer: .once, yes: true)
        await #expect(throws: PublisherCheck.Refusal(repository: "ornith-ai/q", publisher: "ornith-ai")) {
            try await actions.pull("ornith-ai/q", dialog: script.dialog(interactive: false))
        }
        await #expect(throws: ModelActions.Failure.notInteractive) {
            try await actions.pull("mlx-community/q", dialog: script.dialog(interactive: false))
        }
        await #expect(throws: FakePuller.NotAllowed(text: "../q")) {
            try await actions.pull("../q", dialog: script.dialog())
        }
        #expect(puller.prepared.value.isEmpty)
        // The model's face has its own pull, through the gate; a build that pulls nothing says so.
        await #expect(throws: ModelActions.Failure.notForTheModel("pull")) {
            try await ModelActions(session: try place.session(puller: puller), face: .tool).pull(
                "mlx-community/q", dialog: script.dialog())
        }
        let none = ModelActions(session: try place.session(puller: nil), face: .chat)
        if ModelPullers.current == nil {
            await #expect(throws: ModelActions.Failure.noPuller) {
                try await none.pull("mlx-community/q", dialog: script.dialog())
            }
        }
    }

    @Test func aStoppedPullKeepsWhatArrivedAndIsRecordedAsCancelled() async throws {
        let place = try Place()
        defer { place.remove() }
        let actions = ModelActions(session: try place.session(puller: FakePuller(blocks: true)), face: .chat)
        let script = Script(answer: .once)
        let stop = CommandStop()
        let stopper = Task {
            try await eventually("the fetch to start") { !script.steps.withLock { $0 }.isEmpty }
            stop.request()
        }
        let result = try await actions.pull("ornith-ai/q", dialog: script.dialog(stop: stop))
        try await stopper.value
        #expect(result.outcome == .cancelled && result.fetched == 500_000_000 && result.closing == nil)
        let pull = try #require(place.events(.modelPull).last)
        #expect(pull.details["outcome"] == "cancelled" && pull.details["fetched"] == .int(500_000_000))
        #expect(pull.details["reason"]?.stringValue?.contains("kept") == true)
    }

    @Test func trustAndSwitchAreThePersonsAlone() throws {
        let place = try Place(config: #"{"models": {"disabled": ["ollama:off"]}}"#)
        defer { place.remove() }
        let session = try place.session()
        let chat = ModelActions(session: session, face: .chat)
        #expect(try chat.trust("ornith-ai").hasPrefix("ornith-ai is trusted from now on"))
        #expect(try chat.trust("ornith-ai") == "ornith-ai is trusted already")
        #expect(try chat.trust("mlx-community") == "mlx-community is trusted already")
        #expect(throws: ModelActions.Failure.notAPublisher("../x")) { try chat.trust("../x") }
        #expect(
            try ConfigEdit.current(TrustedPublishers.setting, in: Data(contentsOf: place.home.configFile))
                == ["mlx-community", "ornith-ai"])
        let tool = ModelActions(session: session, face: .tool)
        #expect(throws: ModelActions.Failure.notForTheModel("trust")) { try tool.trust("other") }
        #expect(ModelActions.Failure.notForTheModel("trust").description.contains("/models trust"))
        // A switch is checked against the disabled models under any spelling, and is not the model's.
        #expect(try chat.switchTarget("ollama:on") == .ollama("on"))
        #expect(throws: ModelSelection.Failure.self) { try chat.switchTarget("ollama:off") }
        #expect(throws: ModelActions.Failure.notForTheModel("switch")) { try tool.switchTarget("ollama:on") }
    }

    @Test func showFindsAModelUnderAnySpellingAndSaysWhenItIsNotListed() async throws {
        let place = try Place()
        defer { place.remove() }
        var actions = ModelActions(session: try place.session(), face: .chat)
        actions.listing = { _ in .init(entries: [.init(selection: .ollama("q:latest"), capabilities: ["toolCalling"])])
        }
        #expect(try await actions.show("ollama:q:latest", tools: []).selection == .ollama("q:latest"))
        await #expect(throws: ModelActions.Failure.unknownModel("ollama:other")) {
            try await actions.show("ollama:other", tools: [])
        }
    }
}

/// `/models pull`, `/models trust`, `/models cancel`, and the picker's "pull a model…" row in chat (ADR 0059): through
/// the chat's model actions, with the publisher question as the face's choice dialog and Ctrl-C stopping the fetch.
@Suite struct ChatModelPullTests {
    private func agent() -> Agent {
        Agent(
            instructions: "x", tools: [], model: ResolvedModel(selection: .system, custom: ScriptedModel(steps: [])))
    }

    @Test func aPullInChatAsksThePublisherInTheChoiceDialogAndShowsItsProgress() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-pull-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = MemoryAuditSink()
        let actions = try ChatLoopTests.actions(dir, listing: .init(entries: []), puller: FakePuller(), sink: sink)
        let activity = ChatActivity()
        let doing = Mutex<[String]>([])
        activity.onChange { state in if let state { doing.withLock { $0.append(state.doing) } } }
        let asked = Mutex<[ChatChoice]>([])
        let capture = ChatLoopTests.Capture(lines: ["/models pull ornith-ai/q", "/models trust ornith-ai", "/quit"])
        var io = capture.io
        io.choose = { choice in
            asked.withLock { $0.append(choice) }
            return "once"
        }
        var loop = ChatLoop(
            agent: agent(),
            context: .init(
                directory: "/r", approval: "--yes", models: actions, activity: activity, interrupt: ChatInterrupt()),
            io: io)
        try await loop.run()
        // The question's lines are notes; the answer is a choice whose default is to refuse.
        #expect(
            capture.noted.contains("  Publisher:   ornith-ai") && capture.noted.contains("  Licence:     apache-2.0"))
        let question = try #require(asked.withLock { $0 }.first)
        #expect(question.title == "ornith-ai is not a trusted publisher: pull ornith-ai/q?")
        #expect(question.options.map(\.value) == ["refuse", "once", "trust"] && question.current == "refuse")
        #expect(PublisherCheck.Answer(typed: question.current) == .refuse)
        // The progress was the activity, which a face shows in its status line.
        #expect(doing.withLock { $0 }.contains("pulling ornith-ai/q: 500 MB of 2 GB, file 1 of 2"))
        #expect(activity.current == nil)
        #expect(capture.noted.contains("/models/q links to the snapshot. Use it as --model mlx:q"))
        #expect(sink.events.last { $0.kind == .modelPull }?.details["source"] == "chat")
        // /models trust names the setting.
        #expect(capture.noted.contains { $0.hasPrefix("ornith-ai is trusted from now on (mlx.trustedPublishers)") })
    }

    @Test func ctrlCStopsAPullInChatAndKeepsWhatArrived() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let actions = try ChatLoopTests.actions(
            dir, listing: .init(entries: []), puller: FakePuller(blocks: true))
        let activity = ChatActivity()
        let interrupt = ChatInterrupt()
        let capture = ChatLoopTests.Capture(lines: ["/models pull mlx-community/q", "/quit"])
        var io = capture.io
        io.choose = { _ in "yes" }
        let presser = Task {
            try await eventually("the pull to be stoppable") { activity.current?.stoppable == true }
            #expect(interrupt.press() == .stopping("models pull mlx-community/q"))
        }
        var loop = ChatLoop(
            agent: agent(),
            context: .init(
                directory: "/r", approval: "--yes", models: actions, activity: activity, interrupt: interrupt),
            io: io)
        try await loop.run()
        try await presser.value
        #expect(
            capture.noted.contains(
                "stopped the pull of mlx-community/q after 500 MB; what arrived is kept, and /models pull "
                    + "mlx-community/q resumes it"))
        #expect(interrupt.running == nil && activity.current == nil)
    }

    @Test func thePickersPullRowAsksForARepositoryAndPullsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-chat-row-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let puller = FakePuller(missing: 0, remaining: 0)
        let actions = try ChatLoopTests.actions(
            dir, listing: .init(entries: [.init(selection: .system, capabilities: ["toolCalling"])]), puller: puller)
        let asked = Mutex<[ChatChoice]>([])
        let capture = ChatLoopTests.Capture(lines: ["/models", "/models cancel", "/quit"])
        var io = capture.io
        io.choose = { choice in
            asked.withLock { $0.append(choice) }
            return choice.toggles ? ModelTable.pullRow : "mlx-community/q"
        }
        var loop = ChatLoop(
            agent: agent(), context: .init(directory: "/r", approval: "--yes", models: actions), io: io)
        try await loop.run()
        let choices = asked.withLock { $0 }
        let row = try #require(choices.first?.options.last)
        #expect(row.value == ModelTable.pullRow && row.action && row.on == nil && row.label == "pull a model…")
        #expect(choices.count == 2 && choices[1].acceptsText && choices[1].options.isEmpty)
        #expect(puller.prepared.value == ["mlx-community/q"])
        #expect(capture.noted.contains("/models/q links to the snapshot. Use it as --model mlx:q"))
        // Nothing runs in the background, so a cancel says so.
        #expect(capture.noted.contains("no pull is running"))
        // The row's protocol form carries `action`, and no `on`.
        let fields = ChatProtocol.choice(id: "c", try #require(choices.first))
        let last = try #require(fields["options"]?.arrayValue?.last?.objectValue)
        #expect(last["action"] == true && last["on"] == nil)
    }
}

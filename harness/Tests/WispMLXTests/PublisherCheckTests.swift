import Foundation
import Synchronization
import Testing
import WispCore

@testable import WispMLX

/// Pulling from any publisher, one outside `mlx.trustedPublishers` confirmed by the person first (ADR 0052, amended
/// 2026-10-09): without the network (the fake Hub), the real cache, or a terminal (scripted answers), in a temporary
/// home whose `config.json` and audit the tests read back.
@Suite struct PublisherCheckTests {
    /// A temporary home, cache, and models directory, and the session a pull would run in.
    struct Place {
        let root: URL
        let sink = MemoryAuditSink()
        var home: Home { Home(root: root.appending(path: "home", directoryHint: .isDirectory)) }
        var cache: HubCache { HubCache(root: root.appending(path: "hub", directoryHint: .isDirectory)) }
        var models: URL { root.appending(path: "models", directoryHint: .isDirectory) }

        init(config: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "wisp-publisher-\(UUID().uuidString)")
            try Home(root: root.appending(path: "home", directoryHint: .isDirectory)).ensure()
            if let config { try Data(config.utf8).write(to: home.configFile) }
        }

        /// A session over the home, as `wisp models pull` begins one; each loads `config.json` afresh.
        func session() throws -> Session {
            try Session.begin(.init(entryPoint: .models), home: home, dependencies: .testing(sink: sink))
        }

        /// The plan for `repository` against a fake Hub serving the test repository with `card`.
        func plan(_ repository: String, card: [String: JSONValue] = [:]) async throws -> ModelPull.Plan {
            let hub = FakeHub(files: ModelPullTests.repository, card: card)
            return try await ModelPull(hub: ModelPullTests.hubURL, transport: hub, cache: cache).plan(
                repository, into: models)
        }

        /// `config.json`'s `mlx.trustedPublishers`, nil when unset or when there is no file.
        var trustedInFile: JSONValue? {
            (try? ConfigEdit.current(
                TrustedPublishers.setting, in: FileManager.default.contents(atPath: home.configFile.path))) ?? nil
        }

        /// The `model.publisher` events recorded.
        var decisions: [AuditEvent] { sink.events.filter { $0.kind == .modelPublisher } }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// Answers the question with `answer`, keeping the lines it was shown.
    final class Asker: Sendable {
        let answer: String?
        let shown = Mutex<[[String]]>([])

        init(_ answer: String?) { self.answer = answer }

        func ask(_ lines: [String]) -> String? {
            shown.withLock { $0.append(lines) }
            return answer
        }

        var asked: Bool { shown.withLock { !$0.isEmpty } }
        var lines: [String] { shown.withLock { $0.first ?? [] } }
    }

    @Test func aTrustedPublisherIsPulledWithoutAsking() async throws {
        let place = try Place(config: #"{"mlx": {"trustedPublishers": ["ornith-ai"]}}"#)
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        for repository in ["mlx-community/q", "ornith-ai/q"] {
            let screened = try check.screen(repository, interactive: false)
            #expect(screened == .trusted, "\(repository)")
            let asker = Asker("o")
            let plan = try await place.plan(repository)
            #expect(try check.settle(plan, screened: screened, ask: asker.ask) == .trusted)
            #expect(!asker.asked)
        }
        // mlx-community is trusted with no file at all, and with a list that leaves it out.
        let bare = try Place()
        defer { bare.remove() }
        #expect(
            try PublisherCheck(session: try bare.session(), trustFlag: false, source: "cli").screen(
                "mlx-community/q", interactive: false) == .trusted)
        let decision = try #require(place.decisions.last)
        #expect(decision.details["decision"] == "trusted" && decision.details["asked"] == false)
        #expect(decision.details["publisher"] == "ornith-ai" && decision.details["source"] == "cli")
        #expect(Set(decision.details.keys) == AuditEvent.fields(for: .modelPublisher))
    }

    @Test func anUntrustedPublisherIsAskedAndRefusedByDefault() async throws {
        let place = try Place()
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        #expect(try check.screen("ornith-ai/q", interactive: true) == nil)
        let plan = try await place.plan("ornith-ai/q", card: ["cardData": ["license": "apache-2.0"]])
        for answer in ["", "n", "no", "yes", "y", "maybe", nil] as [String?] {
            let asker = Asker(answer)
            #expect(try check.settle(plan, screened: nil, ask: asker.ask) == .refused, "\(answer ?? "end of input")")
            #expect(asker.asked)
        }
        #expect(place.trustedInFile == nil)
        #expect(!FileManager.default.fileExists(atPath: place.home.configFile.path))
        let decision = try #require(place.decisions.last)
        #expect(decision.details["decision"] == "refused" && decision.details["asked"] == true)
        #expect(decision.details["licence"] == "apache-2.0" && decision.details["bytes"] == .int(plan.remaining))
        #expect(!PublisherCheck.Decision.refused.pulls)
    }

    @Test func pullingOnceLeavesTheSettingAsItWas() async throws {
        let place = try Place()
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        let plan = try await place.plan("ornith-ai/q")
        for answer in ["o", " Once "] {
            #expect(try check.settle(plan, screened: nil, ask: Asker(answer).ask) == .once)
        }
        #expect(PublisherCheck.Decision.once.pulls && PublisherCheck.Decision.once.approvedDownload)
        #expect(place.trustedInFile == nil)
        #expect(place.sink.events.allSatisfy { $0.kind != .configChange })
        // The next pull asks again.
        let next = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        #expect(try next.screen("ornith-ai/q", interactive: true) == nil)
        #expect(place.decisions.last?.details["decision"] == "once")
    }

    @Test func trustingAddsThePublisherAndTheNextPullDoesNotAsk() async throws {
        let place = try Place(config: #"{"approval": {"timeoutSeconds": 30}}"#)
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        let plan = try await place.plan("ornith-ai/q")
        #expect(try check.settle(plan, screened: nil, ask: Asker("t").ask) == .trust)
        #expect(place.trustedInFile == ["mlx-community", "ornith-ai"])
        // The rest of the file is kept, and the change is recorded as any config change is.
        #expect(
            try ConfigEdit.current(
                "approval.timeoutSeconds", in: FileManager.default.contents(atPath: place.home.configFile.path)) == 30)
        let change = try #require(place.sink.events.last { $0.kind == .configChange })
        #expect(change.details["path"] == "mlx.trustedPublishers" && change.details["source"] == "cli")
        #expect(change.details["old"] == .null && change.details["new"] == ["mlx-community", "ornith-ai"])
        #expect(place.decisions.last?.details["decision"] == "trust")
        // The next session reads the setting, and the publisher is no longer asked about.
        let next = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        #expect(try next.screen("ornith-ai/q", interactive: false) == .trusted)
        // Trusting it again changes nothing.
        #expect(try place.session().trustPublisher("ornith-ai", source: "cli") == nil)
        #expect(place.sink.events.filter { $0.kind == .configChange }.count == 1)
    }

    @Test func theFlagPullsOnceWithoutTheQuestion() async throws {
        let place = try Place()
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: true, source: "cli")
        // Without a terminal too: the flag answers the publisher question, not the download question.
        let screened = try check.screen("ornith-ai/q", interactive: false)
        #expect(screened == .flag)
        let asker = Asker("t")
        #expect(try check.settle(try await place.plan("ornith-ai/q"), screened: screened, ask: asker.ask) == .flag)
        #expect(!asker.asked && place.trustedInFile == nil)
        #expect(PublisherCheck.Decision.flag.pulls && !PublisherCheck.Decision.flag.approvedDownload)
        #expect(place.decisions.last?.details["decision"] == "flag")
        #expect(place.decisions.last?.details["asked"] == false)
    }

    @Test func noTerminalAndNoFlagRefusesWithTheGuidanceBeforeAnyRequest() throws {
        let place = try Place()
        defer { place.remove() }
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        #expect(throws: PublisherCheck.Refusal(repository: "ornith-ai/q", publisher: "ornith-ai")) {
            try check.screen("ornith-ai/q", interactive: false)
        }
        let text = PublisherCheck.Refusal(repository: "ornith-ai/q", publisher: "ornith-ai").description
        #expect(text.contains("--trust-publisher") && text.contains("mlx.trustedPublishers"))
        #expect(text.contains(#"wisp config set mlx.trustedPublishers '["mlx-community","ornith-ai"]'"#))
        let decision = try #require(place.decisions.last)
        #expect(decision.details["decision"] == "refused" && decision.details["asked"] == false)
        #expect(decision.details["reason"] == "no terminal" && decision.details["licence"] == .null)
        #expect(decision.details["bytes"] == .null)
        #expect(Set(decision.details.keys) == AuditEvent.fields(for: .modelPublisher))
    }

    @Test func theQuestionNamesThePublisherRepositoryLicenceAndSize() async throws {
        let place = try Place()
        defer { place.remove() }
        let plan = try await place.plan("ornith-ai/q", card: ["cardData": ["license": "apache-2.0"]])
        let lines = PublisherCheck.question(for: plan)
        let size = ModelPull.Failure.size(plan.remaining)
        #expect(lines.contains("  Publisher:   ornith-ai"))
        #expect(lines.contains("  Repository:  ornith-ai/q"))
        #expect(lines.contains("  Licence:     apache-2.0"))
        #expect(lines.contains("  Download:    \(size) in 4 of 4 files, \(size) in all"))
        #expect(lines.last?.hasSuffix("refuse [N]? ") == true)
        // The asker sees the same lines.
        let asker = Asker(nil)
        let check = PublisherCheck(session: try place.session(), trustFlag: false, source: "cli")
        _ = try check.settle(plan, screened: nil, ask: asker.ask)
        #expect(asker.lines == lines)
    }

    @Test func anUnknownLicenceAndNothingToDownloadAreSaid() async throws {
        let place = try Place()
        defer { place.remove() }
        var plan = try await place.plan("ornith-ai/q")
        #expect(PublisherCheck.question(for: plan).contains("  Licence:     unknown"))
        plan.reused = plan.files.map(\.path)
        #expect(
            PublisherCheck.question(for: plan).contains(
                "  Download:    nothing (every file is already on this Mac), \(ModelPull.Failure.size(plan.bytes)) in all"
            ))
    }

    @Test func theAnswersAreOnceTrustOrRefuse() {
        #expect(PublisherCheck.Answer(typed: "o") == .once && PublisherCheck.Answer(typed: "ONCE") == .once)
        #expect(PublisherCheck.Answer(typed: "t") == .trust && PublisherCheck.Answer(typed: " trust ") == .trust)
        for refusing in ["", "n", "N", "y", "yes", "ok", "trusted", nil] as [String?] {
            #expect(PublisherCheck.Answer(typed: refusing) == .refuse, "\(refusing ?? "nil")")
        }
    }
}

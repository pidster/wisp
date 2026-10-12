import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// A pull that fails, and the words around the ones that do not finish: the failure recorded and thrown for the
/// person, posted as a note for the model, a declined pull's note, and the model's refusal to pull or trust through
/// the change request.
@Suite struct ModelPullFailureTests {
    /// A pull whose fetch fails is recorded as failed with the reason and thrown, not taken for a stop.
    @Test func aFailedPullIsRecordedAndThrownToThePerson() async throws {
        let place = try ModelActionsTests.Place()
        defer { place.remove() }
        let actions = ModelActions(session: try place.session(puller: FakePuller(fails: true)), face: .chat)
        let script = ModelActionsTests.Script(answer: .once)
        await #expect(throws: FakePuller.NetworkDropped()) {
            try await actions.pull("ornith-ai/q", dialog: script.dialog())
        }
        let pull = try #require(place.events(.modelPull).last)
        #expect(pull.details["outcome"] == "failed" && pull.details["reason"] == "the network dropped")
        #expect(pull.details["fetched"] == .int(0))
    }

    /// A dialog made without a progress callback ignores progress and a pull still ends.
    @Test func aDialogWithoutAProgressCallbackStillPulls() async throws {
        let place = try ModelActionsTests.Place()
        defer { place.remove() }
        let actions = ModelActions(session: try place.session(puller: FakePuller()), face: .chat)
        let dialog = PullDialog(
            interactive: true, show: { _ in }, notice: { _ in }, publisher: { _ in .once }, confirm: { _ in false })
        let result = try await actions.pull("ornith-ai/q", dialog: dialog)
        #expect(result.outcome == .fetched)
    }

    /// A pull the model asked for that fails after approval posts a note naming the approval and the reason, and
    /// says what arrived is kept.
    @Test func aBackgroundPullThatFailsPostsANoteWithTheReason() async throws {
        let approver = ModelsToolTests.Answering([.approved(.once)])
        let place = try ModelsToolTests.Place(puller: FakePuller(fails: true), approver: approver)
        defer { place.remove() }
        let reply = await place.tool().call(arguments: .init(action: "pull", name: "mlx-community/q", page: nil))
        #expect(reply.hasPrefix("pulling mlx-community/q in the background"))
        await place.session.modelPulls.wait(for: "mlx-community/q")
        let notes = place.session.notices.take(for: "t")
        let note = try #require(notes.first { $0.contains("failed") })
        #expect(note.contains("the network dropped") && note.contains("a pull asked for again resumes it"))
        #expect(note.contains("(approval "))
        #expect(place.events(.modelPull).last?.details["outcome"] == "failed")
    }

    /// The note for a declined pull says so, and the model cannot ask for a pull or trust through a change request.
    @Test func aDeclinedPullsNoteAndTheModelsRefusedActions() async throws {
        let result = PullResult(
            outcome: .declined, repository: "ornith-ai/q", selection: "mlx:q", fetched: 0, closing: nil)
        #expect(
            ModelActions.note(result, approval: "ab12")
                == "[wisp: the pull of ornith-ai/q you asked for (approval ab12) was declined]")
        let place = try ModelsToolTests.Place(approver: ModelsToolTests.Answering([]))
        defer { place.remove() }
        var actions = ModelActions(session: place.session, face: .tool, audit: place.log)
        actions.listing = { _ in ModelListing.Listing(entries: [], unreachable: []) }
        let refused = await actions.requestChange(
            .pull, "mlx-community/q", gate: place.gate, workingDirectory: "/tmp")
        #expect(refused.hasPrefix("error: ") && refused.contains("pull"))
        let trust = await actions.requestChange(.trust, "ornith-ai", gate: place.gate, workingDirectory: "/tmp")
        #expect(trust.hasPrefix("error: "))
    }
}

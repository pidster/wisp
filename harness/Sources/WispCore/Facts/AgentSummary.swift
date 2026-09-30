import Foundation
import FoundationModels

extension Agent {
    /// Whether the turns condensing drops are summarised in the earlier block (`ContextComposer.summarises`); on
    /// by default, and only an agent that keeps facts writes a summary.
    public var summarises: Bool {
        get { composer.summarises }
        set {
            composer.summarises = newValue
            refreshFacts(quietly: true)
        }
    }

    /// The share of the context window the running summary may take (`ContextComposer.summaryShare`).
    public var summaryShare: Double {
        get { composer.summaryShare }
        set {
            composer.summaryShare = newValue
            refreshFacts(quietly: true)
        }
    }

    /// How many dropped turns wait for the summary (`ContextComposer.summaryBatchTurns`).
    public var summaryBatchTurns: Int {
        get { composer.summaryBatchTurns }
        set { composer.summaryBatchTurns = newValue }
    }

    /// What a condensation hands on before it drops `leaving`: the facts in the prose of those turns
    /// (`distil(_:staying:)`) and, when the batch is due, a new version of the running summary covering them and
    /// the turns dropped before them that it does not cover yet. With `FactSettings.summaryWithFacts`, both
    /// come from one call; otherwise the summary has a call of its own after the facts'. Nothing here fails
    /// the turn.
    ///
    /// - Parameters:
    ///   - leaving: The store entries a condensation is about to drop.
    ///   - staying: The entries it keeps.
    nonisolated(nonsending) func handOn(_ leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry]) async {
        guard let batch = summaryBatch(leaving: leaving) else {
            await distil(leaving, staying: staying)
            return
        }
        if let facts, facts.distils, facts.summaryWithFacts {
            await distilAndSummarise(batch, leaving: leaving, staying: staying)
        } else {
            await distil(leaving, staying: staying)
            await summarise(batch)
        }
    }

    /// The entries the next summary covers when it is due: the prompts, tool calls, and replies of the turns
    /// dropped earlier and not yet summarised, then of `leaving`, in order; nil when the agent keeps no facts,
    /// summarising is off, or they come to fewer than `summaryBatchTurns` turns.
    ///
    /// - Parameter leaving: The store entries a condensation is about to drop.
    /// - Returns: The batch, or nil.
    func summaryBatch(leaving: [ThreadRecord.Entry]) -> [ThreadRecord.Entry]? {
        guard facts != nil, composer.summarises else { return nil }
        let narrative: Set<ThreadRecord.Kind> = [.prompt, .toolCalls, .response]
        let batch = (store.unsummarised + leaving.filter { narrative.contains($0.kind) }).sorted { $0.id < $1.id }
        guard FactDistiller.turns(in: batch).count >= max(1, composer.summaryBatchTurns) else { return nil }
        return batch
    }

    /// The summary's cap and the turns' input budget for this agent's window.
    private var summaryBounds: (capBytes: Int, budgetBytes: Int) {
        let window = contextSize ?? Self.assumedWindow
        return (
            SummaryWriter.capBytes(share: composer.summaryShare, window: window),
            min(12_000, window * ContextComposer.bytesPerToken / 3)
        )
    }

    /// Writes a new version of the running summary from the one before and `batch`, with one call to the
    /// conversation's model in a session of its own, and records it in the store. Audited as `context.summary`;
    /// on a failure, or an empty answer, the summary stays as it was and the batch waits for the next one.
    ///
    /// - Parameter batch: The entries to add (`summaryBatch(leaving:)`).
    nonisolated(nonsending) func summarise(_ batch: [ThreadRecord.Entry]) async {
        let turns = FactDistiller.turns(in: batch)
        let (cap, budget) = summaryBounds
        let prompt = SummaryWriter.prompt(
            previous: store.summary, turns: turns, calls: SummaryWriter.calls(in: batch), budgetBytes: budget,
            capBytes: cap)
        let started = Date()
        var failure: String?
        do {
            let session = model.session(tools: [], instructions: SummaryWriter.instructions)
            let answer = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    samplingMode: .greedy, maximumResponseTokens: cap / ContextComposer.bytesPerToken * 2)
            ).content
            failure = keepSummary(answer, batch: batch, turns: turns, capBytes: cap)
        } catch {
            failure = "\(error)"
        }
        auditSummary(
            turns: turns, entries: batch.count, bytes: prompt.utf8.count, started: started, combined: false,
            failure: failure)
    }

    /// Distils facts from `batch` and writes the running summary in one call (`SummaryWriter.Combined`), and
    /// records both. Audited as `context.distillation` and `context.summary`, each with the call's time; a
    /// failure is audited on both, no fact is recorded, and the summary stays as it was.
    ///
    /// - Parameters:
    ///   - batch: The entries the summary adds (`summaryBatch(leaving:)`), whose prose the facts come from too.
    ///   - leaving: The entries the condensation drops.
    ///   - staying: The entries it keeps, whose prompts are shown for the latest values.
    nonisolated(nonsending) private func distilAndSummarise(
        _ batch: [ThreadRecord.Entry], leaving: [ThreadRecord.Entry], staying: [ThreadRecord.Entry]
    ) async {
        guard let facts else { return }
        let turns = FactDistiller.turns(in: batch)
        let (cap, budget) = summaryBounds
        let prompt = FactDistiller.prompt(
            turns: turns, kinds: facts.kinds, existing: factView.groups.map(\.key), budgetBytes: budget,
            later: FactDistiller.turns(in: staying),
            summary: FactDistiller.SummaryRequest(
                previous: store.summary, calls: SummaryWriter.calls(in: batch), words: SummaryWriter.words(for: cap)))
        let prose = batch.filter { $0.kind == .prompt || $0.kind == .response }
        let started = Date()
        var recorded: [String] = []
        var failure: String?
        var unsummarised: String?
        do {
            try model.checkGuidedGeneration()
            let session = model.session(tools: [], instructions: SummaryWriter.combinedInstructions)
            let answer = try await session.respond(
                to: prompt, generating: SummaryWriter.Combined.self,
                options: GenerationOptions(
                    samplingMode: .greedy,
                    maximumResponseTokens: FactDistiller.maximumResponseTokens + cap / ContextComposer.bytesPerToken * 2
                )
            ).content
            let assertions = FactDistiller.assertions(
                from: answer.facts, kinds: facts.kinds, turns: turns, entries: prose.map(\.id),
                audit: prose.flatMap(\.sources), turn: self.turns.current, time: Date())
            recorded = assertions.compactMap { record($0)?.id }
            unsummarised = keepSummary(answer.summary, batch: batch, turns: turns, capBytes: cap)
        } catch {
            failure = "\(error)"
            Diagnostics.agent.error("distilling and summarising \(turns.count) turn(s) failed: \(error)")
        }
        let seconds = Date().timeIntervalSince(started)
        audit?.record(
            .distillation,
            details: AuditEvent.Details.distillation(
                turns: turns.map(\.number), entries: prose.count, bytes: prompt.utf8.count, facts: recorded,
                seconds: seconds, model: model.selection, failure: failure))
        auditSummary(
            turns: turns, entries: batch.count, bytes: prompt.utf8.count, started: started, combined: true,
            failure: failure ?? unsummarised)
    }

    /// Records `answer`, fitted to `capBytes`, as the next version of the running summary covering `batch`.
    ///
    /// - Parameters:
    ///   - answer: The model's summary.
    ///   - batch: The entries it adds.
    ///   - turns: Their turns.
    ///   - capBytes: The cap.
    /// - Returns: Why nothing was recorded, or nil when a version was.
    private func keepSummary(
        _ answer: String, batch: [ThreadRecord.Entry], turns: [FactDistiller.Turn], capBytes: Int
    ) -> String? {
        let text = SummaryWriter.fitted(answer, capBytes: capBytes)
        guard !text.isEmpty else { return "the model wrote no summary" }
        let previous = store.summary
        store.summarise(
            RunningSummary(
                version: (previous?.version ?? 0) + 1, text: text, covered: (previous?.covered ?? 0) + turns.count,
                turns: turns.map(\.number), entries: batch.map(\.id), audit: batch.flatMap(\.sources),
                through: batch.map(\.id).max() ?? previous?.through ?? 0, recorded: Date(), turn: self.turns.current,
                model: model.selection.description))
        return nil
    }

    /// Records the `context.summary` event for a summary call that started at `started`.
    ///
    /// - Parameters:
    ///   - turns: The turns it was to add.
    ///   - entries: How many entries they came to.
    ///   - bytes: The prompt's size.
    ///   - started: When the call began.
    ///   - combined: Whether the call also distilled facts.
    ///   - failure: Why no version was recorded, or nil.
    private func auditSummary(
        turns: [FactDistiller.Turn], entries: Int, bytes: Int, started: Date, combined: Bool, failure: String?
    ) {
        if let failure { Diagnostics.agent.error("summarising \(turns.count) turn(s) failed: \(failure)") }
        let summary = failure == nil ? store.summary : nil
        audit?.record(
            .summary,
            details: AuditEvent.Details.summary(
                version: summary?.version, turns: turns.map(\.number), entries: entries, bytes: bytes,
                covered: summary?.covered, summaryBytes: summary?.text.utf8.count,
                seconds: Date().timeIntervalSince(started), model: model.selection, combined: combined,
                failure: failure))
    }
}

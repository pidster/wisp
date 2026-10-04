import Foundation
import FoundationModels
import Synchronization

/// wisp's check of what a model can do, for a runtime that does not report it (MLX), run when the person enables
/// the model or asks for a check ([ADR 0056](../../../../docs/decisions/0056-models-enabled-and-disabled.md), refined
/// 2026-10-04). ADR 0019's rule stands: a capability is recorded only once verified, and here wisp verifies it on
/// the model itself. Three short questions, one attempt each, greedy, each within a time limit: a plain reply (the
/// floor: a model that cannot give one can hold no conversation, and nothing is recorded), a call of one trivial
/// tool with a given argument (`toolCalling`), and a small schema reply (`guidedGeneration`). `reasoning` and
/// `vision` are not checked.
public enum ModelVerification {
    /// One of the questions.
    public enum Probe: String, CaseIterable, Sendable {
        /// A plain reply: the floor.
        case reply
        /// One call of `record_word` with the word asked for.
        case toolCalling
        /// A reply that decodes to a two-field schema.
        case guidedGeneration

        /// The capability it verifies; nil for the floor, which verifies none.
        public var capability: CapabilityName? {
            switch self {
            case .reply: nil
            case .toolCalling: .toolCalling
            case .guidedGeneration: .guidedGeneration
            }
        }

        /// Its name in the person's words.
        public var label: String {
            switch self {
            case .reply: "reply"
            case .toolCalling: "tool calling"
            case .guidedGeneration: "structured reply"
            }
        }

        /// The capabilities the model is resolved with for this question: the one it tries, or none.
        var declared: [CapabilityName] { capability.map { [$0] } ?? [] }

        /// The most tokens the model may write in answer: enough for the answer, little enough to stay short.
        var maximumTokens: Int {
            switch self {
            case .reply: 64
            case .toolCalling, .guidedGeneration: 128
            }
        }
    }

    /// What a check means for the model, as the audit records it (`outcome`).
    public enum Outcome: String, Sendable {
        /// The reply failed: it cannot hold a conversation, nothing is recorded, and enable keeps it disabled.
        case refused
        /// The reply passed and tool calling did not: usable only with tools off.
        case textOnly = "text only"
        /// The reply and tool calling passed: usable in chat and by agents.
        case usable

        /// The outcome of `decision`, nil when the floor failed.
        init(_ decision: Decision?) {
            guard let decision else {
                self = .refused
                return
            }
            self = decision.capabilities.contains(CapabilityName.toolCalling.rawValue) ? .usable : .textOnly
        }
    }

    /// The capabilities no question checks, and why, for the person.
    public static let unchecked: [CapabilityName] = [.reasoning, .vision]

    /// The note saying what is not checked.
    public static let uncheckedNote =
        "reasoning and vision are not checked: one short question cannot tell them reliably; "
        + "declare them in config.json if the model has them"

    /// How long each question may take. The first loads the weights as well, so it has longer.
    public struct Limits: Equatable, Sendable {
        /// The floor, the first question, which loads the weights.
        public var first: Duration
        /// Each of the others.
        public var each: Duration

        /// Creates limits.
        public init(first: Duration, each: Duration) {
            self.first = first
            self.each = each
        }

        /// Three minutes for the first, one for each other: a 1.7B model at 4 bits loads and answers in seconds on
        /// this Mac (measured 2026-10-04), and the limits leave room for a model tens of times larger.
        public static let standard = Limits(first: .seconds(180), each: .seconds(60))

        /// The limit for `probe`.
        func limit(for probe: Probe) -> Duration { probe == .reply ? first : each }
    }

    /// What one question found.
    public struct Result: Equatable, Sendable {
        /// The question.
        public var probe: Probe
        /// Whether it passed.
        public var passed: Bool
        /// What came back, or why it failed, in a few words.
        public var detail: String
        /// How long it took.
        public var seconds: Double

        /// Creates a result.
        public init(probe: Probe, passed: Bool, detail: String, seconds: Double) {
            self.probe = probe
            self.passed = passed
            self.detail = detail
            self.seconds = seconds
        }

        /// The line the person sees as it arrives, such as `tool calling: passed in 1.2 s`.
        public var line: String {
            let time = String(format: "%.1f s", seconds)
            return passed ? "\(probe.label): passed in \(time)" : "\(probe.label): failed in \(time) (\(detail))"
        }

        /// The result as the audit records it.
        var json: JSONValue {
            .object([
                "check": .string(probe.rawValue), "passed": .bool(passed), "detail": .string(detail),
                "seconds": .double(seconds),
            ])
        }
    }

    /// What the results mean for the declaration: the capabilities to record and what the person is told.
    public struct Decision: Equatable, Sendable {
        /// The capabilities `config.json` records, in `CapabilityName` order.
        public var capabilities: [String]
        /// Capabilities the person declared by hand whose check failed, which are kept.
        public var kept: [String]
        /// Capabilities an earlier check recorded whose check failed now, which are taken out.
        public var removed: [String]
        /// The check, as `config.json` keeps it.
        public var check: Config.CapabilityCheck
    }

    /// Asks the questions, the floor first; when it fails the rest are not asked, since nothing will be recorded.
    ///
    /// - Parameters:
    ///   - limits: How long each may take.
    ///   - progress: Told each result as it arrives.
    ///   - resolve: Resolves the model with the given capabilities declared.
    /// - Returns: The results, in the order asked.
    public static func run(
        limits: Limits = .standard, progress: @Sendable (Result) -> Void,
        resolve: @escaping @Sendable ([CapabilityName]) throws -> ResolvedModel
    ) async -> [Result] {
        var results: [Result] = []
        for probe in Probe.allCases {
            let result = await ask(probe, limit: limits.limit(for: probe)) { try resolve(probe.declared) }
            results.append(result)
            progress(result)
            if probe == .reply, !result.passed { break }
        }
        return results
    }

    /// Asks one question within `limit`.
    ///
    /// - Parameters:
    ///   - probe: The question.
    ///   - limit: How long it may take.
    ///   - resolve: Resolves the model with the question's capability declared.
    /// - Returns: What it found.
    static func ask(
        _ probe: Probe, limit: Duration, resolve: @escaping @Sendable () throws -> ResolvedModel
    ) async -> Result {
        let started = ContinuousClock.now
        let outcome: (passed: Bool, detail: String)
        do {
            outcome = try await Timeout.run(limit) {
                let model = try resolve()
                return try await answer(probe, model: model)
            }
        } catch is Timeout.Failure {
            outcome = (false, "no answer within \(spoken(limit))")
        } catch {
            outcome = (false, "\(error)")
        }
        let elapsed = ContinuousClock.now - started
        return Result(
            probe: probe, passed: outcome.passed, detail: outcome.detail,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// The word the tool question asks the model to record.
    static let word = "heron"

    /// Asks `probe` of `model` once and judges the answer.
    ///
    /// - Returns: Whether it passed, and what came back or why not.
    /// - Throws: A failure of the floor or the schema reply; the tool question judges the call, not the reply.
    static func answer(_ probe: Probe, model: ResolvedModel) async throws -> (passed: Bool, detail: String) {
        let options = { (tokens: Int) in
            GenerationOptions(samplingMode: .greedy, temperature: 0, maximumResponseTokens: tokens)
        }
        switch probe {
        case .reply:
            let session = model.session(tools: [], instructions: "Answer in a few words.")
            let text = try await session.respond(to: "Say hello.", options: options(probe.maximumTokens)).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? (false, "the reply was empty") : (true, String(text.prefix(60)))
        case .toolCalling:
            let calls = WordProbe.Calls()
            let session = model.session(
                tools: [WordProbe(calls: calls)],
                instructions: "You have one tool, record_word. When asked to record a word, call it with that word.")
            var failure: String?
            do {
                _ = try await session.respond(
                    to: "Record the word \(word).", options: options(probe.maximumTokens))
            } catch {
                failure = "\(error)"
            }
            let words = calls.words.withLock { $0 }
            if words.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == word }) {
                return (true, "record_word(word: \(word))")
            }
            if let first = words.first { return (false, "record_word was called with '\(first)', not '\(word)'") }
            return (false, failure.map { "no call arrived: \($0)" } ?? "no call to record_word arrived")
        case .guidedGeneration:
            let session = model.session(tools: [], instructions: "Answer with the fields asked for.")
            let answer = try await session.respond(
                to: "Name a colour and a whole number from 1 to 10.", generating: ColourAndNumber.self,
                options: options(probe.maximumTokens)
            ).content
            return (true, "colour: \(answer.colour), number: \(answer.number)")
        }
    }

    /// What `results` mean for a model whose file declares `existing` now, or nil when the floor failed and nothing
    /// is recorded. A capability whose check passed is recorded. One whose check failed is taken out when an earlier
    /// check recorded it, and kept, and reported, when the person declared it by hand: wisp does not overrule the
    /// person's declaration, it tells them. A capability no question checks is kept as it was.
    ///
    /// - Parameters:
    ///   - results: The questions' results.
    ///   - existing: The model's declaration in the file now, or nil.
    ///   - date: The day of the check, `YYYY-MM-DD`.
    /// - Returns: The decision, or nil.
    public static func decide(_ results: [Result], existing: Config.MLXModelConfig?, date: String) -> Decision? {
        guard results.first(where: { $0.probe == .reply })?.passed == true else { return nil }
        let declared = existing?.capabilities ?? []
        let byHand = declared.filter { !(existing?.verified?.passed ?? []).contains($0) }
        let passed = results.filter(\.passed).compactMap { $0.probe.capability?.rawValue }
        let failed = results.filter { !$0.passed }.compactMap { $0.probe.capability?.rawValue }
        let kept = failed.filter { byHand.contains($0) }
        let removed = failed.filter { declared.contains($0) && !byHand.contains($0) }
        let recorded = Set(passed + declared.filter { !failed.contains($0) } + kept)
        return Decision(
            capabilities: CapabilityName.allCases.map(\.rawValue).filter { recorded.contains($0) }, kept: kept,
            removed: removed, check: Config.CapabilityCheck(date: date, passed: passed, failed: failed))
    }

    /// Today as `config.json` records a check's day, `YYYY-MM-DD` in the Mac's time zone.
    static func day(_ date: Date = Date()) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    /// A limit in the person's words: `300 ms`, `60 s`, `3 min`.
    static func spoken(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        if seconds == 0 { return "\(duration.components.attoseconds / 1_000_000_000_000_000) ms" }
        return seconds >= 120 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// The line said before the check starts: what will run, what it loads, and how long it may take.
    ///
    /// - Parameters:
    ///   - model: The model.
    ///   - bytes: Its weights' size, when known.
    ///   - limits: The time limits.
    /// - Returns: The line.
    static func announcement(_ model: ModelSelection, bytes: Int?, limits: Limits) -> String {
        let size = bytes.map { " (\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)))" } ?? ""
        return "checking \(model): loads the model\(size) and asks three short questions (a reply, a tool call, "
            + "a structured reply), allowing \(spoken(limits.first)) for the first, which loads it, and "
            + "\(spoken(limits.each)) for each of the others"
    }
}

/// The schema the structured-reply question asks for.
@Generable struct ColourAndNumber {
    /// A colour, in a word.
    @Guide(description: "A colour, in one word") var colour: String
    /// A whole number from 1 to 10.
    @Guide(description: "A whole number from 1 to 10") var number: Int
}

/// The one tool the tool-calling question offers: it records the words it is called with.
struct WordProbe: Tool {
    /// The words it was called with, shared with the question.
    final class Calls: Sendable {
        /// The words, in order.
        let words = Mutex<[String]>([])
    }

    /// The name the model calls.
    let name = "record_word"
    /// What the model is told it does.
    let description = "Records one word."
    /// Where the calls go.
    let calls: Calls

    /// The word to record.
    @Generable struct Arguments {
        /// The word.
        @Guide(description: "The word to record") var word: String
    }

    /// Records the word.
    ///
    /// - Parameter arguments: The word.
    /// - Returns: `recorded`.
    func call(arguments: Arguments) async -> String {
        calls.words.withLock { $0.append(arguments.word) }
        return "recorded"
    }
}

/// The declarations this session's own checks recorded, so the models they made usable can be chosen in this chat
/// at once, as `DisabledModels` holds the models it turned on and off (ADR 0056); other processes read them from
/// `config.json` from their next session.
public final class DeclaredModels: Sendable {
    /// The declarations, by model.
    private let declarations = Mutex<[ModelSelection: Config.MLXModelConfig]>([:])

    /// Creates an empty set.
    public init() {}

    /// Records `declaration` as `selection`'s.
    public func set(_ declaration: Config.MLXModelConfig, for selection: ModelSelection) {
        declarations.withLock { $0[selection] = declaration }
    }

    /// `config` with every declaration recorded here in place, through each model's backend.
    public func applied(to config: Config.Resolved) -> Config.Resolved {
        declarations.withLock { $0 }.reduce(config) { config, entry in
            guard case .local(let scheme, let name) = entry.key, let backend = ModelBackends.backend(for: scheme)
            else { return config }
            return backend.declaring(entry.value, for: name, in: config)
        }
    }
}

extension Session {
    /// Checks what models can do and records what passes (ADR 0056, refined 2026-10-04): for each model whose
    /// backend leaves its capabilities to `config.json` (MLX), and, unless `force`, only when the file declares none,
    /// says what will run, asks `ModelVerification`'s questions, shows each result, and writes the capabilities that
    /// passed, with the check, through `ConfigEdit`, recorded as `model.verified` and `config.change`; this session
    /// uses them at once. Enabling calls it without `force`, and the check decides the enabling, one of three
    /// outcomes: the reply fails and the model stays disabled, nothing recorded; the reply passes and tool calling
    /// fails, and it is enabled for use with tools off only, said plainly; or both pass and it is enabled and usable.
    /// `wisp models check` and `/models check` call it with `force`, and report and record without turning the model
    /// on or off.
    ///
    /// - Parameters:
    ///   - names: The models, as `--model` spells them.
    ///   - force: Whether to check a model the file already declares, replacing what an earlier check recorded.
    ///   - source: `chat` or `cli`, for the audit.
    ///   - limits: How long each question may take.
    ///   - now: The time of the check, for its day.
    ///   - progress: Told each line as it happens: the announcement and each result.
    /// - Returns: A line per model saying what was recorded, or why nothing was.
    /// - Throws: `ModelSelection.Failure` for a name that does not parse, `ConfigEdit.Failure` when the file would
    ///   not load, or the file system's.
    public func checkModels(
        _ names: [String], force: Bool, source: String, limits: ModelVerification.Limits = .standard,
        now: Date = Date(), progress: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        var lines: [String] = []
        for selection in try names.map({ try ModelSelection(parsing: $0) }) {
            guard case .local(let scheme, let name) = selection, let backend = ModelBackends.backend(for: scheme),
                let keys = backend.declarationKeys(for: name)
            else {
                if force { lines.append("\(selection): its runtime reports what it can do; there is nothing to check") }
                continue
            }
            let data = FileManager.default.contents(atPath: home.configFile.path)
            let existing = try ConfigEdit.current(keys: keys, in: data).flatMap(Self.declaration)
            if !force, existing?.capabilities != nil { continue }
            let config = declaredModels.applied(to: config)
            do {
                _ = try backend.resolve(name, config: config, home: home)
            } catch {
                lines.append(
                    !force && disabledModels.contains(selection)
                        ? "did not enable \(selection): it cannot be checked (\(error)); it stays disabled"
                        : "\(selection) cannot be checked: \(error)")
                continue
            }
            let bytes = try? await backend.installed(config: config, home: home).first { $0.selection == selection }?
                .bytes
            progress(ModelVerification.announcement(selection, bytes: bytes, limits: limits))
            let started = ContinuousClock.now
            let home = home
            let results = await ModelVerification.run(limits: limits, progress: { progress("  " + $0.line) }) {
                try backend.resolve(
                    name,
                    config: backend.declaring(.init(capabilities: $0.map(\.rawValue)), for: name, in: config),
                    home: home)
            }
            let elapsed = ContinuousClock.now - started
            let decision = ModelVerification.decide(results, existing: existing, date: ModelVerification.day(now))
            let outcome = ModelVerification.Outcome(decision)
            audit.record(
                .modelVerified,
                details: AuditEvent.Details.modelVerified(
                    model: selection.description, trigger: force ? "check" : "enable", outcome: outcome,
                    results: results, decision: decision,
                    seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
            guard let decision else {
                let reason = results.first.map { " (\($0.detail))" } ?? ""
                guard !force else {
                    lines.append("\(selection) cannot hold a conversation\(reason); nothing was recorded")
                    continue
                }
                // Enable refuses: the model stays, or becomes, disabled; it was unusable either way.
                do {
                    try setDisabled(selection, true, source: source)
                    lines.append("\(selection) cannot hold a conversation\(reason); it stays disabled")
                } catch ModelSelection.Failure.defaultDisabled {
                    lines.append(
                        "\(selection) cannot hold a conversation\(reason); it is the default model, so it cannot be "
                            + "disabled: make another model the default")
                }
                continue
            }
            var declaration = existing ?? Config.MLXModelConfig()
            declaration.capabilities = decision.capabilities
            declaration.verified = decision.check
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(declaration))
            let change = try ConfigEdit.set(keys: keys, to: value, in: data)
            try ConfigEdit.write(change, to: home.configFile)
            audit.record(.configChange, details: AuditEvent.Details.configChange(change, source: source))
            declaredModels.set(declaration, for: selection)
            if !force { try setDisabled(selection, false, source: source) }
            lines += Self.verdict(selection, decision: decision, enabling: !force)
        }
        return lines
    }

    /// A declaration read from the file, or nil when it is not one.
    private static func declaration(_ value: JSONValue) -> Config.MLXModelConfig? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(Config.MLXModelConfig.self, from: data)
    }

    /// What the person is told a check recorded.
    ///
    /// - Parameters:
    ///   - selection: The model.
    ///   - decision: What was recorded.
    ///   - enabling: Whether enable ran the check, so a usable model is said to be enabled.
    /// - Returns: The lines.
    static func verdict(
        _ selection: ModelSelection, decision: ModelVerification.Decision, enabling: Bool
    ) -> [String] {
        let words = ModelListing.Entry(selection: selection, capabilities: decision.capabilities).plainCapabilities
        var lines = [
            "recorded in config.json: \(selection) can do \(words.joined(separator: ", ")) "
                + "(verified \(decision.check.date))"
        ]
        if !decision.capabilities.contains(CapabilityName.toolCalling.rawValue) {
            lines.append(
                "\(selection) holds a conversation but did not call a tool; it is usable only with tools off: "
                    + "--no-tools, tools: [] over MCP, the condensers; chat and agents with tools refuse it")
        } else if enabling {
            lines.append("enabled \(selection)")
        }
        if !decision.kept.isEmpty {
            lines.append(
                "kept \(decision.kept.joined(separator: ", ")), which config.json declared by hand, though its check "
                    + "failed; remove it there if the model cannot")
        }
        if !decision.removed.isEmpty {
            lines.append(
                "took out \(decision.removed.joined(separator: ", ")): an earlier check passed it, this one did not")
        }
        lines.append(ModelVerification.uncheckedNote)
        return lines
    }
}

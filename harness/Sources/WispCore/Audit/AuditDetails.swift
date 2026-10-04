import Foundation

extension AuditEvent {
    /// Builds the `details` of each event kind, so every field name is spelled in exactly one place
    /// and `docs/logging.md` has one Swift file to agree with. `fields(for:)` is the documented set;
    /// a test checks every constructor against it.
    public enum Details {
        /// `session.start` for a session or an MCP thread. wisp's own system prompt is not repeated
        /// per event: it is fixed per `version`, which every event carries.
        public static func sessionStart(
            entryPoint: EntryPoint, prompting: Prompting, tools: [String], model: ModelSelection, unsafe: Bool,
            autoApprove: Bool, resume: String?, parent: String? = nil, carriedFrom: [String] = []
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "entryPoint": .string(entryPoint.rawValue),
                "systemPromptExtension": prompting.systemPromptExtension.map { .string($0) } ?? .null,
                "instructions": prompting.instructions.map { .string($0) } ?? .null,
                "tools": .array(tools.map { .string($0) }), "model": .string(model.description),
                "unsafe": .bool(unsafe), "autoApprove": .bool(autoApprove),
                "resume": resume.map { .string($0) } ?? .null,
            ]
            if let parent { details["parent"] = .string(parent) }
            if !carriedFrom.isEmpty { details["carriedFrom"] = .array(carriedFrom.map { .string($0) }) }
            return details
        }

        /// `session.start` with reason `new`: a chat `/new` on the same session.
        public static func sessionRestart(tools: [String], model: ModelSelection) -> [String: JSONValue] {
            ["reason": "new", "tools": .array(tools.map { .string($0) }), "model": .string(model.description)]
        }

        /// `model.resolved`: which model a conversation actually opened on, what it declared, and who
        /// declared it.
        public static func modelResolved(
            model: ModelSelection, backend: String, asset: String?, capabilities: [String],
            capabilitySource: CapabilitySource, tools: [String], contextSize: Int? = nil, contextNote: String? = nil
        ) -> [String: JSONValue] {
            [
                "model": .string(model.description), "backend": .string(backend),
                "asset": asset.map { .string($0) } ?? .null,
                "capabilities": .array(capabilities.map { .string($0) }),
                "capabilitySource": .string(capabilitySource.rawValue), "tools": .array(tools.map { .string($0) }),
                "contextSize": contextSize.map { .int($0) } ?? .null,
                "contextNote": contextNote.map { .string($0) } ?? .null,
            ]
        }

        /// `session.end`, with why for MCP threads.
        public static func sessionEnd(reason: String? = nil) -> [String: JSONValue] {
            reason.map { ["reason": .string($0)] } ?? [:]
        }

        /// `prompt`; `schema` is the caller's JSON Schema when the reply had to be shaped.
        public static func prompt(text: String, schema: JSONValue? = nil) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["text": .string(text)]
            if let schema { details["schema"] = schema }
            return details
        }

        /// `response`.
        public static func response(text: String, condensed: Bool, seconds: TimeInterval) -> [String: JSONValue] {
            ["text": .string(text), "condensed": .bool(condensed), "seconds": .double(seconds)]
        }

        /// `model.reasoning` as the model begins thinking within one request (ADR 0053): `phase` `start`, nothing
        /// else, so a face can show that it is thinking.
        public static func reasoningStarted() -> [String: JSONValue] {
            ["phase": "start"]
        }

        /// `model.reasoning` once the model has stopped thinking within one request (ADR 0053): `phase` `end`, the
        /// thinking verbatim as `text`, its size in `bytes`, its `tokens` as the runtime counted them, and the
        /// `seconds` it took. The text is the person's to read; it never enters the model's context.
        public static func reasoningEnded(text: String, tokens: Int, seconds: TimeInterval) -> [String: JSONValue] {
            [
                "phase": "end", "text": .string(text), "bytes": .int(text.utf8.count), "tokens": .int(tokens),
                "seconds": .double(seconds),
            ]
        }

        /// `tool.call`; `arguments` is the JSON the model produced.
        public static func toolCall(tool: String, arguments: String) -> [String: JSONValue] {
            ["tool": .string(tool), "arguments": .string(arguments)]
        }

        /// `tool.result`.
        public static func toolResult(tool: String, output: String, seconds: TimeInterval) -> [String: JSONValue] {
            [
                "tool": .string(tool), "output": .string(output), "bytes": .int(output.utf8.count),
                "seconds": .double(seconds),
            ]
        }

        /// How `policy.decision` came out.
        public enum PolicyVerdict: String, Sendable {
            /// Passed the patterns and the gate.
            case allowed
            /// Matched a deny pattern or no allow pattern.
            case denied
            /// The approval gate refused it.
            case disapproved
        }

        /// `policy.decision`.
        public static func policyDecision(
            command: String, workingDirectory: String, verdict: PolicyVerdict, reason: String?, sandbox: Bool,
            network: Bool, nested: Bool, origin: CommandRunner.Origin = .model
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "command": .string(command), "workingDirectory": .string(workingDirectory),
                "verdict": .string(verdict.rawValue), "sandbox": .bool(sandbox), "network": .bool(network),
                "nested": .bool(nested),
            ]
            if let reason { details["reason"] = .string(reason) }
            if origin == .person { details["origin"] = .string(origin.rawValue) }
            return details
        }

        /// `command.outcome`; `origin` is written only for a command the person typed.
        public static func commandOutcome(
            command: String, outcome: CommandRunner.Outcome, seconds: TimeInterval,
            origin: CommandRunner.Origin = .model
        )
            -> [String: JSONValue]
        {
            var details: [String: JSONValue] = [
                "command": .string(command), "exitStatus": .int(Int(outcome.exitStatus)),
                "timedOut": .bool(outcome.timedOut), "truncated": .bool(outcome.truncated),
                "stdout": .string(outcome.stdout), "stderr": .string(outcome.stderr), "seconds": .double(seconds),
            ]
            if origin == .person { details["origin"] = .string(origin.rawValue) }
            if let refusal = outcome.sandboxRefusal {
                details["sandboxRefusal"] = .string(refusal.name)
                if !refusal.paths.isEmpty { details["sandboxPaths"] = .array(refusal.paths.map { .string($0) }) }
            }
            return details
        }

        /// `command.typed`: a command the person typed in chat after `!` (ADR 0049), with what became of it.
        /// `verdict` is the policy's (`allowed` or `denied`, with its `reason`); for one that ran, its exit
        /// status, whether it timed out or lost output to the bound, whether the sandbox refused it or may have
        /// (`sandboxRefused`, with the check's `sandboxRefusal` and `sandboxPaths`, ADR 0054), and `output`, what it printed (stdout, then stderr) as the person is shown it, with its
        /// size in `bytes`. `failure` says why one that was allowed could not start.
        public static func commandTyped(
            command: String, workingDirectory: String, verdict: PolicyVerdict, reason: String? = nil,
            outcome: CommandRunner.Outcome? = nil, output: String = "", sandboxRefused: Bool = false,
            failure: String? = nil, seconds: TimeInterval
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "command": .string(command), "workingDirectory": .string(workingDirectory),
                "verdict": .string(verdict.rawValue), "output": .string(output), "bytes": .int(output.utf8.count),
                "seconds": .double(seconds),
            ]
            if let reason { details["reason"] = .string(reason) }
            if let failure { details["failure"] = .string(failure) }
            if let outcome {
                details["exitStatus"] = .int(Int(outcome.exitStatus))
                details["timedOut"] = .bool(outcome.timedOut)
                details["truncated"] = .bool(outcome.truncated)
                details["sandboxRefused"] = .bool(sandboxRefused)
                if let refusal = outcome.sandboxRefusal {
                    details["sandboxRefusal"] = .string(refusal.name)
                    if !refusal.paths.isEmpty { details["sandboxPaths"] = .array(refusal.paths.map { .string($0) }) }
                }
            }
            return details
        }

        /// `file.write`.
        public static func fileWrite(
            path: String, mode: String, created: Bool, bytesBefore: Int, bytesAfter: Int
        ) -> [String: JSONValue] {
            [
                "path": .string(path), "mode": .string(mode), "created": .bool(created),
                "bytesBefore": .int(bytesBefore), "bytesAfter": .int(bytesAfter),
            ]
        }

        /// `context.cut`: one stretch of a reply cut from later requests because it reproduced a tool output
        /// of its turn. `entry` and `output` are store ids; `response` and `result` the audit events that
        /// recorded the reply and the output; `tokens` estimates `bytes` at four bytes a token.
        public static func presentationCut(
            entry: Int, output: Int, tool: String, response: String?, result: String?, bytes: Int, tokens: Int,
            words: Int, coverage: Double
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "entry": .int(entry), "output": .int(output), "tool": .string(tool), "bytes": .int(bytes),
                "tokens": .int(tokens), "words": .int(words), "coverage": .double((coverage * 1000).rounded() / 1000),
            ]
            if let response { details["response"] = .string(response) }
            if let result { details["result"] = .string(result) }
            return details
        }

        /// `context.reference`: a stored tool output that requests now carry as a reference.
        public static func outputReferenced(
            entry: Int, tool: String, result: String?, bytes: Int, referenceBytes: Int, tokens: Int
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "entry": .int(entry), "tool": .string(tool), "bytes": .int(bytes),
                "referenceBytes": .int(referenceBytes), "tokens": .int(tokens),
            ]
            if let result { details["result"] = .string(result) }
            return details
        }

        /// `context.distillation`: the turns leaving the active view, distilled into facts by the model.
        public static func distillation(
            turns: [Int], entries: Int, bytes: Int, facts: [String], seconds: Double, model: ModelSelection,
            failure: String?
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "turns": .array(turns.map { .int($0) }), "entries": .int(entries), "bytes": .int(bytes),
                "facts": .array(facts.map { .string($0) }), "seconds": .double((seconds * 1000).rounded() / 1000),
                "model": .string(model.description),
            ]
            if let failure { details["failure"] = .string(failure) }
            return details
        }

        /// `context.summary`: a new version of the running summary of the turns condensing dropped, or why none
        /// was written.
        public static func summary(
            version: Int?, turns: [Int], entries: Int, bytes: Int, covered: Int?, summaryBytes: Int?, seconds: Double,
            model: ModelSelection, combined: Bool, failure: String?
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "turns": .array(turns.map { .int($0) }), "entries": .int(entries), "bytes": .int(bytes),
                "seconds": .double((seconds * 1000).rounded() / 1000), "model": .string(model.description),
                "combined": .bool(combined),
            ]
            if let version { details["version"] = .int(version) }
            if let covered { details["covered"] = .int(covered) }
            if let summaryBytes { details["summaryBytes"] = .int(summaryBytes) }
            if let failure { details["failure"] = .string(failure) }
            return details
        }

        /// `context.memory` for a recall: what one `memory` call restored for its turn, and where the content was
        /// read from.
        ///
        /// - Parameters:
        ///   - request: The call's `request`, as the model wrote it.
        ///   - target: What it was read as: `entry`, `turn`, `task`, `summary`, or `fact`.
        ///   - found: Whether anything was restored.
        ///   - entries: The store ids of the entries restored.
        ///   - facts: The ids of the facts restored.
        ///   - summaries: The versions of the running summary restored.
        ///   - events: The ids of the audit events content was read from.
        ///   - from: `audit` when every entry's content came from the audit log, `store` when every one came from
        ///     the thread record's copy, `audit+store` for a mix; nil when no entry content was restored.
        ///   - offset: The first line of the page.
        ///   - bytes: The result's UTF-8 bytes.
        /// - Returns: The details, with `action` `recall`.
        public static func memoryRecall(
            request: String, target: String, found: Bool, entries: [Int], facts: [String], summaries: [Int],
            events: [String], from: String?, offset: Int, bytes: Int
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "request": .string(request), "action": "recall", "target": .string(target), "found": .bool(found),
                "entries": .array(entries.map { .int($0) }), "facts": .array(facts.map { .string($0) }),
                "summaries": .array(summaries.map { .int($0) }), "events": .array(events.map { .string($0) }),
                "offset": .int(offset), "bytes": .int(bytes),
            ]
            if let from { details["from"] = .string(from) }
            return details
        }

        /// `context.memory` for a note: what the model noted, or why it was refused. A kept note is recorded as a
        /// `fact.recorded` (method `noted`) when its turn ends.
        ///
        /// - Parameters:
        ///   - request: The call's `request`, as the model wrote it.
        ///   - subject: The subject kind, when kept.
        ///   - name: The normalised name, when kept.
        ///   - value: The value as kept.
        ///   - temporalClass: The kind's class; `permanent` makes the fact a proposal.
        ///   - failure: Why it was refused (`shape`, `subject`, `name`, `off`, `full`), or nil when kept.
        /// - Returns: The details, with `action` `note` and `noted`.
        public static func memoryNote(
            request: String, subject: String?, name: String?, value: String?, temporalClass: TemporalClass?,
            failure: String?
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "request": .string(request), "action": "note", "noted": .bool(failure == nil),
            ]
            if let subject { details["subject"] = .string(subject) }
            if let name { details["name"] = .string(name) }
            if let value { details["value"] = .string(value) }
            if let temporalClass { details["class"] = .string(temporalClass.rawValue) }
            if let failure { details["failure"] = .string(failure) }
            return details
        }

        /// `context.memory` for the `task` verb: the task the model proposed, as kept, or why it was refused.
        public static func memoryTask(request: String, value: String?, failure: String?) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "request": .string(request), "action": "task", "noted": .bool(failure == nil),
            ]
            if let value { details["value"] = .string(value) }
            if let failure { details["failure"] = .string(failure) }
            return details
        }

        /// `context.assessment`: what one request's assessment decided (phase 4d, decision D12), and how. Never in the
        /// model's context; the eval relates its time to the tokens it saved and scores its choices.
        ///
        /// - Parameters:
        ///   - method: `rules`, `model`, `fallback`, or `retry`.
        ///   - tools: The tools chosen, in the agent's order.
        ///   - ruleTools: The tools the rules gave on their own.
        ///   - registered: The tools the request's session registers; nil for every tool.
        ///   - intent: The person's intent, as the model put it.
        ///   - task: The task fact recorded, when the assessment changed the task.
        ///   - facts: The facts repeated next to the request.
        ///   - seconds: How long it took.
        ///   - bytes: The model call's prompt, in bytes; 0 when no call was made.
        ///   - model: The model asked, when one was.
        ///   - failure: Why the call failed, or why the request was retried.
        /// - Returns: The details.
        public static func assessment(
            method: String, tools: [String], ruleTools: [String], registered: [String]?, intent: String?,
            task: String?, facts: [String], seconds: Double, bytes: Int, model: ModelSelection?, failure: String?
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "method": .string(method), "tools": .array(tools.map { .string($0) }),
                "ruleTools": .array(ruleTools.map { .string($0) }),
                "registered": registered.map { .array($0.map { .string($0) }) } ?? .string("all"),
                "taskChanged": .bool(task != nil), "facts": .array(facts.map { .string($0) }),
                "seconds": .double((seconds * 1000).rounded() / 1000), "bytes": .int(bytes),
            ]
            if let intent { details["intent"] = .string(intent) }
            if let task { details["task"] = .string(task) }
            if let model { details["model"] = .string(model.description) }
            if let failure { details["failure"] = .string(failure) }
            return details
        }

        /// `fact.recorded`: a new fact, or a new version of one, with what it superseded.
        public static func factRecorded(_ fact: Fact, supersedes: String?) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "id": .string(fact.id), "scope": .string(fact.identity.scope.rawValue),
                "subject": .string(fact.identity.subject), "name": .string(fact.identity.name),
                "source": .string(fact.source.rawValue), "version": .int(fact.version), "value": .string(fact.value),
                "class": .string(fact.temporalClass.rawValue), "method": .string(fact.method.rawValue),
                "entries": .array(fact.entries.map { .int($0) }),
                "sources": .array(fact.audit.map { .string($0.event) }),
            ]
            if let detail = fact.detail { details["detail"] = .string(detail) }
            if let supersedes { details["supersedes"] = .string(supersedes) }
            return details
        }

        /// `fact.superseded`: a fact replaced by a newer version from its source, or by its approval.
        public static func factSuperseded(_ fact: Fact, by other: String) -> [String: JSONValue] {
            [
                "id": .string(fact.id), "subject": .string(fact.identity.subject), "name": .string(fact.identity.name),
                "source": .string(fact.source.rawValue), "by": .string(other),
            ]
        }

        /// `fact.deleted`: a fact the person deleted.
        public static func factDeleted(_ fact: Fact) -> [String: JSONValue] {
            [
                "id": .string(fact.id), "subject": .string(fact.identity.subject), "name": .string(fact.identity.name),
                "source": .string(fact.source.rawValue), "value": .string(fact.value), "by": "person",
            ]
        }

        /// `fact.scope.changed`: a fact's scope was moved by command (chat's `/fact ID SCOPE`, MCP's
        /// `set_fact_scope`). `fact` is the id it was named by (`c3`, or `git/c3` for another conversation's
        /// proposal), `from` and `to` the scopes (`permanent`, `thread`, `session`), `by` who asked (`person` or
        /// `caller`), `now` the id it has after the move, and `proposed` whether it was a proposed permanent
        /// fact awaiting the person.
        public static func factScopeChanged(
            named id: String, before: Fact, after: Fact, to: FactTarget, by: FactSource, request: String? = nil
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "fact": .string(id), "from": .string(FactTarget(holding: before).rawValue),
                "to": .string(to.rawValue), "by": .string(by.rawValue), "now": .string(after.id),
                "subject": .string(after.identity.subject), "name": .string(after.identity.name),
                "source": .string(after.source.rawValue), "value": .string(after.value),
                "proposed": .bool(before.proposed),
            ]
            if let request { details["request"] = .string(request) }
            return details
        }

        /// `fact.conflict.raised` and `fact.conflict.resolved`: the heads about one subject and name began or
        /// stopped disagreeing.
        public static func factConflict(
            _ key: FactIdentity.Key, winner: String?, others: [String]
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "subject": .string(key.subject), "name": .string(key.name),
                "others": .array(others.map { .string($0) }),
            ]
            if let winner { details["winner"] = .string(winner) }
            return details
        }

        /// `context.condensation`.
        public static func condensation(
            turnsBefore: Int, turnsAfter: Int, contextSize: Int, tokenCount: Int, reason: String,
            saved: (before: String, after: String)? = nil
        )
            -> [String: JSONValue]
        {
            var details: [String: JSONValue] = [
                "turnsBefore": .int(turnsBefore), "turnsAfter": .int(turnsAfter), "contextSize": .int(contextSize),
                "tokenCount": .int(tokenCount), "reason": .string(reason),
            ]
            if let saved {
                details["savedBefore"] = .string(saved.before)
                details["savedAfter"] = .string(saved.after)
            }
            return details
        }

        /// What a condensation to a target adds to `context.condensation` (phase 5 of the layered-context
        /// proposal): the goal, the fill before and after, the headroom kept for the next turn, all in tokens, the
        /// steps in words, and `floor` only when the floor could not reach the goal.
        static func targeting(
            goal: Int, fillBefore: Int, fillAfter: Int, headroom: Int, steps: [String], floor: Bool
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "target": .int(goal), "fillBefore": .int(fillBefore), "fillAfter": .int(fillAfter),
                "headroom": .int(headroom), "steps": .array(steps.map { .string($0) }),
            ]
            if floor { details["floor"] = .bool(true) }
            return details
        }

        /// `mcp.request`; `arguments` is the call's JSON.
        public static func mcpRequest(tool: String, arguments: String) -> [String: JSONValue] {
            ["tool": .string(tool), "arguments": .string(arguments)]
        }

        /// `mcp.result`.
        public static func mcpResult(
            tool: String, isError: Bool, text: String, seconds: TimeInterval
        )
            -> [String: JSONValue]
        {
            ["tool": .string(tool), "isError": .bool(isError), "text": .string(text), "seconds": .double(seconds)]
        }

        /// `secrets.scan`: where, how much, and what kinds were found, never a value or a preview.
        public static func secretScan(_ report: SecretScan.Report) -> [String: JSONValue] {
            [
                "source": Condensing.json(report.source), "bytes": .int(report.bytes), "diff": .bool(report.diff),
                "thorough": .bool(report.chunks != nil), "findings": .int(report.findings.count),
                "kinds": .object(report.kinds.mapValues { .int($0) }),
                "failedChunks": .array(report.failedChunks.map { .int($0) }),
                "classifier": report.classifier.map { .string($0) } ?? .null,
            ]
        }

        /// `model.routed`: the model chosen for a task by its input's size, and why.
        public static func modelRouted(
            task: String, inputBytes: Int, decision: ModelRouting.Decision
        ) -> [String: JSONValue] {
            [
                "task": .string(task), "inputBytes": .int(inputBytes), "model": .string(decision.model.description),
                "reason": .string(decision.reason),
            ]
        }

        /// `watch.run`: one run of a watched command, how it ended, and whether it turned and notified.
        public static func watchRun(_ run: Watcher.Run, command: String) -> [String: JSONValue] {
            [
                "command": .string(command), "run": .int(run.number), "trigger": .string(run.trigger.rawValue),
                "exitStatus": run.exitStatus.map { .int(Int($0)) } ?? .null, "timedOut": .bool(run.timedOut),
                "state": .string(run.state.rawValue), "previous": run.previous.map { .string($0.rawValue) } ?? .null,
                "changed": .bool(run.changed), "seconds": .double(run.seconds),
                "findings": run.findings.map { .int($0.count) } ?? .null,
                "triageError": run.triageError.map { .string($0) } ?? .null, "notified": .bool(run.notified),
            ]
        }

        /// `config.change`: which setting, its value before and after (null when unset), and whether the
        /// change came from chat or the command line.
        public static func configChange(_ outcome: ConfigEdit.Outcome, source: String) -> [String: JSONValue] {
            [
                "path": .string(outcome.path), "old": outcome.old ?? .null, "new": outcome.new ?? .null,
                "source": .string(source),
            ]
        }

        /// `model.pull`: a model fetched with the person's approval (`wisp models pull`) into the Hugging Face
        /// cache and linked from the MLX models directory: the selection it becomes, where from, the link's path
        /// and the cache's snapshot, how many files and bytes the repository lists, how many files the cache
        /// already held, how many files and bytes this run fetched, what happened at the link's path, and how it
        /// ended (`fetched`, `linked`, `declined`, `failed`), with why.
        public static func modelPull(
            model: String, repository: String, directory: String, cache: String, files: Int, bytes: Int, reused: Int,
            fetchedFiles: Int, fetched: Int, link: String?, outcome: String, reason: String?, seconds: Double
        ) -> [String: JSONValue] {
            [
                "model": .string(model), "repository": .string(repository), "directory": .string(directory),
                "cache": .string(cache), "files": .int(files), "bytes": .int(bytes), "reused": .int(reused),
                "fetchedFiles": .int(fetchedFiles), "fetched": .int(fetched), "link": link.map { .string($0) } ?? .null,
                "outcome": .string(outcome), "reason": reason.map { .string($0) } ?? .null, "seconds": .double(seconds),
            ]
        }

        /// `classifier.train`: where the model went, what it learned from, and how well it fits that.
        public static func classifierTrained(
            _ outcome: RiskClassifierTraining.Outcome, examplesSource: String
        ) -> [String: JSONValue] {
            [
                "path": .string(outcome.url.path), "examplesSource": .string(examplesSource),
                "examples": .int(outcome.examples),
                "perLevel": .object(
                    Dictionary(uniqueKeysWithValues: outcome.perLevel.map { ($0.key.rawValue, .int($0.value)) })),
                "trainingAccuracy": .double(outcome.trainingAccuracy), "seconds": .double(outcome.seconds),
            ]
        }

        /// `redaction`: where, how much, and how many values of each kind were replaced.
        public static func redaction(_ report: Redaction.Report) -> [String: JSONValue] {
            [
                "source": Condensing.json(report.source), "bytes": .int(report.bytes),
                "bytesOut": .int(report.text.utf8.count), "truncated": .bool(report.truncated),
                "thorough": .bool(report.chunks != nil), "replaced": .object(report.counts.mapValues { .int($0) }),
                "failedChunks": .array(report.failedChunks.map { .int($0) }),
            ]
        }

        /// `notification`: what was asked to be shown, by whom, whether it was and by which route, and why
        /// the earlier routes were not taken (ADR 0044).
        public static func notification(
            title: String, body: String, source: String, outcome: Notifier.Outcome, skipped: [String] = []
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "title": .string(title), "body": .string(body), "source": .string(source),
            ]
            switch outcome {
            case .posted(let route):
                details["outcome"] = "posted"
                details["route"] = .string(route.rawValue)
            case .refused(let reason):
                details["outcome"] = "refused"
                details["reason"] = .string(reason)
            }
            if !skipped.isEmpty { details["skipped"] = .array(skipped.map { .string($0) }) }
            return details
        }

        /// `host.hello`: what a `wisp chat --json` front end declared it carries, and who it is.
        public static func hostHello(_ hello: ChatProtocol.Hello) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["effects": .array(hello.effects.map { .string($0) })]
            if let client = hello.client { details["client"] = .string(client) }
            if let version = hello.version { details["version"] = .string(version) }
            return details
        }

        /// `error`.
        public static func error(message: String, context: String?) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["message": .string(message)]
            if let context { details["context"] = .string(context) }
            return details
        }

        /// The fields every approval event shares: the simple command, its pattern, and the whole line
        /// when the command is part of one.
        private static func approvalSubject(command: String, pattern: String, line: String) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["command": .string(command), "pattern": .string(pattern)]
            if line != command { details["line"] = .string(line) }
            return details
        }

        /// `classifier.verdict`.
        public static func classifierVerdict(
            command: String, pattern: String, line: String, assessment: RiskAssessment, seconds: TimeInterval
        ) -> [String: JSONValue] {
            var details = approvalSubject(command: command, pattern: pattern, line: line).merging([
                "level": .string(assessment.level.rawValue),
                "reasons": .array(assessment.reasons.map { .string($0) }),
                "sources": .array(assessment.sources.map { .string($0) }),
                "seconds": .double(seconds),
            ]) { $1 }
            if !assessment.metadata.isEmpty { details["metadata"] = .object(assessment.metadata) }
            return details
        }

        /// `approval.requested`.
        public static func approvalRequested(
            command: String, pattern: String, line: String, level: RiskLevel
        )
            -> [String: JSONValue]
        {
            approvalSubject(command: command, pattern: pattern, line: line).merging(["level": .string(level.rawValue)])
            { $1 }
        }

        /// What a pending request asks about: for a command, `command`, `pattern`, and `line` when it differs;
        /// for a fact (ADR 0048), `kind` `fact` and the fact's `fact` id, `subject`, `name`, `value`, and
        /// `source`.
        private static func pendingSubject(_ request: PendingApprovals.Request) -> [String: JSONValue] {
            guard request.kind == .fact else {
                return approvalSubject(command: request.command, pattern: request.pattern, line: request.line)
            }
            var details: [String: JSONValue] = ["kind": .string(request.kind.rawValue)]
            if let fact = request.fact {
                details["fact"] = .string(fact.id)
                details["subject"] = .string(fact.subject)
                details["name"] = .string(fact.name)
                details["value"] = .string(fact.value)
                details["source"] = .string(fact.source)
            }
            return details
        }

        /// `approval.pending`: a command waiting under `wisp mcp`, or a fact a caller asked to keep, was filed
        /// for another face to answer (`outcome` `filed`), or could not be (`failed`, with `reason`).
        /// `alongside` is `elicitation` when the client's dialog asks at the same time.
        public static func approvalPending(
            _ request: PendingApprovals.Request, outcome: String, alongside: String?, reason: String? = nil
        ) -> [String: JSONValue] {
            var details = pendingSubject(request)
            details["request"] = .string(request.id)
            if request.kind == .command {
                details["directory"] = .string(request.directory)
                details["level"] = .string(request.level.rawValue)
            }
            details["outcome"] = .string(outcome)
            if let thread = request.thread { details["thread"] = .string(thread) }
            if let client = request.client { details["client"] = .string(client) }
            if let expires = request.expiresAt { details["expiresAt"] = .string(expires.ISO8601Format()) }
            if let alongside { details["alongside"] = .string(alongside) }
            if let reason { details["reason"] = .string(reason) }
            return details
        }

        /// `approval.answered`: the person answered a waiting request in this process (`via` `cli` or `tui`).
        /// `delivery` is `taken` (the server took it), `too-late` (the request went another way first),
        /// `waiting` (not yet read), or `refused` (not written, with `reason`). A fact request's answer is
        /// `keep` or `drop`, with the fact's fields in place of the command's.
        public static func approvalAnswered(
            request id: String, _ request: PendingApprovals.Request?, decision: String, via: String,
            delivery: String, reason: String? = nil
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "request": .string(id), "decision": .string(decision), "via": .string(via),
                "delivery": .string(delivery),
            ]
            if let request {
                if request.kind == .fact {
                    details.merge(pendingSubject(request)) { $1 }
                } else {
                    details["command"] = .string(request.command)
                    details["pattern"] = .string(request.pattern)
                    details["directory"] = .string(request.directory)
                }
                if let thread = request.thread { details["thread"] = .string(thread) }
            }
            if let reason { details["reason"] = .string(reason) }
            return details
        }

        /// `approval.settled`: how a filed request ended. `outcome` is `answered` (with `via`: `elicitation`,
        /// `cli`, or `tui`, and the `decision`), `timed-out`, `abandoned` (the caller cancelled the call),
        /// `failed` (no way left to ask, with `reason`), or `stale` (removed by a sweep after its server
        /// stopped or its wait expired). A fact request (ADR 0048) carries the fact's fields in place of the
        /// command, `decision` `keep` or `drop`, `kept` (the permanent fact's id) when kept, and may also end
        /// `withdrawn` (its thread closed or the server stopped first).
        public static func approvalSettled(
            _ request: PendingApprovals.Request, outcome: String, via: String? = nil, decision: String? = nil,
            reason: String? = nil, seconds: TimeInterval? = nil, kept: String? = nil
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = ["request": .string(request.id), "outcome": .string(outcome)]
            if request.kind == .fact {
                details.merge(pendingSubject(request)) { $1 }
            } else {
                details["command"] = .string(request.command)
            }
            if let kept { details["kept"] = .string(kept) }
            if let thread = request.thread { details["thread"] = .string(thread) }
            if let via { details["via"] = .string(via) }
            if let decision { details["decision"] = .string(decision) }
            if let reason { details["reason"] = .string(reason) }
            if let seconds { details["seconds"] = .double(seconds) }
            return details
        }

        /// `approval.decided`. `decision` is `approved`, `denied`, `timed-out`, `cached`, `cached-turn`,
        /// `cached-project`, or `cached-always`; the optionals apply as documented for each.
        public static func approvalDecided(
            command: String, pattern: String, line: String, decision: String, scope: ApprovalScope? = nil,
            reason: String? = nil, approvalID: String? = nil, expiresAt: Date? = nil,
            downgradedFrom: ApprovalScope? = nil, persistError: String? = nil
        ) -> [String: JSONValue] {
            var details = approvalSubject(command: command, pattern: pattern, line: line)
            details["decision"] = .string(decision)
            if let scope { details["scope"] = .string(scope.rawValue) }
            if let reason { details["reason"] = .string(reason) }
            if let approvalID { details["approvalID"] = .string(approvalID) }
            if let expiresAt { details["expiresAt"] = .string(expiresAt.ISO8601Format()) }
            if let downgradedFrom { details["downgradedFrom"] = .string(downgradedFrom.rawValue) }
            if let persistError { details["persistError"] = .string(persistError) }
            return details
        }
    }

    /// The detail fields each kind may carry, exactly as `docs/logging.md` lists them.
    public static func fields(for kind: Kind) -> Set<String> {
        switch kind {
        case .sessionStart:
            [
                "entryPoint", "systemPromptExtension", "instructions", "tools", "model", "unsafe", "autoApprove",
                "resume", "parent", "reason", "carriedFrom",
            ]
        case .sessionEnd: ["reason"]
        case .modelResolved:
            ["model", "backend", "asset", "capabilities", "capabilitySource", "tools", "contextSize", "contextNote"]
        case .prompt: ["text", "schema"]
        case .response: ["text", "condensed", "seconds"]
        case .modelReasoning: ["phase", "text", "bytes", "tokens", "seconds"]
        case .toolCall: ["tool", "arguments"]
        case .toolResult: ["tool", "output", "bytes", "seconds"]
        case .policyDecision:
            ["command", "workingDirectory", "verdict", "reason", "sandbox", "network", "nested", "origin"]
        case .commandOutcome:
            [
                "command", "exitStatus", "timedOut", "truncated", "stdout", "stderr", "seconds", "origin",
                "sandboxRefusal", "sandboxPaths",
            ]
        case .commandTyped:
            [
                "command", "workingDirectory", "verdict", "reason", "exitStatus", "timedOut", "truncated",
                "sandboxRefused", "sandboxRefusal", "sandboxPaths", "output", "bytes", "seconds", "failure",
            ]
        case .fileWrite: ["path", "mode", "created", "bytesBefore", "bytesAfter"]
        case .notification: ["title", "body", "source", "outcome", "reason", "route", "skipped"]
        case .hostHello: ["effects", "client", "version"]
        case .secretScan: ["source", "bytes", "diff", "thorough", "findings", "kinds", "failedChunks", "classifier"]
        case .redaction: ["source", "bytes", "bytesOut", "truncated", "thorough", "replaced", "failedChunks"]
        case .modelRouted: ["task", "inputBytes", "model", "reason"]
        case .modelPull:
            [
                "model", "repository", "directory", "cache", "files", "bytes", "reused", "fetchedFiles", "fetched",
                "link", "outcome", "reason", "seconds",
            ]
        case .watchRun:
            [
                "command", "run", "trigger", "exitStatus", "timedOut", "state", "previous", "changed", "seconds",
                "findings", "triageError", "notified",
            ]
        case .condensation:
            [
                "turnsBefore", "turnsAfter", "contextSize", "tokenCount", "reason", "savedBefore", "savedAfter",
                "target", "fillBefore", "fillAfter", "headroom", "steps", "floor",
            ]
        case .presentationCut:
            ["entry", "output", "tool", "response", "result", "bytes", "tokens", "words", "coverage"]
        case .outputReferenced: ["entry", "tool", "result", "bytes", "referenceBytes", "tokens"]
        case .distillation: ["turns", "entries", "bytes", "facts", "seconds", "model", "failure"]
        case .summary:
            [
                "version", "turns", "entries", "bytes", "covered", "summaryBytes", "seconds", "model", "combined",
                "failure",
            ]
        case .memory:
            [
                "request", "action", "target", "found", "entries", "facts", "summaries", "events", "from", "offset",
                "bytes", "noted", "subject", "name", "value", "class", "failure",
            ]
        case .assessment:
            [
                "method", "tools", "ruleTools", "registered", "intent", "taskChanged", "task", "facts", "seconds",
                "bytes", "model", "failure",
            ]
        case .factRecorded:
            [
                "id", "scope", "subject", "name", "source", "version", "value", "class", "method", "detail", "entries",
                "sources", "supersedes",
            ]
        case .factSuperseded: ["id", "subject", "name", "source", "by"]
        case .factDeleted: ["id", "subject", "name", "source", "value", "by"]
        case .factScopeChanged:
            ["fact", "from", "to", "by", "now", "subject", "name", "source", "value", "proposed", "request"]
        case .factConflict, .factResolved: ["subject", "name", "winner", "others"]
        case .mcpRequest: ["tool", "arguments"]
        case .mcpResult: ["tool", "isError", "text", "seconds"]
        case .error: ["message", "context"]
        case .classifierVerdict: ["command", "pattern", "line", "level", "reasons", "sources", "seconds", "metadata"]
        case .classifierTrained: ["path", "examplesSource", "examples", "perLevel", "trainingAccuracy", "seconds"]
        case .configChange: ["path", "old", "new", "source"]
        case .approvalRequested: ["command", "pattern", "line", "level"]
        case .approvalPending:
            [
                "request", "command", "pattern", "line", "directory", "level", "thread", "client", "expiresAt",
                "alongside", "outcome", "reason", "kind", "fact", "subject", "name", "value", "source",
            ]
        case .approvalAnswered:
            [
                "request", "command", "pattern", "directory", "thread", "decision", "via", "delivery", "reason",
                "kind", "fact", "subject", "name", "value", "source",
            ]
        case .approvalSettled:
            [
                "request", "command", "thread", "outcome", "via", "decision", "reason", "seconds", "kind", "fact",
                "subject", "name", "value", "source", "kept",
            ]
        case .approvalDecided:
            [
                "command", "pattern", "line", "decision", "scope", "reason", "approvalID", "expiresAt",
                "downgradedFrom",
                "persistError",
            ]
        case .unknown: []
        }
    }
}

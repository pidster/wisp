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
            network: Bool, nested: Bool
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "command": .string(command), "workingDirectory": .string(workingDirectory),
                "verdict": .string(verdict.rawValue), "sandbox": .bool(sandbox), "network": .bool(network),
                "nested": .bool(nested),
            ]
            if let reason { details["reason"] = .string(reason) }
            return details
        }

        /// `command.outcome`.
        public static func commandOutcome(
            command: String, outcome: CommandRunner.Outcome, seconds: TimeInterval
        )
            -> [String: JSONValue]
        {
            [
                "command": .string(command), "exitStatus": .int(Int(outcome.exitStatus)),
                "timedOut": .bool(outcome.timedOut), "truncated": .bool(outcome.truncated),
                "stdout": .string(outcome.stdout), "stderr": .string(outcome.stderr), "seconds": .double(seconds),
            ]
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

        /// `fact.approved`: a proposed permanent fact the person admitted to the shared store.
        public static func factApproved(_ proposal: Fact, admitted: Fact) -> [String: JSONValue] {
            [
                "id": .string(proposal.id), "admitted": .string(admitted.id),
                "subject": .string(admitted.identity.subject), "name": .string(admitted.identity.name),
                "source": .string(admitted.source.rawValue), "value": .string(admitted.value),
            ]
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

        /// `notification`: what was asked to be shown, by whom, and whether it was.
        public static func notification(
            title: String, body: String, source: String, outcome: Notifier.Outcome
        ) -> [String: JSONValue] {
            var details: [String: JSONValue] = [
                "title": .string(title), "body": .string(body), "source": .string(source),
            ]
            switch outcome {
            case .posted: details["outcome"] = "posted"
            case .refused(let reason):
                details["outcome"] = "refused"
                details["reason"] = .string(reason)
            }
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
        case .toolCall: ["tool", "arguments"]
        case .toolResult: ["tool", "output", "bytes", "seconds"]
        case .policyDecision: ["command", "workingDirectory", "verdict", "reason", "sandbox", "network", "nested"]
        case .commandOutcome: ["command", "exitStatus", "timedOut", "truncated", "stdout", "stderr", "seconds"]
        case .fileWrite: ["path", "mode", "created", "bytesBefore", "bytesAfter"]
        case .notification: ["title", "body", "source", "outcome", "reason"]
        case .secretScan: ["source", "bytes", "diff", "thorough", "findings", "kinds", "failedChunks", "classifier"]
        case .redaction: ["source", "bytes", "bytesOut", "truncated", "thorough", "replaced", "failedChunks"]
        case .modelRouted: ["task", "inputBytes", "model", "reason"]
        case .watchRun:
            [
                "command", "run", "trigger", "exitStatus", "timedOut", "state", "previous", "changed", "seconds",
                "findings", "triageError", "notified",
            ]
        case .condensation:
            ["turnsBefore", "turnsAfter", "contextSize", "tokenCount", "reason", "savedBefore", "savedAfter"]
        case .presentationCut:
            ["entry", "output", "tool", "response", "result", "bytes", "tokens", "words", "coverage"]
        case .outputReferenced: ["entry", "tool", "result", "bytes", "referenceBytes", "tokens"]
        case .distillation: ["turns", "entries", "bytes", "facts", "seconds", "model", "failure"]
        case .factRecorded:
            [
                "id", "scope", "subject", "name", "source", "version", "value", "class", "method", "detail", "entries",
                "sources", "supersedes",
            ]
        case .factSuperseded: ["id", "subject", "name", "source", "by"]
        case .factDeleted: ["id", "subject", "name", "source", "value", "by"]
        case .factApproved: ["id", "admitted", "subject", "name", "source", "value"]
        case .factConflict, .factResolved: ["subject", "name", "winner", "others"]
        case .mcpRequest: ["tool", "arguments"]
        case .mcpResult: ["tool", "isError", "text", "seconds"]
        case .error: ["message", "context"]
        case .classifierVerdict: ["command", "pattern", "line", "level", "reasons", "sources", "seconds", "metadata"]
        case .classifierTrained: ["path", "examplesSource", "examples", "perLevel", "trainingAccuracy", "seconds"]
        case .configChange: ["path", "old", "new", "source"]
        case .approvalRequested: ["command", "pattern", "line", "level"]
        case .approvalDecided:
            [
                "command", "pattern", "line", "decision", "scope", "reason", "approvalID", "expiresAt",
                "downgradedFrom",
                "persistError",
            ]
        }
    }
}

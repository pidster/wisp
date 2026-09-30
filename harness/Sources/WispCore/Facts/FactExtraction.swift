import Foundation

/// Facts taken from a turn's tool output without a model (decision D1 of the
/// [layered-context proposal](../../../../docs/proposals/2026-09-29-layered-context.md)): each rule reads one
/// tool's arguments and output and says what is now true, in a line, or nothing. Few and correct rather than
/// many: an output that does not match a rule's shape gives no fact.
///
/// | Tool | Fact |
/// | --- | --- |
/// | `run_command` with a working directory | `workdir`: the directory |
/// | `run_command` running a listed test command | `tests`, named by the command: passed or failed, with the exit status |
/// | `run_command` running git, when its output names the branch | `branch` |
/// | `read_file` | `file`, by path: the lines read, whether to the end, the bytes |
/// | `edit_file` | `file`, by path: what the edit did |
/// | `system_info` | `service` per listening port (`ports`); `machine` per other topic: its first line |
enum FactExtraction {
    /// At most this many facts from one turn.
    static let perTurn = 12
    /// At most this many ports from one `system_info` call.
    static let ports = 5

    /// One tool call of a turn and what it returned.
    struct Call: Equatable {
        /// The tool's name.
        var tool: String
        /// Its arguments, decoded; empty when they were not a JSON object.
        var arguments: [String: JSONValue]
        /// Its output as the tool returned it.
        var output: String
        /// The `tool.result` event that recorded the output.
        var result: AuditReference?
        /// When the output was recorded.
        var time: Date

        /// A string argument, trimmed; nil when absent or empty.
        func string(_ key: String) -> String? {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty
            else { return nil }
            return value
        }
    }

    /// The turn's calls, paired from its `tool.call` and `tool.result` events by call id, in order.
    ///
    /// - Parameter events: The turn's tool events.
    /// - Returns: Each call that has a result.
    static func calls(from events: [AuditEvent]) -> [Call] {
        var results: [String: AuditEvent] = [:]
        for event in events where event.kind == .toolResult {
            if let call = event.call { results[call] = event }
        }
        return events.filter { $0.kind == .toolCall }.compactMap { event in
            guard let id = event.call, let result = results[id] else { return nil }
            let text = event.details["arguments"]?.stringValue ?? "{}"
            let arguments = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.objectValue ?? [:]
            return Call(
                tool: event.details["tool"]?.stringValue ?? "", arguments: arguments,
                output: result.details["output"]?.stringValue ?? "", result: AuditReference(result), time: result.time)
        }
    }

    /// What the calls say, as assertions from the tool, at most `perTurn`.
    ///
    /// - Parameters:
    ///   - calls: The turn's calls.
    ///   - kinds: The subject kinds, which name and normalise each fact, and the test commands.
    ///   - turn: The turn.
    ///   - entries: The store id of each call's output, by its `tool.result` event id.
    /// - Returns: The assertions, in call order.
    static func assertions(
        from calls: [Call], kinds: SubjectKinds, turn: Int?, entries: [String: Int] = [:]
    ) -> [FactBook.Assertion] {
        var found: [FactBook.Assertion] = []
        for call in calls {
            let make = { (subject: String, name: String, value: String) -> FactBook.Assertion? in
                guard let (identity, temporalClass) = kinds.identity(subject: subject, name: name) else { return nil }
                return FactBook.Assertion(
                    identity: identity, source: .tool, value: value, temporalClass: temporalClass, method: .extracted,
                    detail: call.tool, entries: call.result.flatMap { entries[$0.event] }.map { [$0] } ?? [],
                    audit: call.result.map { [$0] } ?? [], time: call.time, turn: turn)
            }
            for (subject, name, value) in facts(in: call, kinds: kinds) {
                if let assertion = make(subject, name, value) { found.append(assertion) }
            }
        }
        return Array(found.prefix(perTurn))
    }

    /// The facts one call gives, as subject, name, and value.
    static func facts(in call: Call, kinds: SubjectKinds) -> [(String, String, String)] {
        let failed = call.output.hasPrefix("error:")
        switch call.tool {
        case "run_command":
            guard let command = call.string("command"), !failed else { return [] }
            var facts: [(String, String, String)] = []
            if let directory = call.string("workingDirectory") {
                facts.append(("workdir", "", URL(fileURLWithPath: directory).standardizedFileURL.path))
            }
            let status = exitStatus(call.output)
            if kinds.testCommand(in: command) != nil, let status {
                facts.append(
                    ("tests", command, status == 0 ? "passed (exit status 0)" : "failed (exit status \(status))"))
            }
            if status == 0, command.contains("git"), let branch = branch(in: call.output) {
                facts.append(("branch", "", branch))
            }
            return facts
        case "read_file":
            guard let path = call.string("path"), !failed, let read = pageRead(call.output) else { return [] }
            return [("file", path, read + ", \(call.output.utf8.count) bytes")]
        case "edit_file":
            guard let path = call.string("path") else { return [] }
            let first = firstLine(call.output)
            return [("file", path, failed ? "edit failed: \(first)" : first)]
        case "system_info":
            guard !failed, let topic = call.string("topic") else { return [] }
            if topic == "ports" {
                return portRows(call.output).prefix(ports).map { ("service", "port \($0.port)", $0.value) }
            }
            return [("machine", topic, firstLine(call.output))]
        default:
            return []
        }
    }

    /// The exit status `run_command` reported on its first line, or nil.
    static func exitStatus(_ output: String) -> Int? {
        guard let first = output.split(separator: "\n").first,
            let match = first.firstMatch(of: #/^exit status: (-?\d+)$/#)
        else { return nil }
        return Int(match.1)
    }

    /// The branch git's output names, when exactly one is named: `On branch x` (`git status`), `## x...y`
    /// (`git status -sb`), `Switched to (a new) branch 'x'`, or, for output of one line in the shape of a
    /// branch name, that line (`git branch --show-current`, `git rev-parse --abbrev-ref HEAD`).
    ///
    /// - Parameter output: `run_command`'s output.
    /// - Returns: The branch, or nil.
    static func branch(in output: String) -> String? {
        let content = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && $0 != "stdout:" && $0 != "stderr:" && !$0.hasPrefix("exit status:")
        }
        var names: Set<String> = []
        for line in content {
            if let match = line.firstMatch(of: #/^On branch (\S+)$/#) { names.insert(String(match.1)) }
            if let match = line.firstMatch(of: #/^## ([^\s.]+)/#), match.1 != "HEAD" { names.insert(String(match.1)) }
            if let match = line.firstMatch(of: #/^Switched to (?:a new )?branch '([^']+)'$/#) {
                names.insert(String(match.1))
            }
        }
        if names.isEmpty, content.count == 1, content[0] != "HEAD",
            content[0].wholeMatch(of: #/[A-Za-z0-9._/-]{1,100}/#) != nil
        {
            names.insert(content[0])
        }
        return names.count == 1 ? names.first : nil
    }

    /// What a `read_file` page read: `read lines 1-101, to the end` or `read lines 1-200 of more`; nil when
    /// the output has no numbered lines.
    static func pageRead(_ output: String) -> String? {
        let numbers = output.split(separator: "\n").compactMap { line -> Int? in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            return Int(line[..<tab])
        }
        guard let first = numbers.first, let last = numbers.last else { return nil }
        let end = output.hasSuffix("[end of file]")
        return "read lines \(first)-\(last)" + (end ? ", to the end" : ", more after")
    }

    /// The first line of content, shortened.
    static func firstLine(_ output: String) -> String {
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        return OutputReference.shortened(line.trimmingCharacters(in: .whitespaces), to: 120)
    }

    /// The listening sockets in `system_info`'s ports table: the port, and the command and pid.
    static func portRows(_ output: String) -> [(port: String, value: String)] {
        var rows: [(port: String, value: String)] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 4, Int(fields[1]) != nil, fields[0] != "COMMAND",
                let port = fields[3].split(separator: ":").last.map(String.init), Int(port) != nil
            else { continue }
            let state = fields.count > 4 ? fields[4].lowercased() : "open"
            let value = "\(fields[0]) (pid \(fields[1])), \(state == "listen" ? "listening" : state)"
            if !rows.contains(where: { $0.port == port }) { rows.append((port, value)) }
        }
        return rows
    }
}

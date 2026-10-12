import Foundation

/// The exact readers of the verification pass ([ADR 0060](../../../../docs/decisions/0060-a-verification-pass.md)):
/// after a reply, each reads one form a result claim takes (a tool written in call form with a result beside it, a
/// command said to have run, an exit status, a denial, a notification posted, a file removed, an output quoted, a
/// count) and keeps the claims the turn's call list cannot support. No model: every finding names what was checked.
///
/// The list is the turn's complete call list from the audit log (`TurnCalls`, every call), each with its whole
/// output where the output store kept it, never a slice the model fetched. Earlier turns' calls are a second,
/// weaker support: a claim only they support is not flagged, since a reply may report what an earlier turn found,
/// but it is never counted as this turn's. Like `TurnToolSummary` and `CitedEntries`, the readers are deterministic;
/// a reply with none of their forms makes no claim they can read, and nothing runs.
public enum ReplyVerification {
    /// One of the readers.
    public enum Reader: String, Sendable, Codable, CaseIterable, Equatable {
        /// A tool in call form with a result beside it, and no such call in the turn.
        case call
        /// A command said to have run that no `run_command` call ran.
        case command
        /// A denial, an exit status, a test or build outcome no call produced.
        case outcome
        /// A notification said to be posted when no `notify` call succeeded.
        case notification
        /// A file said to be removed when no removing command ran.
        case removal
        /// Output quoted that no call's output holds.
        case output
        /// A count no output holds.
        case count
        /// The person said to have answered, chosen, or confirmed when no `ask` call was answered (ADR 0062).
        case answer
    }

    /// One claim a reader could not support.
    public struct Claim: Equatable, Sendable, Codable {
        /// The reader that read it; `model` names none.
        public var reader: Reader?
        /// The claim, quoted from the reply, at most `claimLength` characters.
        public var claim: String
        /// Why the list does not support it.
        public var reason: String

        /// Creates a claim.
        public init(reader: Reader?, claim: String, reason: String) {
            self.reader = reader
            self.claim = claim
            self.reason = reason
        }

        /// The claim as JSON, for `respond`'s `verification` and the audit event: `reader` is the reader's name, or
        /// `model` for the model step's finding.
        public var json: JSONValue {
            .object([
                "reader": .string(reader?.rawValue ?? "model"), "claim": .string(claim), "reason": .string(reason),
            ])
        }
    }

    /// The most characters a quoted claim keeps.
    public static let claimLength = 120
    /// The most claims one reply yields.
    public static let claimLimit = 12

    /// The claims in `reply` that `calls` cannot support, at most `claimLimit`, in the order the readers run.
    ///
    /// - Parameters:
    ///   - reply: The reply's text.
    ///   - calls: The turn's complete call list, from the audit log.
    ///   - tools: The names of the conversation's tools, so a call form is read only for them.
    ///   - earlier: Earlier turns' calls, a second support; empty for the first turn.
    ///   - answered: Whether the person has answered one of the conversation's questions another way than a call
    ///     this list holds (a note after a park, ADR 0062), which supports a claim about their answer.
    ///   - output: A call's whole output, from the output store when it was kept; nil falls back to the call's own.
    /// - Returns: The unsupported claims.
    public static func claims(
        in reply: String, calls: [TurnCalls.Call], tools: [String], earlier: [TurnCalls.Call] = [],
        answered: Bool = false, output: (TurnCalls.Call) -> String? = { _ in nil }
    ) -> [Claim] {
        let support = Support(calls: calls, earlier: earlier, output: output)
        let raw = reply.components(separatedBy: "\n")
        // Matched with bold and underline marks removed, so `**Removed** the file` reads as words.
        let lines = raw.map(plain)
        let form = callForm(tools: tools)
        var found: [Claim] = []
        found += callClaims(lines: lines, form: form, support: support)
        found += commandClaims(lines: lines, form: form, support: support)
        found += outcomeClaims(lines: lines, support: support)
        found += notificationClaims(lines: lines, support: support)
        found += removalClaims(lines: lines, support: support)
        found += outputClaims(lines: lines, raw: raw, form: form, support: support)
        found += countClaims(lines: lines, support: support)
        if !answered { found += answerClaims(lines: lines, support: support) }
        var seen: Set<String> = []
        return Array(found.filter { seen.insert($0.claim).inserted }.prefix(claimLimit))
    }

    /// Whether `reply` has result language: a tool of the conversation in call form, or a word that reports an
    /// outcome. The model step runs only on such a reply (ADR 0060).
    ///
    /// - Parameters:
    ///   - reply: The reply's text.
    ///   - tools: The conversation's tools.
    /// - Returns: Whether the reply reports results.
    public static func hasResultLanguage(_ reply: String, tools: [String]) -> Bool {
        callForm(tools: tools).has(reply) || resultWords.has(reply)
    }

    /// The line beside the reply for `claims`: the first quoted with its reason, then how many more; nil for none.
    ///
    /// - Parameter claims: The unsupported claims.
    /// - Returns: The line, or nil.
    public static func line(_ claims: [Claim]) -> String? {
        guard let first = claims.first else { return nil }
        let more = claims.count > 1 ? " +\(claims.count - 1) more" : ""
        let reason = first.reader == nil ? "the model found no call producing it: \(first.reason)" : first.reason
        return "unsupported: \"\(first.claim)\" (\(reason))\(more)"
    }

    // MARK: - The support

    /// The call list a reply is checked against: this turn's calls with their whole outputs, and earlier turns' as
    /// a second support.
    struct Support {
        /// This turn's calls.
        var calls: [TurnCalls.Call]
        /// Earlier turns' calls.
        var earlier: [TurnCalls.Call]
        /// Each call's whole output, folded, this turn's then earlier ones'.
        var outputs: [String]
        /// Each call's arguments, folded, this turn's then earlier ones'.
        var arguments: [String]

        /// Builds the support, reading each output through `output`.
        init(calls: [TurnCalls.Call], earlier: [TurnCalls.Call], output: (TurnCalls.Call) -> String?) {
            self.calls = calls
            self.earlier = earlier
            outputs = (calls + earlier).map { ReplyVerification.fold(output($0) ?? $0.output ?? "") }
            arguments = (calls + earlier).map { ReplyVerification.fold($0.arguments) }
        }

        /// This turn's calls and earlier ones.
        var all: [TurnCalls.Call] { calls + earlier }
        /// The commands among them.
        var commands: [TurnCalls.Call] { all.filter { $0.command != nil } }

        /// Whether `tool` was called.
        func called(_ tool: String) -> Bool { all.contains { $0.tool == tool } }

        /// Whether a call of `tool` has every one of `tokens` in its arguments.
        func supportsCall(_ tool: String, tokens: [String]) -> Bool {
            zip(all, arguments).contains { call, arguments in
                call.tool == tool && tokens.allSatisfy { arguments.contains($0) }
            }
        }

        /// Whether `text`, folded, is in any output.
        func inOutput(_ text: String) -> Bool {
            let needle = ReplyVerification.fold(text)
            return needle.isEmpty || outputs.contains { $0.contains(needle) }
        }

        /// Whether a command whose folded line contains `line` ran, with any outcome.
        func ranCommand(containing line: String) -> Bool {
            let needle = ReplyVerification.fold(line)
            return needle.isEmpty || commands.contains { ReplyVerification.fold($0.command ?? "").contains(needle) }
        }

        /// This turn's command whose line contains `line`, if one ran.
        func command(containing line: String) -> TurnCalls.Call? {
            let needle = ReplyVerification.fold(line)
            guard !needle.isEmpty else { return nil }
            return calls.first { call in call.command.map { ReplyVerification.fold($0).contains(needle) } ?? false }
        }

        /// Whether a command whose line names one of `words` exited 0.
        func ranSuccessfully(naming words: [String]) -> Bool {
            commands.contains { call in
                guard let command = call.command?.lowercased(), call.exitStatus == 0, !call.timedOut else {
                    return false
                }
                return words.contains { command.contains($0) }
            }
        }
    }

    // MARK: - Readers

    /// Result markers beside a call form: on its line after it, or on the next two lines.
    private static let resultMarker = Pattern(
        #"(→|->|\bOutput\b|\bResults?\b|\bReturned\b|\bRan\b|\bSuccess\b|\bsucceeded\b|\bconfirmed\b|"#
            + #"\bdisplayed\b|\bposted\b|\bdenied\b|\bexit status\b|\bexit code\b)"#)
    /// `ran` just before a call form: "Ran `inspect(config)`".
    private static let ranBefore = Pattern(#"\bran\s*[`*_]*$"#)
    /// A value that is a placeholder, not a result: `<scratch>`, "(example path)".
    private static let placeholder = Pattern(#"<[^>\n]{1,40}>|\bexample\b|\bplaceholder\b|\bTBD\b"#)
    /// A value that opens with an angle-bracketed placeholder: `<scratch>`, `: <path>`.
    private static let angleFirst = Pattern(#"^[\s:→\-–—`"']*<[^>\n]{1,40}>"#)
    /// A line that says its value is illustrative.
    private static let illustrative = Pattern(#"\bexample\b|\bplaceholder\b|\bTBD\b|\bfor instance\b|\be\.g\."#)
    /// A backticked value that is output rather than a name: it has a path separator, whitespace, or a digit.
    private static let looksLikeOutput = Pattern(#"[/\s0-9]"#)
    /// The words that report an outcome, for `hasResultLanguage`.
    private static let resultWords = Pattern(
        #"\b(ran|executed|returned|output|passed|failed|denied|confirmed|verified|displayed|posted|deleted|"#
            + #"removed|wrote|exit status|exit code|succeeded|success)\b|→"#)
    /// Parameter names in wisp's call forms, not values to look for in the arguments.
    private static let parameterNames: Set<String> = [
        "path", "mode", "content", "command", "line", "limit", "offset", "what", "last", "title", "message",
        "topic", "port", "process", "find", "request", "workingdirectory", "timezone", "args", "env", "stdin",
    ]

    /// A tool written in call form with a result beside it, for a tool the turn did not call, or called with other
    /// arguments.
    private static func callClaims(lines: [String], form: Pattern, support: Support) -> [Claim] {
        var claims: [Claim] = []
        for (index, line) in lines.enumerated() {
            for match in form.matches(line) {
                guard let whole = Range(match.range, in: line), let nameRange = Range(match.range(at: 1), in: line),
                    let argumentsRange = Range(match.range(at: 2), in: line)
                else { continue }
                let before = String(line[..<whole.lowerBound])
                let rest = String(line[whole.upperBound...])
                var region = rest
                if rest.trimmingCharacters(in: CharacterSet(charactersIn: "`*_ .;,")).isEmpty {
                    // The form ends its line, as one in a fenced block does: the result may follow the fence.
                    let following = lines.dropFirst(index + 1).filter {
                        !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                    }
                    region = ([rest] + following.prefix(2)).joined(separator: "\n")
                }
                var claimed = ranBefore.has(before)
                if let marker = resultMarker.first(region), let markerRange = Range(marker.range, in: region) {
                    // The value after the marker: a placeholder, or an illustrative line, is a plan, not a result.
                    let value = String(region[markerRange.upperBound...].prefix(80))
                    claimed = claimed || !(angleFirst.has(value) || illustrative.has(value))
                }
                guard claimed else { continue }
                let tool = String(line[nameRange])
                guard support.called(tool) else {
                    claims.append(Claim(reader: .call, claim: quote(line), reason: "no call to \(tool) in this turn"))
                    continue
                }
                let tokens = argumentTokens(String(line[argumentsRange]))
                guard !support.supportsCall(tool, tokens: tokens) else { continue }
                claims.append(
                    Claim(
                        reader: .call, claim: quote(line),
                        reason: "no \(tool) call in this turn took "
                            + tokens.map { "\"\($0)\"" }.joined(separator: ", ")))
            }
        }
        return claims
    }

    /// The values in a call form's arguments: quoted strings, bare words that are not parameter names, and numbers
    /// of three digits or more (a port, not a page size), each folded; the ones a real call's arguments must hold.
    static func argumentTokens(_ arguments: String) -> [String] {
        let quoted = Pattern(#""((?:[^"\\]|\\.){2,})""#)
        var tokens = quoted.matches(arguments).compactMap { match in
            Range(match.range(at: 1), in: arguments).map { fold(String(arguments[$0])) }
        }
        let rest = quoted.replacing(arguments, with: " ")
        for match in Pattern(#"[A-Za-z_][A-Za-z0-9_.\-]{2,}|\d{3,}"#).matches(rest) {
            guard let range = Range(match.range, in: rest) else { continue }
            let word = String(rest[range])
            if parameterNames.contains(word.lowercased()) || word == "true" || word == "false" { continue }
            tokens.append(fold(word))
        }
        return tokens.filter { !$0.isEmpty && !placeholder.has($0) }
    }

    /// A command said to have run, in backticks after `ran`, `executed`, or `invoked`, that no `run_command` ran.
    private static func commandClaims(lines: [String], form: Pattern, support: Support) -> [Claim] {
        let said = Pattern(#"\b(ran|executed|invoked)\b[^`\n]{0,60}`([^`\n]{2,200})`"#)
        var claims: [Claim] = []
        for line in lines {
            for match in said.matches(line) {
                guard let range = Range(match.range(at: 2), in: line) else { continue }
                let command = String(line[range])
                // A call form in backticks is the call reader's.
                if form.has(command) || support.ranCommand(containing: command) { continue }
                claims.append(
                    Claim(
                        reader: .command, claim: quote(line),
                        reason: "no run_command call in this turn ran `\(command)`"))
            }
        }
        return claims
    }

    /// A denial, an exit status, or a test or build outcome no call produced.
    private static func outcomeClaims(lines: [String], support: Support) -> [Claim] {
        let denial = Pattern(
            #"\b(denied|blocked|refused|rejected)\s+(by|per|under)\s+(the\s+)?(policy|sandbox|gate|deny\s+list)|"#
                + #"(?:^|[|·→])\s*Denied\b|\b(was|were|got)\s+denied\b|\bDenied\s*\((policy|by policy|as expected)"#)
        let exit = Pattern(#"\bexit(?:ed)?\s+(?:with\s+)?(?:status|code)?\s*[:=]?\s*(\d{1,3})\b"#)
        let tests = Pattern(
            #"\b(?:all\s+)?tests?\s+(?:all\s+)?pass(?:ed|es)?\b|\b\d+\s+tests?\s+passed\b|\btest suite passed\b"#)
        let build = Pattern(
            #"\bbuild\s+(?:succeeded|passed|completed successfully)|\bbuilt successfully\b|"#
                + #"\bcompil(?:ed|es)\s+(?:cleanly|successfully)"#)
        let denied = support.commands.contains { $0.verdict != nil }
        var claims: [Claim] = []
        for line in lines {
            if !denied, denial.has(line) {
                var reason = "no call in this turn was denied"
                if let ran = backticked(line).lazy.compactMap({ support.command(containing: $0) }).first,
                    let command = ran.command
                {
                    reason += "; `\(fold(command))` ran" + (ran.exitStatus.map { " and exited \($0)" } ?? "")
                }
                claims.append(Claim(reader: .outcome, claim: quote(line), reason: reason))
            }
            for match in exit.matches(line) {
                guard let range = Range(match.range(at: 1), in: line), let status = Int(line[range]),
                    !support.commands.contains(where: { $0.exitStatus == status })
                else { continue }
                claims.append(
                    Claim(reader: .outcome, claim: quote(line), reason: "no command in this turn exited \(status)"))
            }
            if tests.has(line), !support.ranSuccessfully(naming: ["test"]) {
                claims.append(
                    Claim(reader: .outcome, claim: quote(line), reason: "no test command in this turn exited 0"))
            }
            if build.has(line), !support.ranSuccessfully(naming: ["build", "make", "compile", "xcodebuild"]) {
                claims.append(
                    Claim(reader: .outcome, claim: quote(line), reason: "no build command in this turn exited 0"))
            }
        }
        return claims
    }

    /// A notification said to be posted when no `notify` call succeeded.
    private static func notificationClaims(lines: [String], support: Support) -> [Claim] {
        let posted = Pattern(
            #"\bnotification\b[^.\n]{0,60}?\b(?:has been\s+|was\s+|were\s+)?"#
                + #"(displayed|posted|sent|shown|triggered|delivered)\b|"#
                + #"\b(triggered|posted|sent|delivered)\s+(?:a|the)\s+(?:\w+\s+){0,2}notification\b"#)
        let notified = support.all.contains {
            $0.tool == "notify" && $0.error == nil && !($0.output ?? "").hasPrefix("error:")
        }
        guard !notified else { return [] }
        return lines.filter(posted.has).map {
            Claim(reader: .notification, claim: quote($0), reason: "no notify call in this turn posted one")
        }
    }

    /// A file said to be removed when no removing command ran.
    private static func removalClaims(lines: [String], support: Support) -> [Claim] {
        let removed = Pattern(
            #"\b(?:removed|deleted)\s+(?:the\s+|a\s+)?(?:temporary\s+|temp\s+|scratch\s+)?file\b|"#
                + #"\bfile\s+(?:was\s+|has been\s+|is\s+)?(?:removed|deleted)\b|"#
                + #"\bCleanup\b[^\n]{0,40}\b(?:removed|deleted)\b"#)
        let remover = Pattern(#"(^|[\s;&|(])(rm|rmdir|unlink|trash)\s"#)
        let ran = support.commands.contains { $0.exitStatus == 0 && remover.has($0.command ?? "") }
        guard !ran else { return [] }
        return lines.filter(removed.has).map {
            Claim(reader: .removal, claim: quote($0), reason: "no rm, rmdir, unlink, or trash command ran in this turn")
        }
    }

    /// Output quoted that no call's output holds: a fenced block under a result marker, or a backticked value on a
    /// line with one.
    private static func outputClaims(lines: [String], raw: [String], form: Pattern, support: Support) -> [Claim] {
        let marker = Pattern(#"(→|->|\bOutput\b|\bReturned\b|\bResult\b|\bstdout\b|\bprinted\b)"#)
        var claims: [Claim] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                var body: [String] = []
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(raw[end])
                    end += 1
                }
                // The two lines above the fence, blank ones skipped, must carry a marker and not say "example".
                let above = lines[..<index].reversed().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .prefix(2)
                if above.contains(where: marker.has), !above.contains(where: illustrative.has) {
                    let quoted = body.map(stripLineNumber).filter { !fold($0).isEmpty }.prefix(3)
                    if !quoted.isEmpty, !quoted.allSatisfy(form.has), !quoted.allSatisfy(placeholder.has),
                        !quoted.contains(where: support.inOutput)
                    {
                        claims.append(
                            Claim(
                                reader: .output, claim: quote(quoted.first ?? ""),
                                reason: "no call's output in this turn holds it"))
                    }
                }
                index = end + 1
                continue
            }
            if let found = marker.first(line), let markerRange = Range(found.range, in: line) {
                let after = String(line[markerRange.upperBound...])
                let value = backticked(after).first {
                    $0.count >= 3 && !form.has($0) && !placeholder.has($0) && looksLikeOutput.has($0)
                }
                if let value, !illustrative.has(after), !support.inOutput(value), !support.ranCommand(containing: value)
                {
                    claims.append(
                        Claim(
                            reader: .output, claim: quote(line),
                            reason: "no call's output in this turn holds `\(value)`"))
                }
            }
            index += 1
        }
        return claims
    }

    /// A count no output holds, and that no command printed as its number of lines.
    private static func countClaims(lines: [String], support: Support) -> [Claim] {
        let counted = Pattern(
            #"\b(?:found|returned|listed|matched|there\s+(?:are|were))\s+(\d{1,6})\s+"#
                + #"(?:files?|matches|results|entries|lines|processes|tests?|packages|warnings|errors)\b|"#
                + #"\b(\d{1,6})\s+(?:files?|matches|results|tests?)\s+(?:found|matched|passed|failed)\b"#)
        var claims: [Claim] = []
        for line in lines {
            for match in counted.matches(line) {
                let text = [1, 2].compactMap { Range(match.range(at: $0), in: line) }.map { String(line[$0]) }
                guard let digits = text.first, let number = Int(digits) else { continue }
                let token = Pattern(#"(^|[^0-9.,])"# + digits + #"([^0-9.,]|$)"#)
                let inOutput = support.outputs.contains(where: token.has)
                let asLines = support.calls.contains { call in
                    guard call.command != nil, let output = call.output else { return false }
                    return printedLines(output) == number
                }
                if inOutput || asLines { continue }
                claims.append(
                    Claim(reader: .count, claim: quote(line), reason: "no call's output in this turn holds \(number)"))
            }
        }
        return claims
    }

    /// The person said to have answered, chosen, said, or confirmed something when no `ask` call of this turn or an
    /// earlier one was answered (ADR 0062, D13): a model claiming the person agreed is the worst fabrication the
    /// verb makes possible.
    private static func answerClaims(lines: [String], support: Support) -> [Claim] {
        let claimed = Pattern(
            #"\b(?:you|the (?:person|user|operator))\s+(?:chose|picked|selected|said|told me|answered|confirmed|"#
                + #"replied|opted)\b|\bas you (?:confirmed|said|chose|answered)\b|"#
                + #"\bper your (?:answer|choice)\b|\byour (?:answer|choice) (?:was|is)\b"#)
        let answeredCall = support.all.contains { call in
            call.tool == AskTool.toolName && ["answer:", "chose:"].contains { (call.output ?? "").hasPrefix($0) }
        }
        guard !answeredCall else { return [] }
        return lines.filter(claimed.has).map {
            Claim(reader: .answer, claim: quote($0), reason: "no ask call was answered by the person")
        }
    }

    /// The lines a command printed, from `run_command`'s rendering: the non-blank lines after the `stdout:` heading.
    private static func printedLines(_ output: String) -> Int {
        let lines = output.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == "stdout:" }) else { return 0 }
        return lines[(start + 1)...].prefix { $0 != "stderr:" }.filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
    }

    // MARK: - Text

    /// A compiled regular expression that matches nothing when its pattern does not compile; the patterns here are
    /// constants, so the tests catch that.
    struct Pattern {
        /// The expression, or nil for a pattern that did not compile.
        let expression: NSRegularExpression?

        /// Compiles `pattern`, matching case-insensitively unless `options` say otherwise.
        init(_ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            expression = try? NSRegularExpression(pattern: pattern, options: options)
        }

        /// Every match in `text`.
        func matches(_ text: String) -> [NSTextCheckingResult] {
            expression?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        }

        /// The first match in `text`.
        func first(_ text: String) -> NSTextCheckingResult? {
            expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        }

        /// Whether `text` has a match.
        func has(_ text: String) -> Bool { first(text) != nil }

        /// `text` with every match replaced by `template`.
        func replacing(_ text: String, with template: String) -> String {
            expression?.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) ?? text
        }
    }

    /// The call form of any of `tools`: the name, then arguments in parentheses, one level of nesting allowed. With
    /// no tools, a pattern that matches nothing.
    private static func callForm(tools: [String]) -> Pattern {
        guard !tools.isEmpty else { return Pattern(#"(?!)"#) }
        // Exact names, no space before the parenthesis: prose such as "Inspect (audit, last 5)" is not a call.
        let names = tools.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return Pattern(#"\b("# + names + #")\(([^()\n]*(?:\([^()\n]*\)[^()\n]*)*)\)"#, options: [])
    }

    /// The backticked spans of `text`.
    private static func backticked(_ text: String) -> [String] {
        Pattern(#"`([^`\n]+)`"#).matches(text).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
    }

    /// `line` without markdown bold and underline marks, so emphasis does not break a word boundary.
    private static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    }

    /// `line` without a leading line number as `read_file` prints one (`12\t` or `12   `).
    private static func stripLineNumber(_ line: String) -> String {
        Pattern(#"^\s*\d{1,6}[\t ]+"#).replacing(line, with: "")
    }

    /// `text` folded for matching: backslashes and quotes dropped, whitespace collapsed, lowercased.
    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    /// `line` as a quoted claim: list marks and emphasis dropped, table bars softened, trimmed, cut to `claimLength`.
    static func quote(_ line: String) -> String {
        var text = Pattern(#"^\s*(?:[-*+]|\d+\.)\s+"#).replacing(line, with: "")
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "|", with: "·")
            .trimmingCharacters(in: .whitespaces)
        if text.count > claimLength { text = String(text.prefix(claimLength - 1)) + "…" }
        return text
    }
}

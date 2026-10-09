import Foundation

/// One simple command inside a shell line, with the key its approval is stored under.
public struct SimpleCommand: Equatable, Sendable {
    /// The segment as written, trimmed.
    public var text: String
    /// The program that actually runs, after unwrapping prefixes such as `sudo`, `env`, `time`, or
    /// `VAR=value`, and without its directory.
    public var executable: String
    /// The verb, for a program in `Multiplexers` (`commit` in `git commit -q`); nil otherwise.
    public var subcommand: String?
    /// The approval key: the executable, its verb when it has one, and ` *`, so arguments never
    /// matter to remembering but `git commit *` and `git push *` are remembered apart. For a command
    /// whose program says nothing of what runs (`isKeyedExactly`), the exact text instead.
    public var pattern: String {
        isKeyedExactly ? text : "\(executable)\(subcommand.map { " " + $0 } ?? "") *"
    }
    /// The pattern before verbs were part of it (`git *`); a standing approval stored under it is
    /// still honoured so an existing approvals file keeps working.
    public var legacyPattern: String? { subcommand == nil || isKeyedExactly ? nil : "\(executable) *" }
    /// Whether an approval of this command is remembered by its exact text, never by a pattern: its
    /// program is a shell keyword, an interpreter, or a function definition, or it runs through `exec`,
    /// `xargs`, or `eval`, so `X *` would cover anything at all (`do *`, `sh *`, `python3 *`).
    public var isKeyedExactly: Bool { CommandSplitter.isKeyedExactly(text: text, executable: executable) }

    /// Creates a simple command.
    public init(text: String, executable: String, subcommand: String? = nil) {
        self.text = text
        self.executable = executable
        self.subcommand = subcommand
    }
}

/// Splits a shell line into the simple commands it would run.
///
/// Understands single and double quotes, backslash escapes, the operators `;`, `&&`, `||`, `|`, `&`
/// and newlines, and looks inside `$(…)`, backticks, and `(…)` subshells so a command hidden there is
/// checked too. It is a policy pre-pass, not a shell: anything it cannot parse stays in the enclosing
/// segment's text, where the deny patterns and classifier still see it.
public enum CommandSplitter {
    /// Wrapper options that take a separate value, whose value must be skipped too.
    static let valueOptions: Set<String> = [
        "-n", "-u", "-g", "-s", "-k", "-C", "-i", "-p", "-P", "-I", "-L", "-a", "-c",
    ]

    /// Prefixes that run another command; the real executable follows them.
    static let wrappers: Set<String> = [
        "sudo", "doas", "env", "nice", "nohup", "time", "timeout", "xargs", "command", "exec", "builtin", "caffeinate",
        "stdbuf", "ionice", "chronic",
    ]

    /// Shell keywords and builtins that run what follows them, or nothing of their own: a pattern
    /// such as `do *` would approve any command at all.
    static let keywords: Set<String> = [
        "do", "done", "if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac", "in", "select",
        "function", "coproc", "{", "}", "!", "[[", "]]", "((", "))", ".", "source", "eval", "exec", "trap",
    ]

    /// Programs that run a script or command given to them, so their name says nothing of what runs.
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "node", "deno", "bun", "ruby", "perl", "php",
        "lua", "osascript", "xargs", "pwsh", "tclsh", "expect",
    ]

    /// Wrappers whose presence alone makes a command keyed by its text: what they run is decided late.
    static let exactWrappers: Set<String> = ["exec", "xargs", "eval"]

    /// The shells whose `-c` argument is itself a command line, looked inside like a substitution.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// How deep `split` looks inside nested substitutions and `sh -c` bodies before it stops.
    static let maxDepth = 8

    /// The simple commands in `line`, in order, including those nested in substitutions, subshells,
    /// and the scripts given to `sh -c` and `eval`. Fails closed: a segment from which no command can
    /// be read is returned as itself, so the gate never judges fewer commands than the line holds.
    public static func split(_ line: String) -> [SimpleCommand] { split(line, depth: 0) }

    /// `split` at a nesting `depth`; past `maxDepth` the text is returned whole as one command.
    private static func split(_ line: String, depth: Int) -> [SimpleCommand] {
        guard depth < maxDepth else {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [SimpleCommand(text: text, executable: text)]
        }
        var commands: [SimpleCommand] = []
        for segment in segments(of: line) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let before = commands.count
            for nested in substitutions(in: trimmed) {
                commands += split(nested, depth: depth + 1)
            }
            if let essential = essential(of: trimmed) {
                commands.append(
                    SimpleCommand(text: trimmed, executable: essential.executable, subcommand: essential.subcommand))
                for script in innerScripts(of: trimmed) {
                    commands += split(script, depth: depth + 1)
                }
            } else if commands.count == before {
                // Nothing could be read from it (an assignment, an unbalanced group, a bare `()`): it is
                // judged as written rather than not at all.
                commands.append(SimpleCommand(text: trimmed, executable: trimmed))
            }
        }
        return commands
    }

    /// The command lines a segment hands to a shell: the argument of `sh -c`, `bash -lc`, and the like,
    /// and the words after `eval`, which the shell runs as a line of their own.
    static func innerScripts(of segment: String) -> [String] {
        guard let (name, rest, _) = program(of: segment) else { return [] }
        if name == "eval" { return rest.isEmpty ? [] : [rest.joined(separator: " ")] }
        guard shells.contains(name) else { return [] }
        var words = rest[...]
        while let word = words.first {
            words.removeFirst()
            if word == "-o" || word == "+o" {
                if !words.isEmpty { words.removeFirst() }
                continue
            }
            guard word.hasPrefix("-") || word.hasPrefix("+"), word != "--", word != "-" else { return [] }
            if !word.hasPrefix("--"), word.contains("c") { return words.first.map { [$0] } ?? [] }
        }
        return []
    }

    /// `text` as one shell word: in single quotes, each `'` written `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Whether the command with this `text` and `executable` is remembered by its exact text
    /// (`SimpleCommand.isKeyedExactly`).
    static func isKeyedExactly(text: String, executable: String) -> Bool {
        if keywords.contains(executable) || interpreters.contains(executable) || executable.hasPrefix("python") {
            return true
        }
        // A function definition (`f() {`, `f ()`), or a name no program has: whatever could not be read.
        let plain = executable.allSatisfy { $0.isLetter || $0.isNumber || "._+-@:[".contains($0) }
        if !plain || executable.isEmpty || executable.hasSuffix("()") { return true }
        guard let (_, rest, unwrapped) = program(of: text) else { return true }
        return rest.first?.hasPrefix("(") == true || !unwrapped.isDisjoint(with: exactWrappers)
    }

    /// Top-level segments split on control operators outside quotes and parentheses.
    static func segments(of line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var chars = Array(line)
        var index = 0
        var inSingle = false
        var inDouble = false
        var depth = 0
        var inBacktick = false
        var inANSI = false
        while index < chars.count {
            let char = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if inSingle {
                current.append(char)
                if char == "'" { inSingle = false }
            } else if inANSI {
                // `$'…'`: a backslash escapes the next character, a quote among them.
                current.append(char)
                if char == "\\", let next { current.append(next); index += 1 } else if char == "'" { inANSI = false }
            } else if inDouble {
                current.append(char)
                if char == "\\", let next { current.append(next); index += 1 } else if char == "\"" { inDouble = false }
            } else if inBacktick {
                current.append(char)
                if char == "`" { inBacktick = false }
            } else {
                switch char {
                case "\\":
                    current.append(char)
                    if let next { current.append(next); index += 1 }
                case "$" where next == "'":
                    inANSI = true
                    current.append(char); current.append("'"); index += 1
                case "'": inSingle = true; current.append(char)
                case "\"": inDouble = true; current.append(char)
                case "`": inBacktick = true; current.append(char)
                case "(": depth += 1; current.append(char)
                case ")": depth = max(0, depth - 1); current.append(char)
                // Each pattern carries its own `where`: `case ";", "\n" where …` binds it to the newline only,
                // and a `;` inside parentheses would split them.
                case ";" where depth == 0, "\n" where depth == 0:
                    result.append(current); current = ""
                case "|" where depth == 0:
                    if next == "|" { index += 1 }
                    result.append(current); current = ""
                case "&" where depth == 0:
                    if next == "&" {
                        index += 1
                        result.append(current); current = ""
                    } else if next == ">" || (current.last == ">") {
                        current.append(char)  // redirection such as `2>&1` or `&>`
                    } else {
                        result.append(current); current = ""  // background job
                    }
                default: current.append(char)
                }
            }
            index += 1
        }
        result.append(current)
        chars.removeAll()
        return result
    }

    /// The bodies of `$(…)`, backtick, and top-level `(…)` groups in `segment`, outermost only. Quoted
    /// text, `'…'` and `$'…'`, is skipped, and a parenthesis inside quotes does not close a group.
    static func substitutions(in segment: String) -> [String] {
        var bodies: [String] = []
        let chars = Array(segment)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "'" || (char == "$" && index + 1 < chars.count && chars[index + 1] == "'") {
                index = quoteEnd(chars, from: char == "$" ? index + 1 : index)
                continue
            }
            if char == "\\" { index += 2; continue }
            if char == "`" {
                if let close = chars[(index + 1)...].firstIndex(of: "`") {
                    bodies.append(String(chars[(index + 1)..<close]))
                    index = close + 1
                    continue
                }
            }
            let isDollarParen = char == "$" && index + 1 < chars.count && chars[index + 1] == "("
            if isDollarParen || char == "(" {
                let open = isDollarParen ? index + 1 : index
                if let close = closingParenthesis(chars, open: open) {
                    bodies.append(String(chars[(open + 1)..<close]))
                    index = close + 1
                    continue
                }
            }
            index += 1
        }
        return bodies
    }

    /// The index just past the quoted text whose opening quote is at `open`: `'…'` with no escapes,
    /// `$'…'` (when `chars[open - 1]` is `$`) and `"…"` with backslash escapes; the end of the text
    /// when the quote is never closed.
    private static func quoteEnd(_ chars: [Character], from open: Int) -> Int {
        let quote = chars[open]
        let escapes = quote == "\"" || (open > 0 && chars[open - 1] == "$" && quote == "'")
        var cursor = open + 1
        while cursor < chars.count {
            if escapes, chars[cursor] == "\\" {
                cursor += 2
                continue
            }
            if chars[cursor] == quote { return cursor + 1 }
            cursor += 1
        }
        return chars.count
    }

    /// The index of the `)` that closes the `(` at `open`, skipping quoted text and escapes; nil when
    /// it is never closed.
    private static func closingParenthesis(_ chars: [Character], open: Int) -> Int? {
        var depth = 0
        var cursor = open
        while cursor < chars.count {
            switch chars[cursor] {
            case "\\":
                cursor += 2
                continue
            case "'", "\"":
                cursor = quoteEnd(chars, from: cursor)
                continue
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return cursor }
            default: break
            }
            cursor += 1
        }
        return nil
    }

    /// The program a segment runs, or nil for a bare subshell or assignment-only segment.
    static func executable(of segment: String) -> String? { essential(of: segment)?.executable }

    /// The program and, for a multiplexer, its verb: the first word after the program that is not an
    /// option, an option's value, or a toolchain selector such as `+nightly`. `git -C dir status`
    /// gives `status`; `git --version` gives no verb.
    static func essential(of segment: String) -> (executable: String, subcommand: String?)? {
        guard let (name, rest, _) = program(of: segment) else { return nil }
        guard Multiplexers.programs.contains(name) else { return (name, nil) }
        var words = rest
        while let word = words.first {
            words.removeFirst()
            if word.hasPrefix("-") {
                if valueOptions.contains(word), !words.isEmpty { words.removeFirst() }
                continue
            }
            if word.hasPrefix("+") { continue }
            let isVerb =
                word.first?.isLetter == true && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return (name, isVerb ? word : nil)
        }
        return (name, nil)
    }

    /// The program name and the words after it, with wrappers and assignments unwrapped, and the
    /// wrappers that were.
    private static func program(of segment: String) -> (String, [String], Set<String>)? {
        var words = words(of: segment)
        var unwrapped: Set<String> = []
        while let first = words.first {
            if first.hasPrefix("(") || first.hasPrefix("$(") || first.hasPrefix("`") { return nil }
            let isAssignment =
                first.contains("=") && !first.hasPrefix("=")
                && first.split(separator: "=", maxSplits: 1)[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isAssignment {
                words.removeFirst()
                continue
            }
            let name = String(first.split(separator: "/").last ?? Substring(first))
            if wrappers.contains(name) {
                unwrapped.insert(name)
                words.removeFirst()
                // Skip a wrapper's own options such as `sudo -u root`, `nice -n 10`, or `timeout 5`.
                while let option = words.first, option.hasPrefix("-") || (name == "timeout" && Double(option) != nil) {
                    words.removeFirst()
                    if Self.valueOptions.contains(option), !words.isEmpty { words.removeFirst() }
                }
                continue
            }
            words.removeFirst()
            return (name, words, unwrapped)
        }
        return nil
    }

    /// Whitespace-separated words, honouring quotes so an argument with spaces stays one word: `'…'`
    /// literally, `"…"` and `$'…'` with backslash escapes (kept as the escaped character, not
    /// interpreted). A backslash before a newline continues the line and leaves nothing.
    static func words(of segment: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var inANSI = false
        var previousWasEscape = false
        var previous: Character?
        for char in segment {
            defer { previous = char }
            if inSingle {
                if char == "'" { inSingle = false } else { current.append(char) }
            } else if previousWasEscape {
                if char != "\n" { current.append(char) }
                previousWasEscape = false
            } else if char == "\\" {
                previousWasEscape = true
            } else if inANSI {
                if char == "'" { inANSI = false } else { current.append(char) }
            } else if inDouble {
                if char == "\"" { inDouble = false } else { current.append(char) }
            } else if char == "'" {
                if previous == "$", current.last == "$" {
                    current.removeLast()
                    inANSI = true
                } else {
                    inSingle = true
                }
            } else if char == "\"" {
                inDouble = true
            } else if char.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

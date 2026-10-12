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
    ///
    /// Compound commands are read clause by clause (`clause(of:caseOpen:)`): `do X`, `then X`, `if X`, `! X`,
    /// and a case branch's `a) X` are judged as `X`; a loop header (`for f in *.txt`) and a closing keyword
    /// (`done`, `fi`) run nothing of their own; and a command that uses a loop's variable carries what the
    /// variable ranges over (`rm "$f" # f in *.txt`), so the rules see what it can hold.
    private static func split(_ line: String, depth: Int) -> [SimpleCommand] {
        guard depth < maxDepth else {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [SimpleCommand(text: text, executable: text)]
        }
        var commands: [SimpleCommand] = []
        var openCases = 0
        var loops: [LoopVariable] = []
        for segment in segments(of: line) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let before = commands.count
            for nested in substitutions(in: trimmed) {
                commands += split(nested, depth: depth + 1)
            }
            let clause = clause(of: trimmed, caseOpen: openCases > 0)
            openCases = max(0, openCases + clause.caseDelta)
            if let loop = clause.loop { loops.append(loop) }
            // A loop header, or `do`, `fi`, or `esac` alone, runs nothing of its own.
            guard let body = clause.body else { continue }
            if let essential = essential(of: body) {
                commands.append(
                    SimpleCommand(
                        text: annotated(body, loops: loops), executable: essential.executable,
                        subcommand: essential.subcommand))
                for script in innerScripts(of: body) {
                    commands += split(script, depth: depth + 1)
                }
            } else if commands.count == before || runsASubstitution(body) {
                // Nothing could be read from it (an assignment, an unbalanced group, a bare `()`), or the program
                // is what a substitution prints (`$(echo rm) -rf x`): it is judged as written rather than not at all.
                commands.append(SimpleCommand(text: body, executable: body))
            }
        }
        return commands
    }

    /// The variable a `for` or `select` header binds, and the words it ranges over as written.
    struct LoopVariable: Equatable, Sendable {
        /// The variable's name.
        var name: String
        /// What it ranges over, as written (`*.txt`, `$(ls)`); `"$@"` for a header without `in`.
        var values: String
    }

    /// What one segment of a compound command runs.
    struct Clause: Equatable, Sendable {
        /// The command the segment runs, as written, or nil when it runs nothing of its own (a loop header,
        /// `do`, `then`, `done`, `fi`, `esac`, or `}` alone).
        var body: String?
        /// The variable a `for` or `select` header binds.
        var loop: LoopVariable?
        /// `case` headers opened (+1) or `esac` closed (-1) by the segment.
        var caseDelta = 0
    }

    /// Keywords that only introduce the command after them.
    static let leadingKeywords: Set<String> = ["do", "then", "else", "elif", "if", "while", "until", "!", "{"]

    /// Keywords that close a compound command and run nothing.
    static let closingKeywords: Set<String> = ["done", "fi", "esac", "}"]

    /// Reads one segment as a clause of a compound command. Keywords are recognised only as written bare (a
    /// quoted `"do"` is a program's name), and a case branch's pattern (`a)`, `*)`) only while a `case` is
    /// open. A closing keyword with more after it (`done > out.txt`) is judged as written, since what follows
    /// applies to the whole compound command.
    ///
    /// - Parameters:
    ///   - segment: One trimmed segment from `segments(of:)`.
    ///   - caseOpen: Whether an earlier segment of the line opened a `case` not yet closed.
    /// - Returns: The clause.
    static func clause(of segment: String, caseOpen: Bool) -> Clause {
        let chars = Array(segment)
        let words = tokens(of: segment)
        var clause = Clause()
        var inCase = caseOpen
        var index = 0
        func rest(from position: Int) -> String? {
            guard position < words.count else { return nil }
            return String(chars[words[position].start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while index < words.count {
            let raw = words[index].raw
            let next = index + 1 < words.count ? words[index + 1].raw : nil
            if leadingKeywords.contains(raw) {
                index += 1
            } else if closingKeywords.contains(raw), index == 0 {
                if raw == "esac" { clause.caseDelta -= 1 }
                clause.body = words.count > 1 ? segment : nil
                return clause
            } else if raw == "for" || raw == "select" {
                // `for NAME [in WORDS]`; without `in` it ranges over the arguments. `for ((…))` binds nothing.
                if let name = next, !name.hasPrefix("(") {
                    let hasIn = index + 2 < words.count && words[index + 2].raw == "in"
                    clause.loop = LoopVariable(name: name, values: hasIn ? rest(from: index + 3) ?? "" : #""$@""#)
                }
                return clause
            } else if raw == "case" {
                guard index + 2 < words.count, words[index + 2].raw == "in" else {
                    clause.body = rest(from: index)
                    return clause
                }
                clause.caseDelta += 1
                inCase = true
                index += 3
            } else if raw == "function", next != nil {
                index += 2
                if index < words.count, words[index].raw == "()" { index += 1 }
            } else if next == "()" {
                index += 2  // `f () {`
            } else if raw.count > 2, raw.hasSuffix("()") {
                index += 1  // `f() {`
            } else if inCase, raw.hasSuffix(")"), !raw.contains("(") {
                index += 1  // a case branch's pattern
            } else {
                break
            }
        }
        clause.body = rest(from: index)
        return clause
    }

    /// `body` with ` # NAME in VALUES` added for each loop variable it uses, so the rules judge `rm "$f"` in
    /// `for f in ~/*` by what `$f` ranges over. The key is unchanged: the program is the same.
    static func annotated(_ body: String, loops: [LoopVariable]) -> String {
        var text = body
        for loop in loops where uses(body, variable: loop.name) {
            text += " # \(loop.name) in \(loop.values)"
        }
        return text
    }

    /// Whether `text` expands the variable `name` (`$name`, `${name}`, `${name:-x}`).
    static func uses(_ text: String, variable name: String) -> Bool {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let pattern = #"\$(\{"# + name + #"\b|"# + name + #"(?![A-Za-z0-9_]))"#
        return (try? RegexCache.regex(pattern))?.matches(anywhereIn: text) == true
    }

    /// Whether the program a segment runs is what a substitution prints (`$(which tool) args`, `` `x` y``).
    static func runsASubstitution(_ segment: String) -> Bool {
        guard let word = unwrap(segment)?.first else { return false }
        return word.raw.hasPrefix("$(") || word.raw.hasPrefix("`")
    }

    /// Whether the program a segment runs is chosen when it runs: its name, after keywords, wrappers, and
    /// assignments, is a variable or a substitution (`$X args`, `"${TOOL}" x`, `$(which rm) -rf`, `/bin/$X`),
    /// so its name says nothing of what runs. A variable naming only a directory (`$HOME/bin/tool`) does not
    /// count: the program's own name is still written.
    static func programIsChosenAtRunTime(_ segment: String) -> Bool {
        guard let body = clause(of: segment, caseOpen: false).body, let word = unwrap(body)?.first else {
            return false
        }
        if word.raw.hasPrefix("$(") || word.raw.hasPrefix("`") { return true }
        let name = word.value.split(separator: "/").last.map(String.init) ?? word.value
        return name.contains("$") || name.contains("`")
    }

    /// The command lines a segment hands to a shell: the argument of `sh -c`, `bash -lc`, and the like,
    /// and the words after `eval`, which the shell runs as a line of their own.
    static func innerScripts(of segment: String) -> [String] {
        guard let (name, rest, _) = program(of: segment) else { return [] }
        if name == "eval" { return rest.isEmpty ? [] : [rest.joined(separator: " ")] }
        if name == "find" { return executed(byFind: rest) }
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

    /// The commands `find` runs for each match: the words after `-exec`, `-execdir`, `-ok`, or `-okdir` up to
    /// the `;` or `+` that ends them, quoted again as one line, so `-exec sh -c 'rm {}' \;` is judged as
    /// `sh -c 'rm {}'`, and the script inside it too.
    static func executed(byFind words: [String]) -> [String] {
        var commands: [String] = []
        var remaining = words[...]
        while let word = remaining.popFirst() {
            guard ["-exec", "-execdir", "-ok", "-okdir"].contains(word) else { continue }
            var command: [String] = []
            while let next = remaining.popFirst(), next != ";", next != "+" {
                command.append(next)
            }
            if !command.isEmpty { commands.append(command.map(shellWord).joined(separator: " ")) }
        }
        return commands
    }

    /// `word` as it must be written to stay one shell word: as it is when it holds nothing special, quoted
    /// otherwise.
    static func shellWord(_ word: String) -> String {
        let plain = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "_./{}=+:@,%-".contains($0) }
        return plain ? word : quoted(word)
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
    /// text, `'…'` and `$'…'`, is skipped, and a parenthesis inside quotes does not close a group. Inside `"…"`
    /// only `$(…)` and backticks are substitutions: a `(` there is a character (`grep -E "a (b|c)"`), and so is
    /// a `'` (`"it's $(x)"`, whose substitution is still found).
    static func substitutions(in segment: String) -> [String] {
        var bodies: [String] = []
        let chars = Array(segment)
        var index = 0
        var inDouble = false
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                inDouble.toggle()
                index += 1
                continue
            }
            if !inDouble, char == "'" || (char == "$" && index + 1 < chars.count && chars[index + 1] == "'") {
                index = quoteEnd(chars, from: char == "$" ? index + 1 : index)
                continue
            }
            if char == "\\" { index += 2; continue }
            if inDouble, char == "(" {
                index += 1
                continue
            }
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

    /// The program name and the words after it, with wrappers and assignments unwrapped, and the wrappers that
    /// were; nil for a bare subshell, a substitution in the program's place, or assignments alone.
    private static func program(of segment: String) -> (String, [String], Set<String>)? {
        guard let (first, rest, unwrapped) = unwrap(segment) else { return nil }
        if first.raw.hasPrefix("(") || first.raw.hasPrefix("$(") || first.raw.hasPrefix("`") { return nil }
        let name = String(first.value.split(separator: "/").last ?? Substring(first.value))
        return (name, rest.map(\.value), unwrapped)
    }

    /// `segment`'s words with wrappers (and their options) and assignments taken off the front: the word in
    /// the program's place, the words after it, and the wrappers that were unwrapped; nil for assignments
    /// alone.
    private static func unwrap(_ segment: String) -> (first: Word, rest: [Word], unwrapped: Set<String>)? {
        var words = tokens(of: segment)[...]
        var unwrapped: Set<String> = []
        while let first = words.first {
            let value = first.value
            let isAssignment =
                !first.raw.hasPrefix("(") && !first.raw.hasPrefix("$(") && value.contains("=") && !value.hasPrefix("=")
                && value.split(separator: "=", maxSplits: 1)[0].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            if isAssignment {
                words.removeFirst()
                continue
            }
            let name = String(value.split(separator: "/").last ?? Substring(value))
            if wrappers.contains(name) {
                unwrapped.insert(name)
                words.removeFirst()
                // Skip a wrapper's own options such as `sudo -u root`, `nice -n 10`, or `timeout 5`.
                while let option = words.first?.value,
                    option.hasPrefix("-") || (name == "timeout" && Double(option) != nil)
                {
                    words.removeFirst()
                    if Self.valueOptions.contains(option), !words.isEmpty { words.removeFirst() }
                }
                continue
            }
            words.removeFirst()
            return (first, Array(words), unwrapped)
        }
        return nil
    }

    /// One word of a segment.
    struct Word: Equatable, Sendable {
        /// The word as the shell reads it: quotes removed, escapes and `$'…'` read.
        var value: String
        /// The word as written, quotes and escapes included.
        var raw: String
        /// Where it starts in the segment, as a character offset.
        var start: Int
        /// Whether any of it was quoted or escaped, so that `value` and `raw` differ.
        var isQuoted: Bool { value != raw }
    }

    /// Whitespace-separated words, honouring quotes so an argument with spaces stays one word: `'…'`
    /// literally, `"…"` and `$'…'` with backslash escapes (kept as the escaped character, not
    /// interpreted). A backslash before a newline continues the line and leaves nothing, and an unquoted
    /// `$IFS` or `${IFS}` separates words as a space would (`rm${IFS}-rf` is `rm -rf`).
    static func words(of segment: String) -> [String] {
        tokens(of: segment).map(\.value).filter { !$0.isEmpty }
    }

    /// The words of `segment`, as `words(of:)` reads them, each with its spelling and where it starts. A word
    /// written as an empty quote (`''`) is kept, with an empty value; a line continuation alone is not.
    static func tokens(of segment: String) -> [Word] {
        let chars = Array(segment)
        var result: [Word] = []
        var current = ""
        var start: Int?
        var inSingle = false
        var inDouble = false
        var inANSI = false
        var index = 0
        func finish(at end: Int) {
            if let begin = start {
                let raw = String(chars[begin..<end])
                if !current.isEmpty || raw.contains("'") || raw.contains("\"") {
                    result.append(Word(value: current, raw: raw, start: begin))
                }
            }
            current = ""
            start = nil
        }
        while index < chars.count {
            let char = chars[index]
            let quoted = inSingle || inDouble || inANSI
            if !quoted, char.isWhitespace {
                finish(at: index)
                index += 1
                continue
            }
            if !quoted, char == "$", let length = ifsLength(chars, at: index) {
                finish(at: index)
                index += length
                continue
            }
            if start == nil { start = index }
            if inSingle {
                if char == "'" { inSingle = false } else { current.append(char) }
            } else if char == "\\" {
                if index + 1 < chars.count {
                    index += 1
                    if chars[index] != "\n" { current.append(chars[index]) }
                }
            } else if inANSI {
                if char == "'" { inANSI = false } else { current.append(char) }
            } else if inDouble {
                if char == "\"" { inDouble = false } else { current.append(char) }
            } else if char == "'" {
                if index > 0, chars[index - 1] == "$", current.last == "$" {
                    current.removeLast()
                    inANSI = true
                } else {
                    inSingle = true
                }
            } else if char == "\"" {
                inDouble = true
            } else {
                current.append(char)
            }
            index += 1
        }
        finish(at: chars.count)
        return result
    }

    /// The length of an unquoted `$IFS` or `${IFS}` at `index`, or nil when there is none there.
    private static func ifsLength(_ chars: [Character], at index: Int) -> Int? {
        let ahead = String(chars[index..<min(chars.count, index + 6)])
        if ahead == "${IFS}" { return 6 }
        guard ahead.hasPrefix("$IFS") else { return nil }
        let after = index + 4 < chars.count ? chars[index + 4] : nil
        return after.map { $0.isLetter || $0.isNumber || $0 == "_" } == true ? nil : 4
    }
}

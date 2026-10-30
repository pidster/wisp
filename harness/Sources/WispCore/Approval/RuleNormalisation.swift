import Foundation

/// The second spelling of a command the rules (and the deny patterns) run over: quoting, escapes, line
/// continuations, `$IFS`, and git's global options taken away, so `'rm' -rf`, `w''isp`, `rm${IFS}-rf`, and
/// `git -C . push --force` read as what runs. The text, pattern, and file arguments of programs that only
/// print or search (`echo`, `printf`, the pattern of `grep` and `rg`, the script of `sed`, a `git commit -m`
/// message) stay as written: they are data, and unquoting them made a search for `"a|sh"` read as a pipe into
/// a shell (0.21.1). Beside it, the same line with that data written `''` (`Spellings`), for the rules that look
/// for what the shell runs: a pipe, a list, a redirection, or a program's name inside a pattern is none of those
/// (the 0.22.0 eval, 2026-10-12).
///
/// ``CommandPolicy/check(_:)`` reads the same spellings, so the deny patterns and the rules see a command alike.
/// `docs/approval.md` lists what is data for each program.
extension RuleRiskClassifier {
    /// Git's options that come before the verb and take a separate value.
    private static let gitValueOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env", "--super-prefix",
    ]

    /// Another spelling of `command` for the rules: its words (quotes removed, `$'…'` read, line continuations
    /// joined, `$IFS` read as a space) joined by single spaces, with git's global options (`-C <dir>`,
    /// `-c <k=v>`, `--no-pager`, `--git-dir=…`) dropped so the verb follows `git` directly, and the quoted data
    /// arguments of printing and searching programs kept as written (`DataArguments`).
    ///
    /// - Parameter command: The command line.
    /// - Returns: The one normalised spelling, in an array.
    static func normalisedForms(of command: String) -> [String] { [spellings(of: command).normalised] }

    /// The spellings of one command line the rules run over.
    struct Spellings: Equatable {
        /// `normalisedForms`: words unquoted, data kept as written.
        var normalised: String
        /// `normalised` with every data argument written `''`: the commands the line runs, and nothing they print
        /// or search for.
        var maskedNormalised: String
        /// The line as written with every data argument written `''`.
        var maskedRaw: String
        /// Every word unquoted, data included, as 0.21.2 spelled the line: what a file the shell runs at start-up
        /// would hold, were this line's output written into it.
        var unquoted: String
    }

    /// The spellings of `command`: as `normalisedForms`, and with its data masked (`masked(_:)`), so the rules
    /// that look for a pipe, a list, a redirection, or a program's name see only what the shell runs.
    ///
    /// One pass over the line's tokens: each simple command's program starts a ``DataArguments`` that says which
    /// of its arguments are data, and an operator ends it. `maskedRaw` blanks the data in the original text by
    /// position, so everything else keeps its spelling.
    ///
    /// - Parameter command: The command line.
    /// - Returns: Its spellings.
    static func spellings(of command: String) -> Spellings {
        var words: [String] = []
        var masked: [String] = []
        var blanks: [(start: Int, length: Int)] = []
        let tokens = CommandSplitter.tokens(of: command).filter { !$0.value.isEmpty }
        var remaining = tokens[...]
        var arguments: DataArguments?
        while let token = remaining.popFirst() {
            // A word that starts with an operator (`|grep`) starts the next command.
            if let first = token.raw.first, "|;&".contains(first) { arguments = nil }
            var isData = false
            if var current = arguments {
                isData = current.isData(token)
                arguments = current
                let written = isData && token.isQuoted ? token.raw : token.value
                words.append(written)
                if isData, Self.canMask(token.raw) {
                    masked.append(Self.blank)
                    blanks.append((token.start, token.raw.count))
                } else {
                    masked.append(written)
                }
            } else {
                words.append(token.value)
                masked.append(token.value)
                let program = token.value.drop { "|;&".contains($0) }
                if !program.isEmpty, !Self.isPrefix(String(program)) {
                    arguments = DataArguments(program: String(program.split(separator: "/").last ?? program))
                }
            }
            if !isData, token.value == "git" || token.value.hasSuffix("/git") {
                while let option = remaining.first?.value, option.hasPrefix("-") {
                    remaining.removeFirst()
                    let name = String(option.prefix { $0 != "=" })
                    if gitValueOptions.contains(name), !option.contains("="), !remaining.isEmpty {
                        remaining.removeFirst()
                    }
                }
            }
            // A word that ends the command (`x;`) or holds an operator (`a;rm`) leaves nothing after it as data.
            if Self.endsCommand(token.raw) || Self.holdsAnOperator(token.raw) { arguments = nil }
        }
        var raw = Array(command)
        for blank in blanks.reversed() {
            raw.replaceSubrange(blank.start..<(blank.start + blank.length), with: Self.blank)
        }
        return Spellings(
            normalised: words.joined(separator: " "), maskedNormalised: masked.joined(separator: " "),
            maskedRaw: String(raw), unquoted: CommandSplitter.words(of: command).joined(separator: " "))
    }

    /// What a masked data argument is written as: an empty quoted word, so it is still one argument.
    private static let blank = "''"

    /// Whether a data argument written `raw` can be masked: it runs nothing and ends nothing, so blanking it
    /// hides no command. A word with an unquoted operator, parenthesis, or backslash (`x|sh`, `a;`), any
    /// substitution (`"$(rm -rf ~)"`, even in single quotes, which only ever keeps a rule's verdict), or an
    /// unclosed quote is left as it is.
    ///
    /// - Parameter raw: The word as written.
    /// - Returns: True when blanking it is safe.
    static func canMask(_ raw: String) -> Bool {
        guard !raw.contains("$("), !raw.contains("`") else { return false }
        var quote: Character?
        var escapes = false
        var previous: Character?
        var skip = false
        for char in raw {
            defer { previous = char }
            if skip {
                skip = false
                continue
            }
            if let open = quote {
                if escapes, char == "\\" {
                    skip = true
                } else if char == open {
                    quote = nil
                }
                continue
            }
            switch char {
            case "'":
                quote = "'"
                escapes = previous == "$"
            case "\"":
                quote = "\""
                escapes = true
            case "|", ";", "&", "<", ">", "(", ")", "\\": return false
            default: break
            }
        }
        return quote == nil
    }

    /// Whether a word written `raw` holds an unquoted, unescaped `;`, `|`, or `&` that is not part of a redirection
    /// (`2>&1`, `&>`): the shell ends a command there, so what follows starts another (`echo a;rm -rf ~`).
    ///
    /// - Parameter raw: The word as written.
    /// - Returns: True when it holds such an operator.
    static func holdsAnOperator(_ raw: String) -> Bool {
        let chars = Array(raw)
        var quote: Character?
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if let open = quote {
                if char == "\\", open == "\"" {
                    index += 1
                } else if char == open {
                    quote = nil
                }
            } else if char == "\\" {
                index += 1
            } else if char == "'" || char == "\"" {
                quote = char
            } else if char == ";" || char == "|" {
                return true
            } else if char == "&" {
                let before = index > 0 ? chars[index - 1] : nil
                let after = index + 1 < chars.count ? chars[index + 1] : nil
                if before != ">", after != ">" { return true }
            }
            index += 1
        }
        return false
    }

    /// Whether `word`, at the start of a simple command, comes before its program: a wrapper or its option or
    /// count (`sudo`, `-u`, `timeout 5`), a keyword (`do`, `then`, `!`), or an assignment (`NO_COLOR=1`).
    ///
    /// - Parameter word: The word's value.
    /// - Returns: True when the program is still to come.
    private static func isPrefix(_ word: String) -> Bool {
        let name = String(word.split(separator: "/").last ?? Substring(word))
        if CommandSplitter.wrappers.contains(name) || CommandSplitter.leadingKeywords.contains(word) { return true }
        if word.hasPrefix("-") || Double(word) != nil { return true }
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Whether a word written as `raw` ends the simple command it is in: an operator, or a word ending in an
    /// unescaped `;`, `|`, or `&` (`x;`), but not a redirection such as `2>&`.
    ///
    /// - Parameter raw: The word as written.
    /// - Returns: True when the command ends with it.
    private static func endsCommand(_ raw: String) -> Bool {
        guard let last = raw.last, "|;&".contains(last) else { return false }
        return !raw.dropLast().hasSuffix("\\") && !raw.dropLast().hasSuffix(">")
    }
}

/// Which arguments of a simple command are data its program never runs: every argument of `echo` and
/// `printf`; the pattern of `grep`, `egrep`, `fgrep`, `rg`, `ag`, and `git grep` (the value of `-e`, or the first
/// argument when there is none); the pattern of `pgrep` and `pkill`, which names the processes and is not run; the
/// script of `sed` (the value of `-e`, or the first argument); the program of `awk` and its field separator, unless
/// the program runs a command, reads one, or writes a file (`awkRuns(_:)`); and the message of `git … -m`. File
/// names are never data, so a credential path is seen however it is quoted, and nor is a redirection's target.
///
/// A small state machine fed one argument at a time, since whether a word is data depends on the options before
/// it. A program not listed here has no data: every argument is read as written.
struct DataArguments {
    /// The program, without its directory.
    let program: String
    /// Whether the previous word was an option that takes the next word as its value.
    private var expectingValue = false
    /// Whether that value is data (a pattern, a script, a message) rather than a file or a number.
    private var valueIsData = false
    /// Whether the pattern or script has been given, so later arguments are files.
    private var patternGiven = false
    /// Whether the previous word was a redirection operator, whose target comes next.
    private var afterRedirection = false
    /// Whether the previous word was `sed -i` or `-I`, which may be followed by a backup suffix.
    private var maybeSuffix = false
    /// Git's verb, once it is seen: `grep` reads its arguments as `grep` does.
    private var gitVerb: String?

    /// The programs whose first argument (or `-e` value) is data, each with the family whose options it takes.
    static let families: [String: String] = [
        "grep": "grep", "egrep": "grep", "fgrep": "grep", "ag": "grep", "rg": "rg", "sed": "sed", "pgrep": "pgrep",
        "pkill": "pgrep", "awk": "awk", "gawk": "awk", "nawk": "awk", "mawk": "awk",
    ]

    /// Options of each family that take a value that is not the pattern or script.
    static let valueOptions: [String: Set<String>] = [
        "grep": [
            "-A", "-B", "-C", "-m", "-d", "-D", "--context", "--after-context", "--before-context",
            "--max-count", "--include", "--exclude", "--exclude-dir", "--label", "--max-depth", "--threads",
        ],
        "rg": [
            "-A", "-B", "-C", "-m", "-g", "--glob", "-t", "--type", "-T", "--type-not", "-j", "--threads",
            "-r", "--replace", "-M", "--max-columns", "-E", "--encoding", "--max-depth",
        ],
        "sed": ["-l", "--line-length"],
        "pgrep": ["-d", "-F", "-G", "-g", "-j", "-M", "-N", "-P", "-t", "-U", "-u"],
        "awk": ["-v"],
    ]

    /// Creates the state for `program`'s arguments.
    ///
    /// - Parameter program: The program's name, without its directory.
    init(program: String) { self.program = program }

    /// Whether `word`, the next argument, is data; updates the state for the words after it.
    ///
    /// - Parameter word: The next argument.
    /// - Returns: True when it is data the program never runs.
    mutating func isData(_ word: CommandSplitter.Word) -> Bool {
        let value = word.value
        if afterRedirection {
            afterRedirection = false
            return false
        }
        if let match = value.firstMatch(of: /^\d*(>>?|<|&>)/) {
            afterRedirection = match.output.0.count == value.count
            return false
        }
        if program == "echo" || program == "printf" { return true }
        if expectingValue {
            expectingValue = false
            return valueIsData
        }
        var family = Self.families[program]
        if program == "git" {
            if gitVerb == nil, !value.hasPrefix("-") {
                gitVerb = value
                return false
            }
            guard gitVerb == "grep" else {
                expectingValue = value == "-m" || value == "--message"
                valueIsData = true
                return value.hasPrefix("--message=")
            }
            family = "grep"
        }
        guard let family else { return false }
        if maybeSuffix {
            maybeSuffix = false
            if value.hasPrefix(".") { return false }
        }
        guard value.hasPrefix("-"), value != "-" else {
            defer { patternGiven = true }
            return !patternGiven && (family != "awk" || !Self.awkRuns(value))
        }
        let dataOptions: Set<String> =
            switch family {
            case "sed": ["-e", "--expression"]
            case "grep", "rg": ["-e", "--regexp"]
            case "awk": ["-F"]
            default: []
            }
        // `pgrep -f` matches the full argument list; it names no file.
        let namesAFile = family != "pgrep" && (value == "-f" || value == "--file")
        if dataOptions.contains(value) || namesAFile {
            expectingValue = true
            valueIsData = dataOptions.contains(value)
            // An awk field separator is not its program; a program file means there is none on the line.
            if value != "-F" { patternGiven = true }
        } else if value.hasPrefix("--regexp=") || value.hasPrefix("--expression=") {
            patternGiven = true
            return true
        } else if family == "awk", value.hasPrefix("-F") {
            return true
        } else if family == "sed", value == "-i" || value == "-I" {
            maybeSuffix = true
        } else if Self.valueOptions[family]?.contains(value) == true {
            expectingValue = true
            valueIsData = false
        }
        return false
    }

    /// Whether an awk program does more than read its input and print: it runs a command (`system(…)`,
    /// `print | "sh"`, `"cmd" | getline`, `|&`), reads another file (`getline`), or writes one (`print > "f"`).
    /// Its strings are taken out first, so a `|` or `>` printed (`printf "%s | %s"`, `" => "`) is not mistaken
    /// for one; a comparison outside a print (`NF>6`) is not a redirection.
    ///
    /// - Parameter program: The awk program's text.
    /// - Returns: True when it runs, reads, or writes something; its text is then not data.
    static func awkRuns(_ program: String) -> Bool {
        let code = program.replacing(/"(\\.|[^"\\])*"/, with: "\"\"")
        return code.contains(/system\s*\(|\bgetline\b|\|&|\b(print|printf)\b[^;}]*[|>]/)
    }
}

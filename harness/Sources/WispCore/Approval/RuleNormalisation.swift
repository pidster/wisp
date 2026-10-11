import Foundation

/// The second spelling of a command the rules (and the deny patterns) run over: quoting, escapes, line
/// continuations, `$IFS`, and git's global options taken away, so `'rm' -rf`, `w''isp`, `rm${IFS}-rf`, and
/// `git -C . push --force` read as what runs. The text, pattern, and file arguments of programs that only
/// print or search (`echo`, `printf`, the pattern of `grep` and `rg`, the script of `sed`, a `git commit -m`
/// message) stay as written: they are data, and unquoting them made a search for `"a|sh"` read as a pipe into
/// a shell (0.21.1).
extension RuleRiskClassifier {
    /// Git's options that come before the verb and take a separate value.
    private static let gitValueOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env", "--super-prefix",
    ]

    /// Another spelling of `command` for the rules: its words (quotes removed, `$'…'` read, line continuations
    /// joined, `$IFS` read as a space) joined by single spaces, with git's global options (`-C <dir>`,
    /// `-c <k=v>`, `--no-pager`, `--git-dir=…`) dropped so the verb follows `git` directly, and the quoted data
    /// arguments of printing and searching programs kept as written (`DataArguments`).
    static func normalisedForms(of command: String) -> [String] {
        var words: [String] = []
        var remaining = CommandSplitter.tokens(of: command).filter { !$0.value.isEmpty }[...]
        var arguments: DataArguments?
        while let token = remaining.popFirst() {
            // A word that starts with an operator (`|grep`) starts the next command.
            if let first = token.raw.first, "|;&".contains(first) { arguments = nil }
            var isData = false
            if var current = arguments {
                isData = current.isData(token)
                arguments = current
                words.append(isData && token.isQuoted ? token.raw : token.value)
            } else {
                words.append(token.value)
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
            if Self.endsCommand(token.raw) { arguments = nil }
        }
        return [words.joined(separator: " ")]
    }

    /// Whether `word`, at the start of a simple command, comes before its program: a wrapper or its option or
    /// count (`sudo`, `-u`, `timeout 5`), a keyword (`do`, `then`, `!`), or an assignment (`NO_COLOR=1`).
    private static func isPrefix(_ word: String) -> Bool {
        let name = String(word.split(separator: "/").last ?? Substring(word))
        if CommandSplitter.wrappers.contains(name) || CommandSplitter.leadingKeywords.contains(word) { return true }
        if word.hasPrefix("-") || Double(word) != nil { return true }
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Whether a word written as `raw` ends the simple command it is in: an operator, or a word ending in an
    /// unescaped `;`, `|`, or `&` (`x;`), but not a redirection such as `2>&`.
    private static func endsCommand(_ raw: String) -> Bool {
        guard let last = raw.last, "|;&".contains(last) else { return false }
        return !raw.dropLast().hasSuffix("\\") && !raw.dropLast().hasSuffix(">")
    }
}

/// Which arguments of a simple command are data its program never runs: every argument of `echo` and
/// `printf`; the pattern of `grep`, `egrep`, `fgrep`, `rg`, and `ag` (the value of `-e`, or the first
/// argument when there is none); the script of `sed` (the value of `-e`, or the first argument); and the
/// message of `git … -m`. File names are never data, so a credential path is seen however it is quoted, and
/// nor is a redirection's target.
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

    /// The searching programs whose first argument is a pattern.
    static let searchers: Set<String> = ["grep", "egrep", "fgrep", "rg", "ag"]

    /// Options of the searching programs and `sed` that take a value that is not the pattern or script.
    static let valueOptions: [String: Set<String>] = [
        "grep": [
            "-A", "-B", "-C", "-m", "-d", "-D", "--context", "--after-context", "--before-context",
            "--max-count", "--include", "--exclude", "--exclude-dir", "--label",
        ],
        "rg": [
            "-A", "-B", "-C", "-m", "-g", "--glob", "-t", "--type", "-T", "--type-not", "-j", "--threads",
            "-r", "--replace", "-M", "--max-columns", "-E", "--encoding", "--max-depth",
        ],
        "sed": ["-l", "--line-length"],
    ]

    /// Creates the state for `program`'s arguments.
    init(program: String) { self.program = program }

    /// Whether `word`, the next argument, is data; updates the state for the words after it.
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
        if program == "git" {
            expectingValue = value == "-m" || value == "--message"
            valueIsData = true
            return value.hasPrefix("--message=")
        }
        let family = Self.searchers.contains(program) ? (program == "rg" ? "rg" : "grep") : program
        guard family == "grep" || family == "rg" || family == "sed" else { return false }
        if maybeSuffix {
            maybeSuffix = false
            if value.hasPrefix(".") { return false }
        }
        guard value.hasPrefix("-"), value != "-" else {
            defer { patternGiven = true }
            return !patternGiven
        }
        let dataOptions: Set<String> = family == "sed" ? ["-e", "--expression"] : ["-e", "--regexp"]
        if dataOptions.contains(value) || value == "-f" || value == "--file" {
            expectingValue = true
            valueIsData = dataOptions.contains(value)
            patternGiven = true
        } else if value.hasPrefix("--regexp=") || value.hasPrefix("--expression=") {
            patternGiven = true
            return true
        } else if family == "sed", value == "-i" || value == "-I" {
            maybeSuffix = true
        } else if Self.valueOptions[family]?.contains(value) == true {
            expectingValue = true
            valueIsData = false
        }
        return false
    }
}

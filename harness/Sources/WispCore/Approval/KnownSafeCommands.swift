import Foundation

/// Simple commands the rules know to be read-only, so the gate need not ask a model about them
/// ([ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md), amendment).
///
/// A command is known safe only when all of these hold: it matches one of `patterns` from start to
/// end, once harmless redirections (`2>&1`, `>/dev/null`) and a few display-only variables (`NO_COLOR=1`)
/// are removed; it runs nothing else (no `$(…)`, backticks, or process substitution); it writes
/// nowhere; it names nothing sensitive (`sensitive`); and none of `disqualifiers` matches, which catch
/// the options that make a reading program write or run something (`find -exec`, `sort -o`,
/// `rg --pre`). The risky rules are checked first, so a command they match is never known safe. The
/// list is deliberately short: a command left off it is judged as before, never refused.
enum KnownSafeCommands {
    /// One argument: a quoted string or a word without shell operators.
    private static let argument = #"(?:"[^"]*"|'[^']*'|[^\s;&|<>"']+)"#
    /// Any arguments.
    private static let arguments = #"(?:\s+"# + argument + ")*"

    /// Read-only forms, each matched against the whole simple command.
    static let patterns: [String] = [
        #"cd(?:\s+"# + argument + ")?",
        #"(?:pwd|whoami|uptime|sw_vers|arch|tty|true|nproc|vm_stat|groups|id|uname|hostname|locale)"#
            + #"(?:\s+-[A-Za-z]+)*"#,
        #"printenv\s+(?:PATH|HOME|SHELL|USER|PWD|TERM|LANG|TMPDIR)"#,
        #"date(?:\s+(?:-u|-R|\+\S+|'\+[^']*'|"\+[^"]*"))*"#,
        #"(?:echo|printf)"# + arguments,
        #"set(?:\s+[-+][euxvo]+)+(?:\s+pipefail)?"#,
        #"sleep\s+\d+(?:\.\d+)?"#,
        #"history(?:\s+\d+)?"#,
        #"ulimit\s+-a"#,
        #"command\s+-[vV]\s+"# + argument,
        #"(?:test|\[)"# + arguments,
        // Reading and searching files.
        #"(?:cat|head|tail|less|more|wc|file|stat|du|df|tree|ls|basename|dirname|realpath|readlink|shasum"#
            + #"|sha1sum|sha256sum|md5|md5sum|cksum|diff|cmp|strings|hexdump|od|nm|otool|size|dwarfdump|column"#
            + #"|cut|tr|comm|paste|fold|nl|rev|sort|jq|awk|grep|egrep|fgrep|rg|ag|find|mdfind|mdls|which"#
            + #"|whereis|type|man|ps|lsof|netstat|system_profiler)"# + arguments,
        #"uniq(?:\s+-[A-Za-z]+)*"#,
        // Git that reads the repository.
        #"git(?:\s+--no-pager)?\s+(?:status|log|diff|show|blame|rev-parse|ls-files|ls-tree|describe|shortlog"#
            + #"|cat-file|rev-list|merge-base|whatchanged|grep|count-objects|name-rev|for-each-ref|show-ref"#
            + #"|check-ignore|var|version|help)\b"# + arguments,
        #"git(?:\s+--no-pager)?\s+branch(?:\s+(?:-a|-r|-v|-vv|--all|--remotes|--list|--show-current|--merged"#
            + #"|--no-merged|--no-color|--color))*"#,
        #"git(?:\s+--no-pager)?\s+config\s+(?:--global\s+|--local\s+)?(?:--get|--get-all|--get-regexp|--list|-l)\b"#
            + arguments,
        // Asking a tool what it is.
        #"(?:swift|cargo|rustc|rustup|go|node|npm|npx|yarn|pnpm|python3?|ruby|perl|java|clang|gcc|make|cmake"#
            + #"|brew|pip3?|gh|docker|jq|rg|xcodebuild|xcrun|git|sqlite3|psql|ollama|wisp)\s+(?:--version|-v|-V|version)"#,
        #"xcrun\s+(?:--find\s+\S+|-f\s+\S+|--show-sdk-path|--show-sdk-version)"#,
        #"xcode-select\s+(?:-p|--print-path|-v|--version)"#,
        #"xcodebuild\s+(?:-showsdks|-version|-list)\b"# + arguments,
        #"swift\s+package\s+(?:describe|dump-package)\b"# + arguments,
        #"brew\s+(?:list|ls|info|outdated|config|--prefix|--cellar|--repository|deps|leaves|uses|desc)\b"#
            + arguments,
        #"pip3?\s+(?:list|show|freeze)\b"# + arguments,
        #"npm\s+(?:ls|list|root|prefix)\b"# + arguments,
        // The Mac's state.
        #"top\s+-l\s*\d+"# + arguments,
        #"ifconfig(?:\s+[a-z]+\d*)?"#,
        #"sysctl(?:\s+(?:-[an]+|[a-z][\w.]*))*"#,
        #"pmset\s+-g\b"# + arguments,
        #"diskutil\s+(?:list|info)\b"# + arguments,
        #"defaults\s+(?:read|read-type|domains|find)\b"# + arguments,
        #"log\s+show\b"# + arguments,
        #"plutil\s+(?:-p|-lint)\b"# + arguments,
        #"codesign\s+(?:-d\S*|-v\S*|--verify|--display)\b"# + arguments,
        #"lipo\s+(?:-info|-archs|-detailed_info)\b"# + arguments,
    ]

    /// Options that make an otherwise reading program write a file or run a program.
    static let disqualifiers: [String] = [
        #"\s-(?:exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)\b"#,
        #"\s--pre(?:=|\s)"#, #"\s--output\b"#, #"\s--ext-diff\b"#,
        #"^sort\b.*\s-o"#, #"^tree\b.*\s-o\b"#, #"^file\b.*\s-C\b"#, #"^man\b.*\s-P\b"#,
        #"^(?:less|more|man)\b.*\s['"]?\+"#, #"^git\b.*\s(?:-O\S*|--open-files-in-pager)"#,
        #"^codesign\b.*\s(?:-s|--sign|-f|--force|--remove-signature)\b"#,
        #"^awk\b.*\s-f\b"#, #"system\s*\("#, #"\|"#,
    ]

    /// What a command must not name, reading or not: its output reaches the model and the audit log.
    static let sensitive =
        #"(?i)(\.env\b|secret|token|passw|credential|\.pem\b|\.p12\b|\.pfx\b|\.key\b|private|id_rsa|id_ed25519"#
        + #"|id_ecdsa|_history\b|/Library/(?:Messages|Mail|Cookies|Safari|Keychains)|TCC\.db|\.sqlite\b|\.db\b"#
        + #"|/etc/(?:master\.passwd|shadow|sudoers))"#

    /// Redirections that write nothing, and display-only variables, removed before matching.
    private static let harmless = [
        #"\s+(?:\d|&)?>>?\s*/dev/null\s*$"#, #"\s+\d?>&\d\s*$"#,
        #"^(?:(?:NO_COLOR|CI|LC_[A-Z]+|LANG|TERM|COLUMNS|FORCE_COLOR|CLICOLOR)=\S*\s+)+"#,
    ]

    /// Whether every pattern here compiles; a test fails if one does not.
    static var patternsCompile: Bool {
        (patterns.map { "^(?:\($0))$" } + disqualifiers + harmless + [sensitive]).allSatisfy {
            (try? RegexCache.regex($0)) != nil
        }
    }

    /// Whether `command`, one simple command, is known to be read-only.
    static func contains(_ command: String) -> Bool {
        var text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("$("), !text.contains("`"), !text.contains("<("), !text.contains(">(") else {
            return false
        }
        guard !matches(sensitive, text) else { return false }
        var changed = true
        while changed {
            changed = false
            for pattern in harmless {
                guard let regex = try? RegexCache.regex(pattern) else { return false }
                let shorter = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
                if shorter != text {
                    text = shorter
                    changed = true
                }
            }
        }
        guard !text.contains(">"), !disqualifiers.contains(where: { matches($0, text) }) else { return false }
        return patterns.contains { matches("^(?:\($0))$", text) }
    }

    /// Whether `pattern` matches anywhere in `text`; a pattern that does not compile never matches.
    private static func matches(_ pattern: String, _ text: String) -> Bool {
        (try? RegexCache.regex(pattern))?.matches(anywhereIn: text) == true
    }
}

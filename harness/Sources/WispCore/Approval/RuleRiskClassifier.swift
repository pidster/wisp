import Foundation

/// Cheap, deterministic risk signals from the command text.
///
/// Covers the model classifier's weak spot (it under-rates ordinary
/// modifications as safe) and the shapes that must never slip through. Each
/// rule is a regex, a level, and the reason shown to the approver.
public struct RuleRiskClassifier: RiskClassifier {
    /// One signal.
    public struct Rule: Sendable, Equatable {
        /// Regex over the whole command line.
        public var pattern: String
        /// Level when it matches.
        public var level: RiskLevel
        /// Shown to the approver.
        public var reason: String

        /// Creates a rule.
        public init(_ pattern: String, _ level: RiskLevel, _ reason: String) {
            self.pattern = pattern
            self.level = level
            self.reason = reason
        }
    }

    /// The rules in use.
    public let rules: [Rule]
    private let compiled: [(regex: NSRegularExpression, rule: Rule)]

    /// Why the rules could not be compiled.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A rule's pattern does not compile as a regular expression.
        case invalidRule(pattern: String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidRule(let pattern): "invalid risk rule pattern: \(pattern)"
            }
        }
    }

    /// Creates a classifier over `rules`, compiling every pattern once.
    ///
    /// - Throws: `Failure.invalidRule` naming the first pattern that does not compile.
    public init(rules: [Rule]) throws {
        self.rules = rules
        compiled = try rules.map { rule in
            do {
                return (try RegexCache.regex(rule.pattern), rule)
            } catch {
                throw Failure.invalidRule(pattern: rule.pattern)
            }
        }
    }

    /// The built-in rules. A test compiles every default pattern, so this cannot fail in practice; a
    /// pattern that somehow did would be dropped with an error in diagnostics rather than crash.
    public static let standard: RuleRiskClassifier = {
        if let classifier = try? RuleRiskClassifier(rules: defaultRules) { return classifier }
        let usable = defaultRules.filter { (try? RegexCache.regex($0.pattern)) != nil }
        Diagnostics.policy.error(
            "dropping \(defaultRules.count - usable.count) default risk rule(s) that do not compile")
        return (try? RuleRiskClassifier(rules: usable)) ?? RuleRiskClassifier(compiled: [])
    }()

    private init(compiled: [(regex: NSRegularExpression, rule: Rule)]) {
        rules = compiled.map(\.rule)
        self.compiled = compiled
    }

    /// A variable name that holds a credential: it contains PASSWORD, TOKEN, SECRET, CREDENTIAL, an API or
    /// access key, or ends in `_KEY`, in any case.
    private static let credentialName =
        #"(?i:[A-Za-z0-9_]*(PASSWORD|PASSWD|PASSPHRASE|TOKEN|SECRET|CREDENTIAL|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Za-z0-9_]*|[A-Za-z0-9_]+_KEY)"#

    /// A word boundary at the start of a simple command in a pipeline or list.
    private static let start = #"(^|[\s;&|(`]|\$\()"#

    /// Built-in signals. Order does not matter; the highest matching level wins.
    public static let defaultRules: [Rule] = [
        // Dangerous
        Rule(start + #"sudo(\s|$)"#, .dangerous, "runs as root"),
        Rule(start + #"rm\s+(-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r|-r|-R)\b"#, .dangerous, "recursive deletion"),
        Rule(start + #"rm\s+.*(~|\$HOME|/Users/|/etc|/usr|/var|/System)"#, .dangerous, "deletes outside the project"),
        Rule(#"\|\s*(ba|z|da)?sh(\s|$)"#, .dangerous, "pipes downloaded or generated content into a shell"),
        Rule(start + #"git\s+push\b.*(--force|-f\b|\+)"#, .dangerous, "force push rewrites remote history"),
        Rule(
            start
                + #"git\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\b[^;&|]*\s--\s|restore\s(?![^;&|]*--staged)|restore\b[^;&|]*\s(--worktree|-W)\b)"#,
            .dangerous,
            "discards local changes"),
        Rule(start + #"git\s+branch\s+-D\b"#, .dangerous, "deletes a branch without merge check"),
        Rule(
            start + #"find\b.*\s(-delete\b|-exec(dir)?\s+rm\b)"#, .dangerous,
            "deletes every file the search matches"),
        Rule(start + #"xargs\s+(-\S+\s+)*rm\b"#, .dangerous, "deletes every path given to it"),
        Rule(
            start + #"find\s+(/|~|\$HOME)\S*\s.*-exec(dir)?\s+(cat|cp|tar|zip|base64|curl|scp|rsync|xxd|strings)\b"#,
            .dangerous, "reads or copies every file a search of the home folder or the disk matches"),
        Rule(
            start + #"security\s+(find-(generic|internet)-password\b.*\s-[wg]\b|dump-keychain\b|export\b)"#,
            .dangerous, "prints stored passwords or keys"),
        Rule(start + #"(chmod|chown)\s+(-R|--recursive)"#, .dangerous, "recursive permission change"),
        Rule(
            start + #"git\s+(reflog\s+(expire|delete)\b|gc\b[^;&|]*--prune=now)"#, .dangerous,
            "destroys the history git keeps for recovery"),
        // Publishing is public and irreversible, as the labels have it; a dry run is not.
        Rule(
            start
                + #"((npm|pnpm|yarn)\s+publish\b|cargo\s+publish\b|gem\s+push\b|twine\s+upload\b|mvn\b[^;&|]*\bdeploy\b|docker\s+push\b|pod\s+trunk\s+push\b)(?![^;&|]*--dry-run)"#,
            .dangerous, "publishes to a registry"),
        Rule(
            start + #"aws\s+s3\s+(rb\b[^;&|]*--force|rm\b[^;&|]*--recursive)"#, .dangerous,
            "deletes remote storage"),
        // A credential printed goes into the model's context and the audit log, sent or not. A variable
        // named for one, printed by value; `${X:+set}` and `${#X}` show only whether it is set or its length.
        Rule(start + #"printenv\s+(-\S+\s+)*"# + credentialName + #"\b"#, .dangerous, "prints a credential"),
        Rule(
            // A quote may come first: `sh -c 'echo "$TOKEN"'` prints it as surely.
            #"(^|[\s;&|(`'"]|\$\()(echo|printf)\b[^;&|]*?\$\{?"# + credentialName + #"\b(?!:[+?-])"#, .dangerous,
            "prints a credential"),
        Rule(
            start + #"env\b[^;&]*\|\s*grep\b.*(?i:token|secret|passw|credential|api_?key|private_key)"#,
            .dangerous, "prints credentials from the environment"),
        Rule(
            start
                + #"(gh\s+auth\s+token\b|op\s+read\b|op\s+item\s+get\b.*--reveal|aws\s+configure\s+get\s+\S*(?i:secret|token)|kubectl\b[^;&|]*\bget\s+secrets?\b[^;&|]*\s-o\s*=?\s*(yaml|json|jsonpath|go-template)|kubectl\b[^;&|]*\bconfig\s+view\b[^;&|]*--raw|az\s+keyvault\s+secret\s+(show|download)\b|gcloud\s+secrets\s+versions\s+access\b|vault\s+(kv\s+get|read)\b|gpg\b[^;&|]*--export-secret-(sub)?keys)"#,
            .dangerous, "prints a stored credential"),
        Rule(
            start
                + #"(mkfs|diskutil\s+(erase|partition|zeroDisk|secureErase|reformat|apfs\s+(delete|erase))|newfs_|dd\s.*\bof=/dev/)"#,
            .dangerous,
            "destroys a disk or volume"),
        // In any case: the file system is case-insensitive, so `~/.SSH/ID_RSA` is the same key.
        Rule(
            #"(?i)(\.ssh/|id_rsa|id_ed25519|id_ecdsa|\.aws/credentials|\.netrc|\.gnupg|keychain|\.config/gh/hosts\.yml|\.git-credentials|\.npmrc|\.pypirc|\.docker/config\.json|\.kube/config)"#,
            .dangerous, "touches credentials"
        ),
        Rule(start + #"(kill\s+-9\s+-1|killall|pkill\s+-9)\b"#, .dangerous, "kills processes broadly"),
        Rule(start + #"(launchctl|systemsetup|nvram|csrutil|spctl)\b"#, .dangerous, "changes system configuration"),
        Rule(
            #"(curl|wget)\b.*(-X\s*POST|--data|-d\s|--upload-file|-T\s|@-)"#, .dangerous,
            "uploads data over the network"),
        Rule(
            #"-m\s+http\.server\b(?!.*(--bind|-b)\s+(127\.0\.0\.1|localhost|::1)\b)"#, .dangerous,
            "serves a directory on every network interface"),
        // Moderate
        Rule(start + #"(curl|wget|ssh|scp|sftp|rsync|nc|telnet)\b"#, .moderate, "uses the network"),
        Rule(
            #"(-m\s+http\.server|\bhttp-server\b|\bserve\b|\bnc\s+-l|\bngrok\b|\bssh\s+-[LRD]\b|--listen\b|\blisten\s+\d)"#,
            .moderate, "starts a network service"),
        Rule(
            start
                + #"git\s+(push|pull|fetch|clone|remote|commit|merge|rebase|stash|tag(?!\s+(-l|--list)\b)|cherry-pick|revert)(?![\w-])"#,
            .moderate, "changes repository state"),
        Rule(
            start
                + #"(npm|npx|yarn|pnpm|pip3?|pipx|gem|cargo|brew|swift\s+package)\s+(install|add|update|upgrade|remove|uninstall|publish)\b"#,
            .moderate, "installs or publishes packages"),
        Rule(
            start + #"(rm|mv|cp|touch|mkdir|rmdir|ln|truncate|tee|sed\s+-i|perl\s+-i)\b"#, .moderate, "modifies files"),
        Rule(#"(^|[^>])>{1,2}\s*(?!/dev/null\b)[^&\s]"#, .moderate, "writes to a file"),
        Rule(start + #"edit_file\b"#, .moderate, "edits a file"),
        // Building and testing the project are safe, as the labels have them (training/risk/labels.md); only
        // what writes outside the project or throws build output away is moderate.
        Rule(
            start + #"xcodebuild(?!\s+(-showsdks|-version|-list)\b)(?=\s|$)"#, .moderate,
            "writes build products outside the project"),
        Rule(
            start
                + #"(make\s+(\S+\s+)*(clean|distclean|install|uninstall)\b|cargo\s+clean\b|swift\s+package\s+(clean|reset|purge-cache)\b|go\s+clean\b)"#,
            .moderate, "cleans or installs build output"),
        Rule(
            start + #"(open|osascript|defaults\s+write|crontab|at)(?=\s|$)"#, .moderate,
            "affects the desktop or scheduling"),
        Rule(start + #"(kill|pkill)\b"#, .moderate, "signals a process"),
        // Printing the whole environment prints every secret in it.
        Rule(
            start + #"(env|printenv)(\s+(-0|--null))?\s*($|[;&|)`])"#, .moderate,
            "prints the whole environment, secrets included"),
    ]

    /// The one reason given when no rule matches, so a caller can tell "safe by a rule" from "no rule
    /// knew the command".
    public static let noSignals = "no risk signals in the command text"

    /// The reason given for a command on the read-only list (`KnownSafeCommands`).
    public static let knownSafe = "a known read-only command"

    /// Applies every rule and returns the highest level with all matching reasons. A command no rule
    /// matches that is on the read-only list is marked `RiskAssessment.knownSafeKey`, so a composite asks
    /// no other classifier about it.
    ///
    /// The rules run over the command as written and over its `normalisedForms`, so quoting a word
    /// (`"sudo" ls`, `sh -c 'rm -rf ~/x'`), continuing a line (`git push \⏎ --force`), or putting git's global
    /// options before its verb (`git -C . push --force`) hides nothing from them.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        var level = RiskLevel.safe
        var reasons: [String] = []
        let forms = [command] + Self.normalisedForms(of: command).filter { $0 != command }
        for (regex, rule) in compiled where forms.contains(where: regex.matches(anywhereIn:)) {
            level = max(level, rule.level)
            if !reasons.contains(rule.reason) { reasons.append(rule.reason) }
        }
        if reasons.isEmpty, KnownSafeCommands.contains(command) {
            return RiskAssessment(
                level: .safe, reasons: [Self.knownSafe], sources: ["rules"],
                metadata: [RiskAssessment.knownSafeKey: true])
        }
        if reasons.isEmpty { reasons = [Self.noSignals] }
        return RiskAssessment(level: level, reasons: reasons, sources: ["rules"])
    }

    /// Git's options that come before the verb and take a separate value.
    private static let gitValueOptions: Set<String> = [
        "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env", "--super-prefix",
    ]

    /// Another spelling of `command` for the rules: its words (quotes removed, `$'…'` read, line
    /// continuations joined) joined by single spaces, with git's global options (`-C <dir>`, `-c <k=v>`,
    /// `--no-pager`, `--git-dir=…`) dropped so the verb follows `git` directly. Unquoting can make a harmless
    /// word look like an operator (`grep -E "a|sh"`), which only ever raises a verdict.
    static func normalisedForms(of command: String) -> [String] {
        var words: [String] = []
        var remaining = CommandSplitter.words(of: command)[...]
        while let word = remaining.popFirst() {
            words.append(word)
            guard word == "git" || word.hasSuffix("/git") else { continue }
            while let option = remaining.first, option.hasPrefix("-") {
                remaining.removeFirst()
                let name = String(option.prefix { $0 != "=" })
                if gitValueOptions.contains(name), !option.contains("="), !remaining.isEmpty { remaining.removeFirst() }
            }
        }
        return [words.joined(separator: " ")]
    }
}

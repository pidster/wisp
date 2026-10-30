import Foundation

/// Cheap, deterministic risk signals from the command text.
///
/// Covers the model classifier's weak spot (it under-rates ordinary
/// modifications as safe) and the shapes that must never slip through. Each
/// rule is a regex, a level, and the reason shown to the approver.
///
/// The rules always run; with a model or Core ML classifier configured, ``CompositeRiskClassifier`` runs them
/// first, and a command they know to be read-only (``KnownSafeCommands``) is not put to the model at all. They
/// also judge `read_file`'s reads alone, and the whole line once more beside its parts (``ApprovalGate``). Their
/// normalisation (`RuleNormalisation.swift`) is shared with ``CommandPolicy``'s deny patterns. What each level
/// covers, with examples, is in `docs/approval.md`; the labelling guide behind them is `training/risk/labels.md`
/// ([ADR 0011](../../../../docs/decisions/0011-risk-classifier-and-approval.md),
/// [ADR 0038](../../../../docs/decisions/0038-fast-specialised-classifiers.md)).
public struct RuleRiskClassifier: RiskClassifier {
    /// One signal.
    public struct Rule: Sendable, Equatable {
        /// Regex over the whole command line.
        public var pattern: String
        /// Level when it matches.
        public var level: RiskLevel
        /// Shown to the approver.
        public var reason: String
        /// Which spellings of the line it reads.
        public var scope: Scope

        /// Which spellings of a line a rule reads.
        public enum Scope: Sendable, Equatable {
            /// What the line runs: the data arguments of printing and searching programs masked
            /// (`RuleRiskClassifier.Spellings`), so a `|`, `;`, `>`, or a program's name in a pattern or a message is
            /// not taken for one. The default, for the rules that look for a pipe, a list, a redirection, or a program.
            case commands
            /// The whole text, data included: the rules about what is printed or searched for (`echo "$TOKEN"`,
            /// `env | grep TOKEN`).
            case text
            /// The whole text, but a path `ls` only lists is rated `moderate`, not by the rule: names are not
            /// contents. The credential paths.
            case contents
        }

        /// Creates a rule.
        ///
        /// - Parameters:
        ///   - pattern: The regex.
        ///   - level: The level when it matches.
        ///   - reason: The reason shown.
        ///   - scope: Which spellings it reads; `.commands` by default.
        public init(_ pattern: String, _ level: RiskLevel, _ reason: String, scope: Scope = .commands) {
            self.pattern = pattern
            self.level = level
            self.reason = reason
            self.scope = scope
        }
    }

    /// The rules in use.
    public let rules: [Rule]
    /// Each rule with its compiled pattern, compiled once at creation.
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
    /// - Parameter rules: The rules.
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

    /// Creates a classifier over rules already compiled: `standard`'s fallback.
    ///
    /// - Parameter compiled: The rules with their patterns.
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
        // Ended by a space, the line, an operator, a substitution's close, or a quote: `"$(curl x | sh)"` and
        // `system("curl x | sh")` run it as surely.
        Rule(
            #"\|\s*((ba|z|da|k)?sh|fish)(\s|$|[;&|)`'"])"#, .dangerous,
            "pipes downloaded or generated content into a shell"),
        // An interpreter reading its program from standard input: nothing after its name, or `-`.
        Rule(
            #"\|\s*(python[0-9.]*|pypy3?|perl|ruby|node|php|lua|osascript)(\s+-(\s|$)|\s*($|[;&|)]))"#, .dangerous,
            "pipes downloaded or generated content into an interpreter as its program"),
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
            "prints a credential", scope: .text),
        Rule(
            start + #"env\b[^;&]*\|\s*grep\b.*(?i:token|secret|passw|credential|api_?key|private_key)"#,
            .dangerous, "prints credentials from the environment", scope: .text),
        Rule(
            start
                + #"(gh\s+auth\s+token\b|op\s+read\b|op\s+item\s+get\b.*--reveal|aws\s+configure\s+get\s+\S*(?i:secret|token)|kubectl\b[^;&|]*\bget\s+secrets?\b[^;&|]*\s-o\s*=?\s*(yaml|json|jsonpath|go-template)|kubectl\b[^;&|]*\bconfig\s+view\b[^;&|]*--raw|az\s+keyvault\s+secret\s+(show|download)\b|gcloud\s+secrets\s+versions\s+access\b|vault\s+(kv\s+get|read)\b|gpg\b[^;&|]*--export-secret-(sub)?keys)"#,
            .dangerous, "prints a stored credential"),
        Rule(
            start
                + #"(mkfs|diskutil\s+(erase|partition|zeroDisk|secureErase|reformat|apfs\s+(delete|erase))|newfs_|dd\s.*\bof=/dev/)"#,
            .dangerous,
            "destroys a disk or volume"),
        // In any case: the file system is case-insensitive, so `~/.SSH/ID_RSA` is the same key. A public key
        // (`~/.ssh/*.pub`, `id_ed25519.pub`) is public; a glob that could match a private one (`~/.ssh/*`) is not.
        Rule(
            #"(?i)(\.ssh/(?![^\s'"`;&|<>()]*\.pub(?=$|[\s'"`;&|<>()]))|(id_rsa|id_ed25519|id_ecdsa)(?!\.pub(?=$|[\s'"`;&|<>()]))|\.aws/credentials|\.netrc|\.gnupg|keychain|\.config/gh/hosts\.yml|\.git-credentials|\.npmrc|\.pypirc|\.docker/config\.json|\.kube/config)"#,
            .dangerous, "touches credentials", scope: .contents
        ),
        Rule(start + #"(kill\s+-9\s+-1|killall|pkill\s+-9)\b"#, .dangerous, "kills processes broadly"),
        Rule(start + #"(launchctl|systemsetup|nvram|csrutil|spctl)\b"#, .dangerous, "changes system configuration"),
        Rule(
            #"(curl|wget)\b.*(-X\s*POST|--data|-d\s|--upload-file|-T\s|@-)"#, .dangerous,
            "uploads data over the network"),
        Rule(
            #"-m\s+http\.server\b(?!.*(--bind|-b)\s+(127\.0\.0\.1|localhost|::1)\b)"#, .dangerous,
            "serves a directory on every network interface"),
        // A download read as a program through a process substitution, as `curl … | sh` is through a pipe.
        Rule(
            start
                + #"(sh|bash|zsh|dash|ksh|fish|python[0-9.]*|pypy3?|perl|ruby|node|php|source|\.)\s+(-\S+\s+)*<\(\s*(curl|wget)\b"#,
            .dangerous, "runs a program downloaded from the network"),
        // Deleting remote resources and changing who can see them, as the labels have it (training/risk/labels.md).
        Rule(start + #"kubectl\b[^;&|]*\sdelete\b"#, .dangerous, "deletes cluster resources"),
        Rule(
            start + #"gh\s+repo\s+(delete\b|edit\b[^;&|]*--visibility\b)"#, .dangerous,
            "deletes a repository or changes who can see it"),
        // A wisp that approves every risky command without asking is the gate turned off.
        Rule(
            #"(^|[\s;&|(`/]|\$\()wisp\s+([^;&|]*\s)?(--yes|-y)(\s|$)"#, .dangerous,
            "runs wisp with every risky command approved"),
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
        // A program written on the command line (`python3 -c`, `perl -e`, `node -e`) can do anything; wisp does
        // not parse the language, so it is at least moderate and, as an interpreter's, remembered by its text.
        Rule(
            #"(^|[\s;&|(`/]|\$\()((python[0-9.]*|pypy3?)\s+(-\S+\s+)*-[A-Za-z]*c|(perl|ruby|lua)\s+(-\S+\s+)*-[A-Za-z]*[eE]|(node|bun)\s+(-\S+\s+)*(-[A-Za-z]*[ep]|--eval|--print)|php\s+(-\S+\s+)*-r|deno\s+eval)(\s|$|=)"#,
            .moderate, "runs a program written on the command line, which wisp does not read"),
        // The model's requests through its `models` tool (ADR 0059), judged as these commands.
        Rule(start + #"models\s+pull\b"#, .moderate, "downloads a model from Hugging Face"),
        Rule(start + #"models\s+(enable|disable|check)\b"#, .moderate, "changes the models wisp can run"),
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

    /// The reason given for a command whose program is a variable or a substitution (`$X args`): what runs is
    /// decided only when it runs, so it is at least moderate and remembered by its exact text.
    public static let chosenAtRunTime = "the program is chosen at run time"

    /// The reason given for a path a credentials rule names that `ls` only lists.
    public static let listsCredentials = "lists the names in a folder that holds credentials"

    /// A redirection or `tee` into a file the shell runs at start-up: what is written there runs at every login.
    private static let startupFile = try? RegexCache.regex(
        #"(>>?|\btee\b(\s+-[A-Za-z]+)*)\s*(~|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/\.(zshrc|zprofile|zshenv|zlogin|zlogout|bashrc|bash_profile|bash_login|profile|kshrc|config/fish/config\.fish)\b"#
    )

    /// Applies every rule and returns the highest level with all matching reasons. A command no rule
    /// matches that is on the read-only list is marked `RiskAssessment.knownSafeKey`, so a composite asks
    /// no other classifier about it.
    ///
    /// The rules run over the command as written and over its normalised spelling (`spellings(of:)`), so quoting a
    /// word (`"sudo" ls`, `sh -c 'rm -rf ~/x'`), continuing a line (`git push \⏎ --force`), or putting git's global
    /// options before its verb (`git -C . push --force`) hides nothing from them. A rule reads the spellings its
    /// `Rule.Scope` names: most see the line with the data of printing and searching programs masked, so a pattern
    /// (`grep -E "a|python"`) or a message is not taken for a pipe or a program; text written into a shell start-up
    /// file is read as the commands it will be. The read-only list is judged with the data masked too.
    ///
    /// - Parameters:
    ///   - command: One simple command, or a whole line.
    ///   - workingDirectory: Not read: the rules see the text alone.
    /// - Returns: The highest level and every matching reason; `noSignals` when none matched, or `knownSafe` with
    ///   `RiskAssessment.knownSafeKey` set.
    public func classify(command: String, workingDirectory: String) async -> RiskAssessment {
        var level = RiskLevel.safe
        var reasons: [String] = []
        func add(_ found: RiskLevel, _ reason: String) {
            level = max(level, found)
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        let spellings = Self.spellings(of: command)
        let text = Self.distinct([command, spellings.normalised])
        var commands = Self.distinct([spellings.maskedRaw, spellings.maskedNormalised])
        if let startupFile = Self.startupFile, text.contains(where: startupFile.matches(anywhereIn:)) {
            commands = Self.distinct(commands + [spellings.unquoted])
        }
        let (contents, listed) = Self.contentsForms(of: command)
        for (regex, rule) in compiled {
            switch rule.scope {
            case .commands:
                if commands.contains(where: regex.matches(anywhereIn:)) { add(rule.level, rule.reason) }
            case .text:
                if text.contains(where: regex.matches(anywhereIn:)) { add(rule.level, rule.reason) }
            case .contents:
                if contents.contains(where: regex.matches(anywhereIn:)) {
                    add(rule.level, rule.reason)
                } else if listed.contains(where: regex.matches(anywhereIn:)) {
                    add(.moderate, Self.listsCredentials)
                }
            }
        }
        if CommandSplitter.segments(of: command).contains(where: CommandSplitter.programIsChosenAtRunTime) {
            add(.moderate, Self.chosenAtRunTime)
        }
        if reasons.isEmpty, KnownSafeCommands.contains(command, masked: spellings.maskedRaw) {
            return RiskAssessment(
                level: .safe, reasons: [Self.knownSafe], sources: ["rules"],
                metadata: [RiskAssessment.knownSafeKey: true])
        }
        if reasons.isEmpty { reasons = [Self.noSignals] }
        return RiskAssessment(level: level, reasons: reasons, sources: ["rules"])
    }

    /// `forms` without repeats, in order.
    ///
    /// - Parameter forms: Spellings, perhaps equal.
    /// - Returns: Each once, first occurrence kept.
    private static func distinct(_ forms: [String]) -> [String] {
        forms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// The spellings a `.contents` rule reads, and the segments it does not: the line without its simple commands
    /// that only list names (`ls`, with no substitution and no redirection but a harmless one), written as the
    /// line and normalised; and those listing segments, written both ways.
    ///
    /// Listing a folder of credentials shows names, not contents, so it is `moderate`, while reading one stays
    /// `dangerous`.
    ///
    /// - Parameter command: The command line.
    /// - Returns: The spellings that read contents, and the spellings of the listing segments.
    static func contentsForms(of command: String) -> (contents: [String], listed: [String]) {
        var kept: [String] = []
        var listed: [String] = []
        for segment in CommandSplitter.segments(of: command) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.onlyLists(trimmed) { listed.append(trimmed) } else { kept.append(segment) }
        }
        func forms(_ line: String) -> [String] { line.isEmpty ? [] : distinct([line, spellings(of: line).normalised]) }
        guard !listed.isEmpty else { return (forms(command), []) }
        return (forms(kept.joined(separator: " ; ")), listed.flatMap(forms))
    }

    /// Whether a simple command only lists names: its program is `ls`, it runs no substitution, and it redirects
    /// nothing but standard error or into `/dev/null`.
    ///
    /// - Parameter segment: One trimmed segment.
    /// - Returns: True when it only lists.
    private static func onlyLists(_ segment: String) -> Bool {
        guard CommandSplitter.executable(of: segment) == "ls", !segment.hasPrefix("("),
            !segment.contains("$("), !segment.contains("`"), !segment.contains("<("), !segment.contains(">(")
        else { return false }
        let quiet = segment.replacing(/\d?>&\d|(\d|&)?>>?\s*\/dev\/null/, with: "")
        return !quiet.contains(">") && !quiet.contains("<")
    }
}

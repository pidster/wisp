import Foundation

/// Finds credentials and personal data in text by rule, for `scan_secrets`, `redact`, `wisp scan`,
/// `wisp redact`, and the `secret` flag of `summarise_diff`
/// ([ADR 0031](../../../../docs/decisions/0031-secret-scanning-and-redaction.md)).
///
/// Rules are regular expressions for shapes that are credentials by construction (a provider's key
/// prefix, a private key block, a URL with a password) or personal data by form (an email address, a
/// card number that passes the Luhn check, a home directory's user name). Matches never leave this type
/// whole: a `Finding` carries a masked preview, and redaction replaces the value with a numbered marker.
/// Generic high-entropy detection is left out on purpose: lockfiles and build output are full of hashes.
public enum SecretScanner {
    /// What a match is.
    public enum Category: String, Sendable, CaseIterable {
        /// A credential: key, token, password, private key.
        case secret
        /// Personal or identifying data: an email, a phone number, a card number, a public IP address, a
        /// user name, a private hostname.
        case personal
    }

    /// One pattern and how to read its match.
    struct Rule: Sendable {
        /// The kind reported and used in the redaction marker, such as `aws-access-key`.
        let kind: String
        /// Secret or personal.
        let category: Category
        /// The expression.
        let pattern: String
        /// The capture group that holds the value; 0 is the whole match.
        let group: Int
        /// Accepts or rejects a value the expression matched; nil accepts all.
        let accepts: (@Sendable (String) -> Bool)?

        /// Creates a rule.
        init(
            _ kind: String, _ category: Category, _ pattern: String, group: Int = 0,
            accepts: (@Sendable (String) -> Bool)? = nil
        ) {
            self.kind = kind
            self.category = category
            self.pattern = pattern
            self.group = group
            self.accepts = accepts
        }
    }

    /// The rules, most specific first: where two matches overlap the earlier and longer one wins.
    static let rules: [Rule] = [
        Rule(
            "private-key", .secret,
            #"-----BEGIN ([A-Z ]*)PRIVATE KEY( BLOCK|)-----(?:[\s\S]*?-----END \1PRIVATE KEY\2-----)?"#),
        // A body line of a PKCS#1 or PKCS#8 RSA key, or an OpenSSH key, seen without its header.
        Rule(
            "private-key", .secret, #"\b(?:MII[A-Za-z0-9+/]{2,3}IBA(?:AK|DAN)|b3BlbnNzaC1rZXktdjE)[A-Za-z0-9+/=]{20,}"#),
        Rule("aws-access-key", .secret, #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, accepts: { !isPlaceholder($0) }),
        Rule(
            "aws-secret-key", .secret,
            #"(?i)aws[a-z0-9_\-]{0,20}(?:secret|private)[a-z0-9_\-]{0,20}["']?\s*[:=]\s*["']?([A-Za-z0-9/+]{40})\b"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "github-token", .secret, #"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"#,
            accepts: { !isPlaceholder($0) }),
        Rule("gitlab-token", .secret, #"\bgl(?:pat|dt|ptt|rt|cbt|soat|ft|imt)-[A-Za-z0-9_\-]{20,}"#),
        Rule("pypi-token", .secret, #"\bpypi-AgE[A-Za-z0-9_\-]{16,}"#),
        Rule("docker-token", .secret, #"\bdckr_pat_[A-Za-z0-9_\-]{20,}"#),
        Rule("npm-token", .secret, #"\bnpm_[A-Za-z0-9]{30,}\b"#),
        Rule("bitbucket-token", .secret, #"\bATBB[A-Za-z0-9]{24,}"#),
        Rule("vault-token", .secret, #"\b(?:hv[sb]\.[A-Za-z0-9_\-]{24,}|s\.[A-Za-z0-9]{24,}\b)"#),
        Rule("fly-token", .secret, #"\bFlyV1 fm[12]_[A-Za-z0-9_+/=\-]{20,}"#),
        Rule("webhook-secret", .secret, #"\bwhsec_[A-Za-z0-9+/=]{24,}"#),
        Rule("mailgun-key", .secret, #"\bkey-[0-9a-f]{32}\b"#),
        Rule(
            "google-oauth", .secret,
            #"\b(?:GOCSPX-[A-Za-z0-9_\-]{20,}|1//0[A-Za-z0-9_\-]{20,}|ya29\.[A-Za-z0-9_\-]{20,})"#),
        Rule(
            "azure-key", .secret, #"(?i)\b(?:AccountKey|SharedAccessKey)=([A-Za-z0-9+/]{40,}={0,2})"#, group: 1),
        Rule("slack-token", .secret, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        Rule("slack-webhook", .secret, #"https://hooks\.slack\.com/services/[A-Za-z0-9/]{20,}"#),
        Rule(
            "chat-webhook", .secret,
            #"https://(?:(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]{20,}|[a-z0-9.\-]*(?:webhook\.office|outlook\.office)\.com/webhook[b2]?/\S{20,})"#
        ),
        Rule("stripe-key", .secret, #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#),
        Rule("anthropic-key", .secret, #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        Rule("openai-key", .secret, #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#),
        Rule("google-api-key", .secret, #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        Rule("jwt", .secret, #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        Rule(
            "url-password", .secret, #"\b[a-z][a-z0-9+.\-]*://[^/\s:@]*:([^/\s:@]{3,})@"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        // A signature or credential in a URL's query: a signed URL, a token or key passed as a parameter.
        Rule(
            "url-secret", .secret,
            #"(?i)[?&](?:sig|signature|x-goog-signature|x-amz-signature|token|access_token|api_key|apikey|key|secret|password|code)=([^&\s"'#]{6,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "auth-header", .secret,
            #"(?i)\b(?:proxy-)?authorization["']?\s*[:=,]\s*["']?(?:bearer|basic|token|digest|apikey|sso-key)\s+([A-Za-z0-9._~+/:\-]{6,}=*)"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "auth-header", .secret, #"\bBearer\s+([A-Za-z0-9._~+/\-]{20,}=*)"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        Rule(
            "session-cookie", .secret,
            #"(?i)\b(?:set-)?cookie\s*:[^\n]*?\b[A-Za-z0-9_\-]*(?:sess(?:ion)?(?:id)?|sid|token|auth|remember[A-Za-z0-9_]*)=([^;\s"']{8,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "password-hash", .secret,
            #"\$(?:2[abxy]?\$\d{2}\$[./A-Za-z0-9]{50,}|(?:1|5|6|apr1|y)\$[^$\s:]{1,64}\$[./A-Za-z0-9]{20,})"#),
        Rule(
            "assigned-secret", .secret,
            #"(?i)\b(?:api[_-]?key|secret|token|password|passwd|pwd|credential|auth[_-]?key)[a-z0-9_]*["']?\s*[:=]\s*["']([^"'\s]{8,})["']"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "env-secret", .secret,
            #"(?m)^\s*(?:export\s+)?[A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Z0-9_]*\s*=\s*([^\s#"']{8,})"#,
            group: 1, accepts: { !isPlaceholder($0) && !isCode($0) }),
        // A value assigned to a name that says it is a credential, quoted or not, in config, env files,
        // headers, and code. The name must end in the credential word (`db_pass`, `X-Api-Key`), so
        // `token_count` and `PUBLIC_KEY_PATH` do not match; a value that reads as code does not count.
        Rule(
            "assigned-secret", .secret,
            #"(?i)"# + credentialName + #"["']?\s*[:=]\s*["']([^"'\n]{4,})["'](?!\s*[+\[])"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "assigned-secret", .secret,
            #"(?i)"# + credentialName + #"["']?\s*[:=]\s*([^\s"'`,;{}()\[\]<>]{4,}+)(?![(\[])"#,
            group: 1, accepts: { !isPlaceholder($0) && !isCode($0) }),
        Rule(
            "cli-password", .secret,
            #"(?i)--(?:password|passwd|pass|token|api-key|secret|client-secret)(?:=|\s+)['"]?([^\s'"]{3,})"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret, #"\b(?:mysql|mysqldump|mysqladmin|mariadb)\b[^|;&\n]*?\s-p([^\s'"]{3,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret,
            #"\b(?:sshpass|docker\s+login|podman\s+login|helm\s+registry\s+login|az\s+login)\b[^|;&\n]*?\s-p\s+['"]?([^\s'"]{3,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret,
            #"\b(?:redis-cli\b[^|;&\n]*?\s-a|zip\b[^|;&\n]*?\s-P|openssl\b[^|;&\n]*?\s-k|security\s+add-(?:generic|internet)-password\b[^|;&\n]*?\s-w)\s+['"]?([^\s'"]{3,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret, #"\b(?:curl|wget)\b[^|;&\n]*?\s(?:-u|--user)[\s=]+['"]?[^\s:'"]+:([^\s'"@]{3,})"#,
            group: 1, accepts: { !isPlaceholder($0) }),
        Rule("cli-password", .secret, #"\bhtpasswd\s+-b\S*\s+\S+\s+\S+\s+['"]?([^\s'"]{3,})"#, group: 1),
        Rule(
            "cli-password", .secret,
            #"\b(?:echo|printf)\s+['"]?([^\s'"|]{3,})['"]?\s*\|\s*sudo\s+-S"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret, #"\bsudo\s+-S\s*<<<\s*['"]?([^\s'"]{3,})"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        Rule(
            "cli-password", .secret, #"\baws\s+configure\s+set\s+\S*(?:secret|token)\S*\s+(\S{8,})"#, group: 1,
            accepts: { !isPlaceholder($0) }),
        Rule("netrc-password", .secret, #"\bmachine\s+\S+\s+login\s+\S+\s+password\s+(\S+)"#, group: 1),
        Rule("wifi-password", .secret, #"\bWIFI:[^\s]*?\bP:([^;\s]+);"#, group: 1),
        Rule(
            "email", .personal, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#,
            accepts: { !isReservedDomain($0) }),
        Rule("phone", .personal, #"(?<![\w+])\+[1-9]\d{0,2}(?:[ \-]?\(?\d{1,4}\)?){2,5}\b"#),
        Rule("card-number", .personal, #"\b(?:\d[ \-]?){12,18}\d\b"#, accepts: { passesLuhn($0) }),
        Rule(
            "ip-address", .personal, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, accepts: { isPublicIPv4($0) }),
        Rule(
            "street-address", .personal,
            #"\b\d{1,5}[A-Za-z]? (?:[A-Z][a-z]+ ){1,3}(?:Street|St|Lane|Ln|Road|Rd|Avenue|Ave|Drive|Dr|Way|Close|Court|Ct|Place|Pl|Boulevard|Blvd|Terrace|Crescent|Gardens|Square|Row|Hill|Grove|Park)\b\.?"#
        ),
        Rule(
            "private-host", .personal,
            #"\b[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?(?:\.[a-z0-9\-]+)*\.(?:internal|corp|lan|intranet|local)\b"#),
        Rule("user-name", .personal, #"/Users/([A-Za-z0-9._\-]+)/"#, group: 1, accepts: { $0 != "Shared" }),
    ]

    /// A name that says its value is a credential, ending in the credential word: `password`,
    /// `api_key`, `client_secret`, `auth_token`, `password_hash`. `pass` and `pw` count only with a
    /// prefix (`db_pass`, `admin_pw`), since alone they are test outcomes (`--- PASS:`, `"pass"`).
    /// Not preceded by a colon, so an ARN's `:secret:` is not a name.
    static let credentialName =
        #"(?<![A-Za-z0-9:])(?:(?:[A-Za-z0-9]+[_.\-])+(?:pass|pw)|(?:[A-Za-z0-9]+[_.\-])*(?:password|passwd"#
        + #"|passphrase|pwd|secret(?:[_\-]?key)?|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|encryption[_\-]?key"#
        + #"|signing[_\-]?key|auth[_\-]?key|credentials?))(?:[_.\-](?:hash|digest|base))?"#

    /// One rule's match in scanned text.
    public struct Match: Equatable, Sendable {
        /// The rule's kind.
        public var kind: String
        /// Secret or personal.
        public var category: Category
        /// Where the value is in the scanned text.
        public var range: Range<String.Index>
        /// The value itself; never put in a result, only masked or replaced.
        public var value: String
        /// The 1-based line the value starts on.
        public var line: Int
    }

    /// A match as reported to a caller: where and what, with the value masked.
    public struct Finding: Equatable, Sendable {
        /// The rule's kind, or the model's for the model pass.
        public var kind: String
        /// Secret or personal.
        public var category: Category
        /// `path:line` in a diff, `line N` otherwise.
        public var location: String
        /// The value masked by `mask`.
        public var preview: String
        /// `rule` or `model`.
        public var detector: String

        /// Creates a finding.
        public init(kind: String, category: Category, location: String, preview: String, detector: String) {
            self.kind = kind
            self.category = category
            self.location = location
            self.preview = preview
            self.detector = detector
        }

        /// The finding as JSON, as the MCP tool returns it.
        public var json: JSONValue {
            [
                "kind": .string(kind), "category": .string(category.rawValue), "location": .string(location),
                "preview": .string(preview), "detector": .string(detector),
            ]
        }
    }

    /// Every rule match of the given categories in `text`, in order, with overlaps resolved: the match
    /// that starts first wins, and of two starting together the longer, then the earlier rule, except
    /// that a credential wins over personal data it overlaps.
    ///
    /// - Parameters:
    ///   - text: What to scan.
    ///   - categories: Which categories to look for.
    /// - Returns: The matches.
    public static func scan(_ text: String, categories: Set<Category> = Set(Category.allCases)) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(range: NSRange, rule: Rule, order: Int)] = []
        for (order, rule) in rules.enumerated() where categories.contains(rule.category) {
            guard let regex = try? RegexCache.regex(rule.pattern) else { continue }
            for result in regex.matches(in: text, range: whole) {
                let range = result.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0, let bounds = Range(range, in: text) else {
                    continue
                }
                if let accepts = rule.accepts, !accepts(String(text[bounds])) { continue }
                found.append((range, rule, order))
            }
        }
        found.sort {
            ($0.range.location, -$0.range.length, $0.order) < ($1.range.location, -$1.range.length, $1.order)
        }
        var kept: [(range: NSRange, rule: Rule, order: Int)] = []
        for candidate in found {
            guard let last = kept.last, NSMaxRange(last.range) > candidate.range.location else {
                kept.append(candidate)
                continue
            }
            // A credential beats the personal data it overlaps: `user:pw@host.example` is a URL's
            // password, not an email address.
            if candidate.rule.category == .secret, last.rule.category == .personal {
                kept[kept.count - 1] = candidate
            }
        }
        let lines = LineIndex(text)
        return kept.compactMap { candidate in
            guard let bounds = Range(candidate.range, in: text) else { return nil }
            return Match(
                kind: candidate.rule.kind, category: candidate.rule.category, range: bounds,
                value: String(text[bounds]), line: lines.line(at: candidate.range.location))
        }
    }

    /// The label the rules give one line of the secrets training set (`training/secrets/labels.md`):
    /// `secret` when any match is a credential, since a line holding both is secret, `personal` when
    /// any is personal data, and `none` otherwise. The U+200B the set puts inside secret-looking values
    /// is removed first, as a classifier's loader removes it.
    public static func label(of line: String) -> String {
        let categories = Set(scan(line.replacingOccurrences(of: "\u{200B}", with: "")).map(\.category))
        return categories.contains(.secret) ? "secret" : categories.contains(.personal) ? "personal" : "none"
    }

    /// The findings in a unified diff: only added lines are scanned, each located as `path:line` in the
    /// new file, so a secret the change removes is not reported.
    ///
    /// - Parameters:
    ///   - diff: The diff.
    ///   - categories: Which categories to look for.
    /// - Returns: The findings, in order.
    public static func scanDiff(_ diff: String, categories: Set<Category> = [.secret]) -> [Finding] {
        added(in: diff).flatMap { line in
            scan(line.text, categories: categories).map { match in
                Finding(
                    kind: match.kind, category: match.category, location: "\(line.path):\(line.number)",
                    preview: mask(match.value), detector: "rule")
            }
        }
    }

    /// One line a diff adds.
    struct AddedLine: Equatable {
        /// The file's path in the new tree.
        var path: String
        /// The line's number in the new file.
        var number: Int
        /// The line without its `+`.
        var text: String
    }

    /// The lines a unified diff adds, with their paths and new-file line numbers.
    static func added(in diff: String) -> [AddedLine] {
        var lines: [AddedLine] = []
        var path = "?"
        var number = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("+++ ") {
                let name = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                path = name.hasPrefix("b/") ? String(name.dropFirst(2)) : name
            } else if line.hasPrefix("@@"), let start = hunkStart(line) {
                number = start
            } else if line.hasPrefix("+") {
                lines.append(AddedLine(path: path, number: number, text: String(line.dropFirst())))
                number += 1
            } else if line.hasPrefix(" ") {
                number += 1
            }
        }
        return lines
    }

    /// Whether `text` reads as a unified diff: a `+++` header followed by a hunk.
    public static func looksLikeDiff(_ text: String) -> Bool {
        text.contains("\n+++ ") && text.contains("\n@@ ") || text.hasPrefix("+++ ") || text.hasPrefix("diff --git ")
    }

    /// The new-file start line of a hunk header `@@ -a,b +c,d @@`.
    static func hunkStart(_ header: String) -> Int? {
        guard let plus = header.range(of: " +") else { return nil }
        let digits = header[plus.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// A value masked for a report: a few leading characters and the length, so a reader can recognise
    /// their own key without the report carrying it.
    public static func mask(_ value: String) -> String {
        let shown = value.count >= 16 ? 4 : value.count >= 8 ? 2 : 0
        return "\(value.prefix(shown))…(\(value.count) chars)"
    }

    /// Whether a matched assignment value is a stand-in rather than a credential: a repeated character,
    /// an obvious word, a template reference, or an example.
    static func isPlaceholder(_ value: String) -> Bool {
        let lower = value.lowercased()
        if Set(lower).count <= 2 { return true }
        let words = [
            "changeme", "password", "secret", "example", "placeholder", "your", "dummy", "fake", "redacted", "mock",
            "sample", "not-a-real", "test-", "...", "…", "***", "xxxx",
        ]
        if words.contains(where: lower.contains) { return true }
        let stock: Set = [
            "test", "testing", "postgres", "root", "guest", "user", "demo", "none", "null", "todo", "tbd",
        ]
        if stock.contains(lower) { return true }
        return value.hasPrefix("$") || value.hasPrefix("<") || value.hasPrefix("{{") || value.hasPrefix("%")
    }

    /// Whether an unquoted assigned value reads as code or a reference rather than a credential: a type
    /// name or keyword, a dotted reference such as `os.environ`, a file path, or the rest of a shell
    /// expansion such as `${TOKEN:+yes}`.
    static func isCode(_ value: String) -> Bool {
        let words: Set = [
            "string", "str", "bool", "boolean", "int", "integer", "number", "any", "none", "null", "nil", "true",
            "false", "undefined", "required", "optional", "bytes", "text", "varchar", "secretstr", "data", "self",
            "this", "value", "input", "env", "config", "params", "args", "options", "await", "try", "new", "let",
            "var", "const", "function", "lambda", "return", "async", "yield",
        ]
        let lower = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
        if words.contains(lower) { return true }
        if let first = value.first, "+?-=/~.#".contains(first) { return true }
        let patterns = [
            #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$"#, #"^[\w.\-]+(?:/[\w.\-]+)+\.[a-z]{1,5}$"#,
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }

    /// Whether an email address is on a domain reserved for examples (RFC 2606): `example.com`,
    /// `example.net`, `example.org`, their subdomains, or the `.example`, `.test`, and `.invalid`
    /// top-level domains. No one can own an address there, so it identifies no one.
    static func isReservedDomain(_ address: String) -> Bool {
        let domain = address.lowercased().split(separator: "@").last.map(String.init) ?? ""
        let labels = domain.split(separator: ".")
        if let top = labels.last, ["example", "test", "invalid"].contains(top) { return true }
        guard labels.count >= 2, let top = labels.last else { return false }
        return labels[labels.count - 2] == "example" && ["com", "net", "org"].contains(top)
    }

    /// Whether a run of digits, spaces, and dashes passes the Luhn check card numbers carry.
    static func passesLuhn(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
            let doubled = pair.offset % 2 == 1 ? pair.element * 2 : pair.element
            return sum + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum % 10 == 0
    }

    /// Whether a dotted quad is a valid, public IPv4 address: not loopback, private, link-local,
    /// unspecified, or multicast, which identify no one.
    static func isPublicIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (224...255, _): return false
        case (172, 16...31), (100, 64...127): return false
        default: return true
        }
    }

    /// Line numbers by UTF-16 offset, for locating matches.
    struct LineIndex {
        /// UTF-16 offsets at which each line after the first starts.
        private let starts: [Int]

        /// Indexes `text`.
        init(_ text: String) {
            var starts: [Int] = []
            for (offset, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(offset + 1) }
            self.starts = starts
        }

        /// The 1-based line holding UTF-16 offset `offset`.
        func line(at offset: Int) -> Int {
            var low = 0
            var high = starts.count
            while low < high {
                let middle = (low + high) / 2
                if starts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return low + 1
        }
    }
}

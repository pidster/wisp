import Foundation

/// What `run_command` may execute and how it is confined.
///
/// Two layers, both configurable from `config.json`:
///
/// 1. **Patterns.** `deny` regexes reject a command line outright; if `allow` is
///    non-empty, the command must also match at least one of them. Deny wins.
///    Patterns are cheap and auditable but only see the command text.
/// 2. **Sandbox.** When enabled, the command runs under `sandbox-exec` with a
///    Seatbelt profile that denies file writes outside a set of directories and,
///    optionally, all network access. This is enforced by the kernel regardless
///    of what the command line says.
public struct CommandPolicy: Codable, Equatable, Sendable {
    /// Seatbelt confinement settings.
    public struct Sandbox: Codable, Equatable, Sendable {
        /// Whether to run commands under `sandbox-exec` at all.
        public var enabled: Bool
        /// Whether the sandboxed command may use the network.
        public var allowNetwork: Bool
        /// Directories writable in addition to the working directory and the temporary directory.
        /// `~` is expanded; symlinks are resolved because Seatbelt matches canonical paths.
        public var writablePaths: [String]

        /// Creates sandbox settings.
        public init(
            enabled: Bool = true, allowNetwork: Bool = true, writablePaths: [String] = Sandbox.defaultWritablePaths
        ) {
            self.enabled = enabled
            self.allowNetwork = allowNetwork
            self.writablePaths = writablePaths
        }

        /// Caches that build tools expect to write: SwiftPM and Cargo registries.
        public static let defaultWritablePaths = ["~/Library/Caches", "~/.cargo/registry", "~/.cargo/git"]

        private enum CodingKeys: String, CodingKey { case enabled, allowNetwork, writablePaths }

        /// Decodes a partial object; missing fields take their defaults.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            allowNetwork = try container.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? true
            writablePaths =
                try container.decodeIfPresent([String].self, forKey: .writablePaths) ?? Sandbox.defaultWritablePaths
        }
    }

    /// The outcome of checking a command line against the patterns.
    public enum Verdict: Equatable, Sendable {
        /// The command may run.
        case allowed
        /// The command must not run, with the reason to report.
        case denied(String)
    }

    /// Regexes; a match rejects the command. Checked before `allow`.
    public var deny: [String]
    /// Regexes; when non-empty, the command must match one of them.
    public var allow: [String]
    /// Confinement settings.
    public var sandbox: Sandbox

    /// Creates a policy.
    public init(deny: [String] = CommandPolicy.defaultDeny, allow: [String] = [], sandbox: Sandbox = Sandbox()) {
        self.deny = deny
        self.allow = allow
        self.sandbox = sandbox
    }

    /// The default: sandbox on with network allowed, no allow list, and a deny list of
    /// obviously destructive or privilege-escalating shapes.
    public static let `default` = CommandPolicy()

    private enum CodingKeys: String, CodingKey { case deny, allow, sandbox }

    /// Decodes a partial object; missing fields take their defaults, so `{"sandbox":{"allowNetwork":false}}`
    /// is a complete policy.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deny = try container.decodeIfPresent([String].self, forKey: .deny) ?? CommandPolicy.defaultDeny
        allow = try container.decodeIfPresent([String].self, forKey: .allow) ?? []
        sandbox = try container.decodeIfPresent(Sandbox.self, forKey: .sandbox) ?? Sandbox()
    }

    /// No patterns and no sandbox. What `--unsafe` selects.
    public static let unrestricted = CommandPolicy(deny: [], allow: [], sandbox: Sandbox(enabled: false))

    /// Shapes rejected by default. Illustrative, not exhaustive; the sandbox is the real barrier.
    public static let defaultDeny: [String] = [
        #"(^|[\s;&|(])sudo(\s|$)"#,
        #"(^|[\s;&|(])rm\s+(-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r)\S*\s+/+\*?(\s|$)"#,
        #"\|\s*(ba|z|da)?sh(\s|$)"#,
        #"(^|[\s;&|(])(mkfs|diskutil\s+erase|newfs_)"#,
        #"(^|[\s;&|(])dd\s.*\bof=/dev/"#,
        // Answering a pending approval is the person's alone (ADR 0046); the model never answers its own. Quotes
        // and a backslash around or inside the words do not hide it.
        #"(^|[\s;&|(/"'\\{`])wisp["']?\s+["']?approvals["']?\s+["']?(approve|deny)\b"#,
        // Nor does it keep or drop a permanent fact a caller asked for (ADR 0048): admitting one is the person's.
        #"(^|[\s;&|(/"'\\{`])wisp["']?\s+["']?facts["']?\s+["']?(keep|drop)\b"#,
        // Nor does it start a wisp of its own (ADR 0054): `wisp respond`, `wisp chat`, `wisp mcp`, or the bare
        // `wisp "prompt"`, which is `respond`, is a nested agent with its own model, tools, and approvals, and under
        // the sandbox it fails anyway, unable to write wisp's home. Matched where wisp is the program a simple
        // command runs (each segment of a line is checked alone), so its other subcommands stay allowed.
        nestedWisp,
        // Nor does it fetch a model: the download is the person's to approve (ADR 0052).
        #"(^|[\s;&|(/])wisp\s+models\s+pull\b"#,
    ]

    /// The deny pattern for a nested wisp agent (ADR 0054): `wisp`, quoted or not, by any path, after any of `env`
    /// and its options, `exec`, `nohup`, `nice`, `time`, `command`, `builtin`, `caffeinate`, `xargs`, `timeout N`,
    /// `VAR=value`, `{`, `then`, `do`, `else`, or `!`, followed by options and then `respond`, `chat`, `mcp`, or a
    /// quoted prompt (the bare `wisp "prompt"`). Kept short: the configuration view that lists the deny patterns is
    /// bounded.
    public static let nestedWisp =
        #"^\s*(?>(env|exec|nohup|nice|time|command|builtin|caffeinate|xargs|timeout|\{|then|do|else|!|-\S*|\d\S*|\S*=\S*)\s+)*["']?(\S*/)?wisp["']?(\s+-\S*(\s+[^-\s]\S*)?)*\s+["']?(respond|chat|mcp|["'])"#

    /// Checks that every pattern compiles.
    ///
    /// - Throws: `Failure.invalidPattern` naming the first bad pattern.
    public func validate() throws {
        for pattern in deny + allow {
            do { _ = try RegexCache.regex(pattern) } catch { throw Failure.invalidPattern(pattern) }
        }
    }

    /// Applies the deny and allow patterns to a command line.
    public func check(_ command: String) -> Verdict {
        for pattern in deny where Self.matches(pattern, command) {
            return .denied("command matches deny pattern \(pattern)")
        }
        if !allow.isEmpty, !allow.contains(where: { Self.matches($0, command) }) {
            return .denied("command matches no allow pattern")
        }
        return .allowed
    }

    /// The Seatbelt profile with `writableRoot` as the writable project directory.
    ///
    /// Everything is allowed except writes outside the writable set and,
    /// when `allowNetwork` is false, all networking. Paths are canonicalised.
    /// The root is fixed by the harness, never by a per-command working directory.
    ///
    /// - Parameters:
    ///   - writableRoot: The project directory commands may write under.
    ///   - temporaryDirectory: The process's `$TMPDIR`.
    ///   - userCacheDirectory: The per-user cache directory (`DARWIN_USER_CACHE_DIR`), where Clang keeps
    ///     its module cache; without it a build that compiles a C module inside the sandbox fails. Nil
    ///     omits it.
    ///   - home: The user's home, for expanding `~` in the configured paths.
    ///   - protected: Directories never writable, whatever the writable set holds: wisp's own home, whose
    ///     approvals, facts, configuration, and pending answers a command must not change. Denied after the
    ///     allow rule, so the denial wins (Seatbelt applies the last matching rule); a protected directory
    ///     inside the writable set is noted in a comment in the profile.
    /// - Returns: The profile text for `sandbox-exec -p`.
    public func seatbeltProfile(
        writableRoot: String, temporaryDirectory: String, userCacheDirectory: String? = nil, home: String,
        protected: [String] = []
    ) -> String {
        let writable = writableRoots(
            writableRoot: writableRoot, temporaryDirectory: temporaryDirectory,
            userCacheDirectory: userCacheDirectory, home: home)
        let subpaths = writable.map { "(subpath \(Self.quote($0)))" }
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
            "(allow file-write* \(subpaths.joined(separator: " ")) (literal \"/dev/null\") (regex #\"^/dev/(tty|fd/)\"))",
        ]
        let denied = protected.map(Self.canonical)
        for path in Self.inside(denied, writable) {
            lines.append("; note: \(path) is inside the writable set; writes to it stay denied")
        }
        lines += denied.map { "(deny file-write* (subpath \(Self.quote($0))))" }
        if !sandbox.allowNetwork {
            lines.append("(deny network*)")
        }
        return lines.joined(separator: "\n")
    }

    /// The canonical directories the sandbox lets commands write under: the same list the profile is
    /// built from, so `edit_file` is confined exactly as `run_command`'s writes are.
    ///
    /// - Parameters:
    ///   - writableRoot: The project directory commands may write under.
    ///   - temporaryDirectory: The process's `$TMPDIR`.
    ///   - userCacheDirectory: The per-user cache directory; nil omits it.
    ///   - home: The user's home, for expanding `~` in the configured paths.
    /// - Returns: Canonical paths without trailing slashes.
    public func writableRoots(
        writableRoot: String, temporaryDirectory: String, userCacheDirectory: String? = nil, home: String
    ) -> [String] {
        var writable = [writableRoot, temporaryDirectory, "/private/tmp"]
        if let userCacheDirectory { writable.append(userCacheDirectory) }
        writable += sandbox.writablePaths.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        return writable.map { Self.canonical($0) }
    }

    /// The canonical `paths` that lie under one of the canonical `roots` (or are one).
    ///
    /// - Parameters:
    ///   - paths: Canonical paths.
    ///   - roots: Canonical directories.
    /// - Returns: The paths inside, in order.
    public static func inside(_ paths: [String], _ roots: [String]) -> [String] {
        paths.filter { path in roots.contains { Self.contains($0, path) } }
    }

    /// Whether the canonical `path` is the canonical `root` or lies under it.
    static func contains(_ root: String, _ path: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Why a policy is unusable.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// A deny or allow pattern is not a valid regular expression.
        case invalidPattern(String)

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .invalidPattern(let pattern): "invalid command policy pattern: \(pattern)"
            }
        }
    }

    private static func matches(_ pattern: String, _ command: String) -> Bool {
        guard let regex = try? RegexCache.regex(pattern) else { return false }
        return regex.matches(anywhereIn: command)
    }

    /// Resolves symlinks with `realpath(3)` (for example `/var` to `/private/var`) and strips a
    /// trailing slash. For a path that does not exist yet, the longest existing prefix is resolved
    /// and the remainder appended unchanged.
    public static func canonical(_ path: String) -> String {
        var existing = path
        var remainder: [String] = []
        var resolved = existing
        while true {
            if let real = realpath(existing, nil) {
                resolved = String(cString: real)
                free(real)
                break
            }
            guard existing.count > 1 else { break }
            let url = URL(fileURLWithPath: existing)
            remainder.insert(url.lastPathComponent, at: 0)
            existing = url.deletingLastPathComponent().path
        }
        for component in remainder {
            resolved += resolved.hasSuffix("/") ? component : "/" + component
        }
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// Quotes a path for a Seatbelt string literal.
    static func quote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

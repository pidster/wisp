import Foundation

/// The line shown above each chat prompt: the model and how much of its window is used, the directory
/// with its git branch and line changes, and how approvals are decided. Facts only; each part is omitted
/// when unknown.
public struct ChatStatus: Equatable, Sendable {
    /// The model selection, as spelled for `--model`.
    public var model: String
    /// The working directory, with the home directory as `~`.
    public var directory: String
    /// The git branch, or nil outside a repository.
    public var branch: String?
    /// Whether tracked files have uncommitted changes; nil when unknown.
    public var dirty: Bool?
    /// Lines added and removed in tracked files since the last commit; nil when unknown.
    public var added: Int?
    /// See `added`.
    public var removed: Int?
    /// How approvals are decided: `approve at moderate`, `approve at dangerous`, `never asks`, or `--yes`.
    public var approval: String
    /// Fraction of the context window used, 0 to 1, or nil when neither side is known.
    public var contextUsed: Double?

    /// Creates a status.
    public init(
        model: String, directory: String, branch: String? = nil, dirty: Bool? = nil, added: Int? = nil,
        removed: Int? = nil, approval: String, contextUsed: Double? = nil
    ) {
        self.model = model
        self.directory = directory
        self.branch = branch
        self.dirty = dirty
        self.added = added
        self.removed = removed
        self.approval = approval
        self.contextUsed = contextUsed
    }

    /// The line: on the left `model:15% used · ~/src/wisp:main+12-3`, on the right the approval mode,
    /// pushed to the right edge when `width` is known and there is room, else after a separator. A
    /// context past 80% is amber; lines added are green, lines removed red.
    public func rendered(style: Style, width: Int? = nil) -> String {
        var model = style.wisp(self.model)
        if let contextUsed {
            let percent = "\(Int((contextUsed * 100).rounded()))% used"
            model += style.muted(":") + Self.contextTone(percent, used: contextUsed, style: style)
        }
        var place = style.wisp(directory)
        if let branch { place += style.muted(":") + style.glow(branch) }
        if let added, let removed, added + removed > 0 {
            place += style.added("+\(added)") + style.removed("-\(removed)")
        } else if dirty == true {
            place += style.amber("*")
        }
        let left = model + style.muted(" · ") + place
        let right = style.muted(approval)
        if let width {
            let gap = width - Style.stripped(left).count - Style.stripped(right).count
            if gap >= 3 { return left + String(repeating: " ", count: gap) + right }
        }
        return left + style.muted(" · ") + right
    }

    /// How a context use is coloured: quiet below half the window, bright from half, amber from 80%,
    /// where condensing is near (it starts at 85%).
    static func contextTone(_ text: String, used: Double, style: Style) -> String {
        if used >= 0.8 { return style.amber(text) }
        return used >= 0.5 ? style.glow(text) : style.muted(text)
    }

    /// `path` with the current user's home replaced by `~`.
    public static func abbreviated(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    )
        -> String
    {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The approval mode in words.
    public static func approvalMode(threshold: ApprovalThreshold, autoApprove: Bool) -> String {
        if autoApprove { return "--yes" }
        switch threshold {
        case .never: return "never asks"
        case .level(let level): return "approve at \(level.rawValue)"
        }
    }
}

/// What git says about a directory, read cheaply: the branch from `.git/HEAD`, and the lines added and
/// removed in tracked files from `git diff --numstat HEAD`, with a short timeout. Nil parts outside a
/// repository or without git.
public enum GitState {
    /// A directory's branch and changes.
    public struct Summary: Equatable, Sendable {
        /// The branch, or the first eight characters of a detached head.
        public var branch: String?
        /// Whether tracked files differ from the last commit.
        public var dirty: Bool?
        /// Lines added in tracked files, staged or not, since the last commit.
        public var added: Int?
        /// Lines removed.
        public var removed: Int?

        /// Creates a summary.
        public init(branch: String? = nil, dirty: Bool? = nil, added: Int? = nil, removed: Int? = nil) {
            self.branch = branch
            self.dirty = dirty
            self.added = added
            self.removed = removed
        }
    }

    /// The branch and changes of `directory`.
    public static func read(in directory: String) -> Summary {
        guard let root = repositoryRoot(of: directory) else { return Summary() }
        let head = (try? String(contentsOfFile: gitDirectory(of: root) + "/HEAD", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch: String?
        if let head, head.hasPrefix("ref: refs/heads/") {
            branch = String(head.dropFirst("ref: refs/heads/".count))
        } else {
            branch = head.map { String($0.prefix(8)) }
        }
        // Before the first commit there is no HEAD to compare with; only dirtiness can be told.
        if let numstat = git(root, ["diff", "--numstat", "HEAD"]) {
            let counts = lineCounts(numstat)
            return Summary(branch: branch, dirty: counts.files > 0, added: counts.added, removed: counts.removed)
        }
        return Summary(
            branch: branch, dirty: git(root, ["status", "--porcelain", "--untracked-files=no"]).map { !$0.isEmpty })
    }

    /// Lines added and removed, and files changed, from `git diff --numstat`; a binary file counts as a
    /// file with no lines.
    static func lineCounts(_ numstat: String) -> (added: Int, removed: Int, files: Int) {
        var added = 0
        var removed = 0
        var files = 0
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            files += 1
            added += Int(fields[0]) ?? 0
            removed += Int(fields[1]) ?? 0
        }
        return (added, removed, files)
    }

    /// Where a repository's own git files are: `.git` itself, or, in a worktree or a submodule, where
    /// the `.git` file's `gitdir:` line points, relative to the root when it is not absolute.
    static func gitDirectory(of root: String) -> String {
        let dotGit = root + "/.git"
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ")
        else { return dotGit }
        let target = line.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : URL(fileURLWithPath: root).appending(path: target).standardized.path
    }

    /// The nearest ancestor of `directory` (itself included) holding a `.git` entry.
    static func repositoryRoot(of directory: String) -> String? {
        var url = URL(fileURLWithPath: directory)
        while true {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// What `git -C root <arguments>` prints within two seconds; nil when git cannot run, fails, or
    /// takes longer.
    static func git(_ root: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

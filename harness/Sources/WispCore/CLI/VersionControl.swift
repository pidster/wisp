import Foundation
import Synchronization

/// Which version control a directory is under, found by its marker in the nearest ancestor, and what that system
/// says of it, read cheaply for the status line: the branch, and the lines added and removed since the last commit
/// (ADR 0029, amended 2026-10-15). Git and Subversion today; another system is a case of `System` with its marker
/// and a reader.
public enum VersionControl {
    /// A version control system wisp recognises.
    public enum System: String, CaseIterable, Equatable, Sendable {
        /// Git: a `.git` directory, or a `.git` file in a worktree or a submodule.
        case git
        /// Subversion: a `.svn` directory at the working copy's root (Subversion 1.7 and later).
        case svn

        /// The entry that marks a working copy's root.
        var marker: String { "." + rawValue }
    }

    /// A directory's system, branch, and changes.
    public struct Summary: Equatable, Sendable {
        /// The system it is under; nil outside a working copy.
        public var system: System?
        /// The branch: git's, or the first eight characters of a detached head; Subversion's from the working copy's
        /// URL (`trunk`, or the name under `branches/` or `tags/`).
        public var branch: String?
        /// Whether tracked files differ from the last commit.
        public var dirty: Bool?
        /// Lines added in tracked files since the last commit.
        public var added: Int?
        /// Lines removed.
        public var removed: Int?

        /// Creates a summary.
        public init(
            system: System? = nil, branch: String? = nil, dirty: Bool? = nil, added: Int? = nil, removed: Int? = nil
        ) {
            self.system = system
            self.branch = branch
            self.dirty = dirty
            self.added = added
            self.removed = removed
        }
    }

    /// The system, branch, and changes of `directory`; an empty summary outside a working copy. A system whose tool is
    /// missing or slow is still named, with the parts it could not tell left out.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The summary.
    public static func read(in directory: String) -> Summary {
        guard let (system, root) = workingCopy(of: directory) else { return Summary() }
        var summary =
            switch system {
            case .git: GitState.read(root: root)
            case .svn: SubversionState.read(root: root)
            }
        summary.system = system
        return summary
    }

    /// The nearest ancestor of `directory` (itself included) holding a system's marker, with that system. Where one
    /// directory holds two markers, the first in `System.allCases` wins.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The system and its working copy's root, or nil.
    static func workingCopy(of directory: String) -> (System, String)? {
        var url = URL(fileURLWithPath: directory)
        while true {
            for system in System.allCases
            where FileManager.default.fileExists(atPath: url.appending(path: system.marker).path) {
                return (system, url.path)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    /// How long a command that reads only the working copy may take, such as git's branch and counts or `svn status`;
    /// the status line is drawn before every prompt, so a slower answer is left out rather than waited for.
    static let quick: TimeInterval = 2
    /// How long `svn diff` may take for the line counts, which reads every changed file against its pristine copy;
    /// past it the status says the tree is dirty without counts.
    static let counting: TimeInterval = 5

    /// What `tool <arguments>` prints, run in `root`, within `timeout` seconds; nil when the tool cannot run, fails, or
    /// takes longer, when it is stopped. The output is read on another thread, so the limit holds however long the
    /// command keeps its output open.
    ///
    /// - Parameters:
    ///   - tool: The command, found on `PATH`.
    ///   - arguments: Its arguments.
    ///   - root: The directory it runs in.
    ///   - timeout: How long it may take, in seconds.
    /// - Returns: Its standard output, or nil.
    static func run(_ tool: String, _ arguments: [String], in root: String, timeout: TimeInterval = quick) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = Output()
        let reading = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            output.data.withLock { $0 = reading.readDataToEndOfFile() }
            output.done.signal()
        }
        guard output.done.wait(timeout: .now() + timeout) == .success else {
            // Stopping it closes its output, so the reading ends too.
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.data.withLock { $0 }, as: UTF8.self)
    }

    /// A command's output as it is read on another thread, and the signal that the reading ended.
    private final class Output: Sendable {
        /// What the command printed.
        let data = Mutex(Data())
        /// Signalled once the output has been read to its end.
        let done = DispatchSemaphore(value: 0)
    }
}

/// What git says about a working copy: the branch from `.git/HEAD`, and the lines added and removed in tracked files
/// from `git diff --numstat HEAD`, staged or not.
enum GitState {
    /// The branch and changes of the working copy at `root`.
    ///
    /// - Parameter root: The directory holding `.git`.
    /// - Returns: The summary, without its system.
    static func read(root: String) -> VersionControl.Summary {
        let head = (try? String(contentsOfFile: gitDirectory(of: root) + "/HEAD", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let branch: String?
        if let head, head.hasPrefix("ref: refs/heads/") {
            branch = String(head.dropFirst("ref: refs/heads/".count))
        } else {
            branch = head.map { String($0.prefix(8)) }
        }
        // Before the first commit there is no HEAD to compare with; only dirtiness can be told.
        if let numstat = VersionControl.run("git", ["diff", "--numstat", "HEAD"], in: root) {
            let counts = lineCounts(numstat)
            return .init(branch: branch, dirty: counts.files > 0, added: counts.added, removed: counts.removed)
        }
        let status = VersionControl.run("git", ["status", "--porcelain", "--untracked-files=no"], in: root)
        return .init(branch: branch, dirty: status.map { !$0.isEmpty })
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
}

/// What Subversion says about a working copy: the branch from its URL (`svn info --show-item relative-url`), whether
/// anything changed (`svn status --quiet`), and, when something did, the lines added and removed from `svn diff`. Each
/// needs the `svn` tool; without it only the system is known.
enum SubversionState {
    /// Runs `svn` with arguments, in a working copy, within a time limit: `VersionControl.run`, or a stand-in in tests.
    typealias Runner = @Sendable ([String], String, TimeInterval) -> String?

    /// The branch and changes of the working copy at `root`.
    ///
    /// - Parameters:
    ///   - root: The directory holding `.svn`.
    ///   - svn: Runs the `svn` tool.
    /// - Returns: The summary, without its system.
    static func read(
        root: String,
        svn: Runner = { arguments, root, timeout in VersionControl.run("svn", arguments, in: root, timeout: timeout) }
    ) -> VersionControl.Summary {
        let quick = VersionControl.quick
        let url = svn(["info", "--show-item", "relative-url"], root, quick)
        let branch = url.flatMap(branch(fromRelativeURL:))
        // Whether anything changed is quick to tell; the counts read every changed file, so they are asked for only
        // when something did, with longer to answer, and a tree too slow to count is still shown dirty.
        guard let status = svn(["status", "--quiet"], root, quick) else { return .init(branch: branch) }
        guard status.contains(where: { !$0.isWhitespace }) else {
            return .init(branch: branch, dirty: false, added: 0, removed: 0)
        }
        guard let diff = svn(["diff", "--internal-diff"], root, VersionControl.counting) else {
            return .init(branch: branch, dirty: true)
        }
        let counts = lineCounts(diff)
        return .init(branch: branch, dirty: true, added: counts.added, removed: counts.removed)
    }

    /// The branch a working copy's relative URL names, by the standard layout: `trunk` for `^/trunk/…`, the name for
    /// `^/branches/NAME/…` or `^/tags/NAME/…`, else the URL's last part; nil for the repository's root.
    ///
    /// - Parameter relativeURL: The URL as `svn info --show-item relative-url` prints it, such as `^/branches/x/src`.
    /// - Returns: The branch, or nil.
    static func branch(fromRelativeURL relativeURL: String) -> String? {
        let parts = relativeURL.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").map(String.init)
            .filter { $0 != "^" }
        if parts.contains("trunk") { return "trunk" }
        for kind in ["branches", "tags"] {
            if let at = parts.firstIndex(of: kind), at + 1 < parts.count { return parts[at + 1] }
        }
        return parts.last
    }

    /// Lines added and removed, and files changed, from `svn diff`'s unified output: a file per `Index:` line, and
    /// each `+` or `-` line that is not a file header.
    static func lineCounts(_ diff: String) -> (added: Int, removed: Int, files: Int) {
        var added = 0
        var removed = 0
        var files = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("Index: ") {
                files += 1
            } else if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                continue
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        return (added, removed, files)
    }
}

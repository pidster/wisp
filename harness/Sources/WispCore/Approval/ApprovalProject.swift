import Foundation

/// The project a remembered approval applies in ([ADR 0085](../../../../docs/decisions/0085-an-approval-lasts-a-time-in-its-project.md),
/// decision 3): inside a git repository, the repository, which its working tree, every subdirectory, and every
/// worktree share; elsewhere, the directory itself.
///
/// The repository is named by its common git directory, read from the `.git` entry nearest above the directory,
/// without running git. Only what git itself would accept joins a repository: a real `.git` directory, or a worktree's
/// `.git` file whose `gitdir:` is `<common>/worktrees/<name>` and whose `<name>/gitdir` points back at that same file.
/// Anything else with a `.git` entry (a link, a submodule, a file naming somewhere it does not belong) is a project of
/// its own, its folder, so a `.git` entry planted where the model can write never borrows another project's approvals.
enum ApprovalProject {
    /// The project of `directory`.
    ///
    /// - Parameter directory: Where a command runs, or where an approval was given.
    /// - Returns: The repository's common git directory, the folder of a `.git` entry that names no repository it can
    ///   be trusted to, or `directory` when no `.git` entry is above it.
    static func of(_ directory: String) -> String {
        var folder = URL(filePath: directory, directoryHint: .isDirectory).standardized
        while true {
            let git = folder.appending(path: ".git")
            switch kind(of: git) {
            case .directory: return resolved(git)
            case .file: return worktreeCommon(of: git) ?? resolved(folder)
            case .other: return resolved(folder)
            case .none: break
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return directory }
            folder = parent
        }
    }

    /// The project as a person reads it: a repository's working tree (the folder holding its common `.git`
    /// directory), else the path as it is.
    ///
    /// - Parameter project: A project, as `of(_:)` returns it.
    /// - Returns: The folder to show.
    static func shown(_ project: String) -> String {
        let url = URL(filePath: project)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : project
    }

    /// What a `.git` entry is, links not followed.
    private enum Kind {
        /// A real directory: a repository's own.
        case directory
        /// A regular file: perhaps a worktree's.
        case file
        /// Anything else, a link among them: trusted to no repository.
        case other
    }

    /// What is at `url`, without following a link; nil when nothing is.
    ///
    /// - Parameter url: The `.git` entry.
    /// - Returns: Its kind.
    private static func kind(of url: URL) -> Kind? {
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        else { return nil }
        switch type {
        case .typeDirectory: return .directory
        case .typeRegular: return .file
        default: return .other
        }
    }

    /// The common git directory of the worktree whose `.git` file is `file`, when git would accept it as one: its
    /// `gitdir:` names `<common>/worktrees/<name>`, that folder's `commondir` names `<common>`, and its `gitdir` file
    /// points back at `file`.
    ///
    /// - Parameter file: The `.git` file.
    /// - Returns: The common git directory, or nil when the file is not such a worktree's.
    private static func worktreeCommon(of file: URL) -> String? {
        guard let named = firstLine(of: file).flatMap({ value(of: "gitdir:", in: $0) }) else { return nil }
        let folder = file.deletingLastPathComponent()
        let gitdir = URL(filePath: named, directoryHint: .isDirectory, relativeTo: folder).absoluteURL
        guard let shared = firstLine(of: gitdir.appending(path: "commondir")), !shared.isEmpty,
            let back = firstLine(of: gitdir.appending(path: "gitdir")), !back.isEmpty
        else { return nil }
        let common = resolved(URL(filePath: shared, directoryHint: .isDirectory, relativeTo: gitdir).absoluteURL)
        let home = resolved(gitdir)
        let pointsBack = resolved(URL(filePath: back, relativeTo: gitdir).absoluteURL) == resolved(file)
        let underWorktrees =
            URL(filePath: home).deletingLastPathComponent().lastPathComponent == "worktrees"
            && URL(filePath: home).deletingLastPathComponent().deletingLastPathComponent().path == common
        return pointsBack && underWorktrees && kind(of: URL(filePath: common)) == .directory ? common : nil
    }

    /// The first line of the file at `url`, trimmed; nil when it cannot be read.
    ///
    /// - Parameter url: The file.
    /// - Returns: The line.
    private static func firstLine(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The value after `key` in `line`, trimmed; nil when the line does not start with it.
    ///
    /// - Parameters:
    ///   - key: Such as `gitdir:`.
    ///   - line: The line.
    /// - Returns: The value.
    private static func value(of key: String, in line: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let value = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `url` standardised with its links resolved, so two spellings of one directory compare equal.
    ///
    /// - Parameter url: A directory.
    /// - Returns: Its path.
    private static func resolved(_ url: URL) -> String {
        url.standardized.resolvingSymlinksInPath().path
    }
}

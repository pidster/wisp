import Foundation

extension LlamaCppAgent {
    /// How `Wisp.app` tells and removes a LaunchAgent file whose `wisp` is gone (`State.abandoned`,
    /// [ADR 0084](../../../../docs/decisions/0084-homebrew-installs-the-app-from-a-cask.md), decision 8): Homebrew's
    /// formula wrote one naming its `opt` link, which goes when the formula is uninstalled on the move to the cask.
    /// Only a file of the agent's own name that names a program is ever judged; tests pass their own.
    struct AbandonedFiles: Sendable {
        /// The program a LaunchAgent file names first in `ProgramArguments`, nil when it cannot be read.
        var program: @Sendable (String) -> String?
        /// Whether a path exists.
        var exists: @Sendable (String) -> Bool
        /// Removes a file.
        var remove: @Sendable (String) throws -> Void

        /// The files on disk.
        static let live = AbandonedFiles(
            program: { path in
                guard let data = FileManager.default.contents(atPath: path),
                    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                    let arguments = plist["ProgramArguments"] as? [String]
                else { return nil }
                return arguments.first
            },
            exists: { FileManager.default.fileExists(atPath: $0) },
            remove: { try FileManager.default.removeItem(atPath: $0) })

        /// Whether the file at `path` is the agent's, names a program, and that program no longer exists.
        ///
        /// - Parameter path: The LaunchAgent file.
        /// - Returns: True when nothing is behind it.
        func isAbandoned(_ path: String) -> Bool {
            guard URL(filePath: path).lastPathComponent == LlamaCppAgent.plistName, let program = program(path) else {
                return false
            }
            return !exists(program)
        }

        /// Removes the LaunchAgent file `launchctl print` names, when it is abandoned, so launchd does not load it
        /// again at the next login.
        ///
        /// - Parameter printed: `launchctl print gui/<uid>/<label>`'s output.
        /// - Returns: True when a file was removed.
        /// - Throws: `Failure.file` when it could not be.
        @discardableResult
        func removeIfAbandoned(_ printed: String) throws -> Bool {
            guard case .file(let path) = LlamaCppAgent.holder(printed), isAbandoned(path) else { return false }
            do {
                try remove(path)
            } catch {
                throw LlamaCppAgent.Failure.file("cannot remove \(path): \(error.localizedDescription)")
            }
            return true
        }
    }
}

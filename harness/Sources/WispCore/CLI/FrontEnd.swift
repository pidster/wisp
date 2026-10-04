import Foundation

/// Where `wisp chat` finds `wisp-tui`, the front end it hands an interactive terminal session to
/// ([ADR 0029](../../../../docs/decisions/0029-tui-front-end.md)).
public enum FrontEnd {
    /// The front end's file name.
    public static let name = "wisp-tui"

    /// The places to look, in order, for an executable at `executable` (its real path, links resolved): the
    /// same folder, as in a build directory or a plain `bin`; then a `bin` beside that folder, the
    /// `libexec`-and-`bin` layout Homebrew installs, where `wisp` lives in `libexec` beside the MLX library
    /// ([ADR 0047](../../../../docs/decisions/0047-mlx-in-the-release.md)) and `wisp-tui` in `bin`.
    ///
    /// - Parameter executable: The running `wisp`, links resolved.
    /// - Returns: The candidate paths, without duplicates.
    public static func candidates(besides executable: URL) -> [URL] {
        let folder = executable.deletingLastPathComponent()
        let beside = folder.appending(path: name)
        let sibling = folder.deletingLastPathComponent().appending(path: "bin").appending(path: name)
        return beside.standardizedFileURL == sibling.standardizedFileURL ? [beside] : [beside, sibling]
    }

    /// The first candidate that is an executable file, or nil.
    ///
    /// - Parameters:
    ///   - executable: The running `wisp`, links resolved.
    ///   - exists: Whether a path is an executable file.
    /// - Returns: Where `wisp-tui` is, or nil when it is in none of the places looked.
    public static func locate(
        besides executable: URL, exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates(besides: executable).first { exists($0.path) }
    }

    /// The running executable's real path: `Bundle.main`'s, not `argv[0]`, which is a bare name when launched
    /// through `PATH`, with links resolved.
    public static var runningExecutable: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }
}

import Foundation

/// Where `wisp chat` finds `wisp-tui`, the front end it hands an interactive terminal session to
/// ([ADR 0029](../../../../docs/decisions/0029-tui-front-end.md)).
public enum FrontEnd {
    /// The front end's file name.
    public static let name = "wisp-tui"

    /// The environment variable naming a `wisp-tui` to use ahead of every other place, for an odd set-up.
    public static let overrideVariable = "WISP_TUI"

    /// The places to look, in order, for an executable at `executable` (its real path, links resolved): the path
    /// `WISP_TUI` names; the one the package declares ([ADR 0072](../../../../docs/decisions/0072-a-dmg-and-a-declared-layout.md));
    /// then, searching, the same folder, as in a build directory or a plain `bin`, and a `bin` beside that folder,
    /// the `libexec`-and-`bin` layout Homebrew installs, where `wisp` lives in `libexec` beside the MLX library
    /// ([ADR 0047](../../../../docs/decisions/0047-mlx-in-the-release.md)) and `wisp-tui` in `bin`.
    ///
    /// - Parameters:
    ///   - executable: The running `wisp`, links resolved.
    ///   - declared: Where the package declares `wisp-tui`, if it does.
    ///   - override: The `WISP_TUI` variable's value, if set.
    /// - Returns: The candidate paths, without duplicates.
    public static func candidates(besides executable: URL, declared: URL? = nil, override: String? = nil) -> [URL] {
        let folder = executable.deletingLastPathComponent()
        var paths: [URL] = []
        if let override, !override.isEmpty { paths.append(URL(filePath: override)) }
        if let declared { paths.append(declared) }
        paths.append(folder.appending(path: name))
        paths.append(folder.deletingLastPathComponent().appending(path: "bin").appending(path: name))
        var seen: Set<String> = []
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The first candidate that is an executable file, or nil.
    ///
    /// - Parameters:
    ///   - executable: The running `wisp`, links resolved.
    ///   - declared: Where the package declares `wisp-tui`, if it does.
    ///   - override: The `WISP_TUI` variable's value, if set.
    ///   - exists: Whether a path is an executable file.
    /// - Returns: Where `wisp-tui` is, or nil when it is in none of the places looked.
    public static func locate(
        besides executable: URL, declared: URL? = nil, override: String? = nil,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        candidates(besides: executable, declared: declared, override: override).first { exists($0.path) }
    }

    /// Where the running package declares `wisp-tui`, if it does.
    public static var declared: URL? { PackageLayout.current.layout?.parts[.frontEnd] }

    /// The `WISP_TUI` variable, if set.
    public static var override: String? { ProcessInfo.processInfo.environment[overrideVariable] }

    /// The running executable's real path, with links resolved (`ExecutablePath`): never `argv[0]`, which is a
    /// bare name when launched through `PATH` and a chosen name when a parent names its child at spawn (ADR 0061).
    /// Nil only when the kernel and Foundation both cannot say, and then `wisp chat` stays the plain chat.
    public static var runningExecutable: URL? { ExecutablePath.current }
}

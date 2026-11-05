import Foundation

/// The move from Homebrew's formula to its cask ([ADR 0084](../../../../docs/decisions/0084-homebrew-installs-the-app-from-a-cask.md)):
/// what Homebrew holds of wisp, and what to run to finish the move. Homebrew moves an install itself only for a person
/// who trusts the cask or the tap; a person who installed the formula by name trusts the formula alone, so most move by
/// hand, and in this order, since the cask installs without its links while the formula's are in the way (probed on
/// 2026-11-04, `docs/measurements.md`).
public struct HomebrewMove: Equatable, Sendable {
    /// The cask's name, fully qualified.
    public static let cask = "pidster/tap/wisp"
    /// The tap, trusted whole by the first command, the cask with it.
    public static let tap = "pidster/tap"
    /// The commands that move a formula install to the cask, in the order they must run.
    public static let commands = [
        "brew trust \(tap)", "brew uninstall --formula wisp", "brew install --cask \(cask)",
    ]
    /// The commands, joined to run as one line.
    public static var line: String { commands.joined(separator: " && ") }

    /// Whether Homebrew's Caskroom holds the cask.
    public var cask: Bool
    /// Whether Homebrew's Cellar holds the formula's keg, linked or not.
    public var keg: Bool
    /// The first `wisp` on `PATH`, links resolved; nil when there is none.
    public var onPath: URL?

    /// Creates a reading.
    ///
    /// - Parameters:
    ///   - cask: Whether the Caskroom holds the cask.
    ///   - keg: Whether the Cellar holds the formula's keg.
    ///   - onPath: The first `wisp` on `PATH`, links resolved.
    public init(cask: Bool = false, keg: Bool = false, onPath: URL? = nil) {
        self.cask = cask
        self.keg = keg
        self.onPath = onPath
    }

    /// Whether the `wisp` on `PATH` is the formula's, from its Cellar.
    public var formulaOnPath: Bool { onPath.map(Self.inCellar) ?? false }

    /// Whether `url` is in Homebrew's Cellar for wisp.
    ///
    /// - Parameter url: A path, links resolved.
    /// - Returns: True for `<prefix>/Cellar/wisp/…`.
    static func inCellar(_ url: URL) -> Bool { url.path.contains("/Cellar/wisp/") }

    /// Homebrew's prefix: `HOMEBREW_PREFIX` when set, else Apple silicon's `/opt/homebrew`.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: The prefix.
    public static func prefix(_ environment: [String: String]) -> URL {
        URL(filePath: environment["HOMEBREW_PREFIX"].flatMap { $0.isEmpty ? nil : $0 } ?? "/opt/homebrew")
    }

    /// Reads what Homebrew holds of wisp, and the first `wisp` on `PATH`.
    ///
    /// - Parameters:
    ///   - environment: The process environment, for `HOMEBREW_PREFIX` and `PATH`.
    ///   - exists: Whether a directory exists.
    ///   - executable: Whether a path is an executable file.
    /// - Returns: The reading.
    public static func read(
        environment: [String: String],
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        executable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> HomebrewMove {
        let prefix = prefix(environment)
        let folders = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) }
        let found = folders.lazy.map { $0.appending(path: "wisp") }.first(where: executable)
        return HomebrewMove(
            cask: exists(prefix.appending(path: "Caskroom/wisp")), keg: exists(prefix.appending(path: "Cellar/wisp")),
            onPath: found?.resolvingSymlinksInPath())
    }
}

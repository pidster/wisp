import Foundation

/// `wisp install` and `wisp uninstall`: links to `Wisp.app`'s `wisp` and `wisp-tui` in a folder on the person's `PATH`,
/// `~/.local/bin` unless another is given, with no administrator's password
/// ([ADR 0073](../../../../docs/decisions/0073-wisp-install-and-the-finder.md)). Only the app installs this way: a
/// Homebrew install owns its links, and a build or an unpacked tarball is put on `PATH` by the person. A file in the way
/// is never replaced; a link elsewhere only with `--force`. Uninstalling removes a link only when it points into the
/// running app, so no record of what was linked is kept. Shell start-up files are never edited.
public enum AppInstall {
    /// The executables linked, each in the app's `Contents/MacOS`.
    public static let names = ["wisp", FrontEnd.name]

    /// The folder linked into when none is given, under the home directory.
    public static let defaultFolder = ".local/bin"

    /// Where the running `wisp` came from, which decides whether it may link itself.
    public enum Source: Equatable, Sendable {
        /// `Wisp.app`, where it may be linked from.
        case app(URL)
        /// `Wisp.app` on a read-only volume: the disk image, before it was dragged to Applications.
        case diskImage(URL)
        /// `Wisp.app` run from the temporary copy macOS makes of an app opened where it was downloaded.
        case translocated(URL)
        /// The Homebrew formula, which declares its layout in a manifest and links `wisp` itself.
        case homebrew
        /// Neither: a build directory, or a tarball unpacked by hand.
        case elsewhere

        /// Why `wisp install` or `uninstall` cannot run from here, or nil when it can.
        public var refusal: String? {
            switch self {
            case .app: nil
            case .diskImage:
                "Wisp.app is running from the disk image; drag it to Applications, then run "
                    + "/Applications/Wisp.app/Contents/MacOS/wisp install"
            case .translocated:
                "macOS is running a temporary copy of Wisp.app, as it does for an app opened where it was downloaded; "
                    + "move Wisp.app to Applications and run it from there"
            case .homebrew:
                "this wisp was installed by Homebrew, which puts it on PATH itself; wisp install is for Wisp.app"
            case .elsewhere:
                "this wisp is not in Wisp.app; a build or an unpacked tarball is put on PATH by hand"
            }
        }
    }

    /// Where the running `wisp` came from, by its declared layout.
    ///
    /// - Parameters:
    ///   - reading: The running `wisp`'s declared layout (`PackageLayout.current`).
    ///   - isReadOnly: Whether a path is on a read-only volume.
    /// - Returns: The source.
    public static func source(of reading: PackageLayout.Reading, isReadOnly: (URL) -> Bool = volumeIsReadOnly) -> Source
    {
        guard let layout = reading.layout else { return .elsewhere }
        switch layout.declaration {
        case .manifest: return .homebrew
        case .app(let app):
            if app.path.contains("/AppTranslocation/") { return .translocated(app) }
            if isReadOnly(app) { return .diskImage(app) }
            return .app(app)
        }
    }

    /// Whether `url` is on a read-only volume, false when that cannot be read.
    ///
    /// - Parameter url: The path.
    /// - Returns: True on a read-only volume, such as a mounted disk image.
    public static func volumeIsReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// The folder to link into: `folder` when given, made absolute against the working directory, else
    /// `~/.local/bin`.
    ///
    /// - Parameters:
    ///   - folder: The folder the person named, if any.
    ///   - home: The home directory.
    /// - Returns: The folder.
    public static func folder(_ folder: String?, home: URL) -> URL {
        guard let folder, !folder.isEmpty else { return home.appending(path: defaultFolder).standardizedFileURL }
        let expanded = folder == "~" ? home.path : folder.hasPrefix("~/") ? home.path + folder.dropFirst(1) : folder
        return URL(filePath: expanded, directoryHint: .isDirectory).standardizedFileURL
    }

    /// What is at a path in the folder now.
    public enum Existing: Equatable, Sendable {
        /// Nothing.
        case nothing
        /// A link, with its destination made absolute.
        case link(String)
        /// A file or folder that is not a link.
        case file
    }

    /// What is at `url`, without following a link.
    ///
    /// - Parameter url: The path.
    /// - Returns: What is there.
    public static func inspect(_ url: URL) -> Existing {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: url.path) {
            let absolute =
                destination.hasPrefix("/") ? destination : url.deletingLastPathComponent().path + "/" + destination
            return .link(URL(filePath: absolute).standardizedFileURL.path)
        }
        return (try? manager.attributesOfItem(atPath: url.path)) == nil ? .nothing : .file
    }

    /// Whether a link's destination is inside `app`.
    static func isInside(_ destination: String, app: URL) -> Bool {
        destination.hasPrefix(app.standardizedFileURL.path + "/")
    }

    /// One executable's link and what installing does with it.
    public struct Entry: Equatable, Sendable {
        /// What installing does.
        public enum Action: Equatable, Sendable {
            /// Nothing is there: link.
            case create
            /// The link already points to the app's executable.
            case unchanged
            /// A link elsewhere, replaced under `--force`; its destination.
            case replace(String)
            /// A link elsewhere, left without `--force`; its destination.
            case blockedByLink(String)
            /// A file that is not a link, never replaced.
            case blockedByFile
        }

        /// The executable's name.
        public var name: String
        /// The link's path in the folder.
        public var link: URL
        /// The executable in the app it points to.
        public var target: URL
        /// What installing does.
        public var action: Action
    }

    /// What installing into `folder` would do for each executable, reading what is there now.
    ///
    /// - Parameters:
    ///   - app: The running `Wisp.app`.
    ///   - folder: The folder to link into.
    ///   - force: Whether a link elsewhere is replaced.
    ///   - existing: What is at a path now.
    /// - Returns: One entry an executable, in `names`' order.
    static func plan(
        app: URL, folder: URL, force: Bool, existing: (URL) -> Existing = inspect(_:)
    ) -> [Entry] {
        names.map { name in
            let link = folder.appending(path: name)
            let target = app.appending(path: "Contents/MacOS/\(name)").standardizedFileURL
            let action: Entry.Action =
                switch existing(link) {
                case .nothing: .create
                case .link(let destination) where destination == target.path: .unchanged
                case .link(let destination): force ? .replace(destination) : .blockedByLink(destination)
                case .file: .blockedByFile
                }
            return Entry(name: name, link: link, target: target, action: action)
        }
    }

    /// A failure to install or uninstall, said to the person.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Not from `Wisp.app`; why.
        case refused(String)
        /// Something in the folder is in the way; each line names one.
        case blocked([String])
        /// The file system refused a step.
        case io(String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .refused(let reason): reason
            case .blocked(let lines): lines.joined(separator: "\n")
            case .io(let message): message
            }
        }
    }

    /// What installing did, a line an executable, then where they are and whether the folder is on `PATH`.
    public struct Report: Equatable, Sendable {
        /// The executables' lines.
        public var lines: [String]
        /// Whether anything changed.
        public var changed: Bool
    }

    /// Links each executable into `folder`, creating it, or changes nothing when any is blocked.
    ///
    /// - Parameters:
    ///   - app: The running `Wisp.app`.
    ///   - folder: The folder to link into.
    ///   - force: Whether a link elsewhere is replaced.
    ///   - home: The home directory, for shortening paths.
    /// - Returns: What was done.
    /// - Throws: `Failure.blocked` naming what is in the way, `Failure.io` when a step fails.
    public static func install(app: URL, folder: URL, force: Bool, home: URL) throws -> Report {
        let entries = plan(app: app, folder: folder, force: force)
        let shown = { (url: URL) in ShellCompletions.tilde(url.path, home: home) }
        let blocked = entries.compactMap { entry -> String? in
            switch entry.action {
            case .blockedByLink(let destination):
                "\(shown(entry.link)) links to \(destination); wisp install --force replaces it"
            case .blockedByFile:
                "\(shown(entry.link)) is a file wisp did not make; remove or rename it, then run wisp install again"
            default: nil
            }
        }
        guard blocked.isEmpty else { throw Failure.blocked(blocked) }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.io("cannot create \(shown(folder)): \(error.localizedDescription)")
        }
        var lines: [String] = []
        for entry in entries {
            do {
                switch entry.action {
                case .unchanged:
                    lines.append("\(shown(entry.link)) already links to \(entry.target.path)")
                    continue
                case .replace(let old):
                    try manager.removeItem(at: entry.link)
                    lines.append("\(shown(entry.link)) now links to \(entry.target.path), not \(old)")
                default:
                    lines.append("linked \(shown(entry.link)) to \(entry.target.path)")
                }
                try manager.createSymbolicLink(atPath: entry.link.path, withDestinationPath: entry.target.path)
            } catch {
                throw Failure.io("cannot link \(shown(entry.link)): \(error.localizedDescription)")
            }
        }
        return Report(lines: lines, changed: entries.contains { $0.action != .unchanged })
    }

    /// Removes each link in `folder` that points into `app`, and leaves anything else, naming it.
    ///
    /// - Parameters:
    ///   - app: The running `Wisp.app`.
    ///   - folder: The folder the links are in.
    ///   - home: The home directory, for shortening paths.
    /// - Returns: A line an executable.
    /// - Throws: `Failure.io` when a removal fails.
    public static func uninstall(app: URL, folder: URL, home: URL) throws -> [String] {
        try names.map { name in
            let link = folder.appending(path: name)
            let shown = ShellCompletions.tilde(link.path, home: home)
            switch inspect(link) {
            case .nothing: return "no \(shown)"
            case .file: return "left \(shown): a file wisp did not make"
            case .link(let destination) where !isInside(destination, app: app):
                return "left \(shown): it links to \(destination), not into \(app.path)"
            case .link:
                do {
                    try FileManager.default.removeItem(at: link)
                } catch {
                    throw Failure.io("cannot remove \(shown): \(error.localizedDescription)")
                }
                return "removed \(shown)"
            }
        }
    }

    /// Whether `folder` is one of `PATH`'s entries, links resolved on both sides.
    ///
    /// - Parameters:
    ///   - folder: The folder.
    ///   - path: The value of `PATH`.
    /// - Returns: True when a shell finds the links by name.
    public static func isOnPath(_ folder: URL, path: String?) -> Bool {
        let wanted = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return (path ?? "").split(separator: ":").contains {
            URL(filePath: String($0), directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath().path
                == wanted
        }
    }

    /// What to add to the shell's start-up file to put `folder` on `PATH`; wisp never edits it.
    ///
    /// - Parameters:
    ///   - folder: The folder.
    ///   - shell: The person's shell, nil when unknown.
    ///   - home: The home directory.
    ///   - known: Whether the folder is known to be off `PATH`; false where `PATH` cannot be read, as from the Finder,
    ///     whose `PATH` is not a terminal's.
    /// - Returns: The lines to show.
    public static func pathAdvice(
        _ folder: URL, shell: ShellCompletions.Shell?, home: URL, known: Bool = true
    ) -> [String] {
        let shown = ShellCompletions.tilde(folder.path, home: home)
        let variable = shown.hasPrefix("~/") ? "$HOME" + shown.dropFirst(1) : shown
        let lead = known ? "\(shown) is not on PATH; " : "If a new terminal cannot find wisp, \(shown) is not on PATH; "
        switch shell {
        case .fish:
            return [lead + "run this once in fish:", "  fish_add_path \(variable)"]
        case .bash:
            return [
                lead + "add this line to ~/.bash_profile, then open a new terminal:",
                "  export PATH=\"\(variable):$PATH\"",
            ]
        case .zsh, nil:
            let file = shell == .zsh ? "~/.zshrc" : "your shell's start-up file"
            return [
                lead + "add this line to \(file), then open a new terminal:", "  export PATH=\"\(variable):$PATH\"",
            ]
        }
    }

    /// Whether this process is `Wisp.app` opened from the Finder: in an app, with no arguments but the process
    /// serial number an older macOS passes, no terminal on stdin, and `launchd` as its parent.
    ///
    /// - Parameters:
    ///   - arguments: The command line, the executable first.
    ///   - stdinIsTerminal: Whether stdin is a terminal.
    ///   - parent: The parent process id.
    ///   - inApp: Whether `wisp` runs from an app bundle.
    /// - Returns: True for a launch with no terminal to speak to.
    public static func isFinderLaunch(arguments: [String], stdinIsTerminal: Bool, parent: Int32, inApp: Bool) -> Bool {
        inApp && !stdinIsTerminal && parent == 1 && arguments.dropFirst().allSatisfy { $0.hasPrefix("-psn_") }
    }

    /// What the Finder dialog says before anything is done.
    public struct Welcome: Equatable, Sendable {
        /// The headline.
        public var title: String
        /// The explanation.
        public var text: String
        /// Whether it offers to install.
        public var offersInstall: Bool
    }

    /// The Finder dialog for the running `wisp`, linking into `folder`.
    ///
    /// - Parameters:
    ///   - source: Where the running `wisp` came from.
    ///   - folder: The folder it would link into.
    ///   - home: The home directory.
    ///   - existing: What is at a path now.
    /// - Returns: The dialog.
    public static func welcome(
        source: Source, folder: URL, home: URL, existing: (URL) -> Existing = inspect(_:)
    ) -> Welcome {
        let title = "Wisp is a command-line tool"
        guard case .app(let app) = source else {
            return Welcome(title: title, text: (source.refusal ?? "") + ".", offersInstall: false)
        }
        let shown = ShellCompletions.tilde(folder.path, home: home)
        let entries = plan(app: app, folder: folder, force: false, existing: existing)
        if entries.allSatisfy({ $0.action == .unchanged }) {
            return Welcome(
                title: title,
                text: "wisp and wisp-tui are installed in \(shown). Open a terminal and run wisp chat, or wisp --help. "
                    + "To remove them, run wisp uninstall.",
                offersInstall: false)
        }
        if entries.contains(where: { if case .blockedByFile = $0.action { true } else { false } }) {
            return Welcome(
                title: title,
                text: "Something not made by wisp is in the way in \(shown). Open a terminal and run "
                    + "\(app.path)/Contents/MacOS/wisp install to see what.",
                offersInstall: false)
        }
        if entries.contains(where: { if case .blockedByLink = $0.action { true } else { false } }) {
            return Welcome(
                title: title,
                text: "\(shown) has links to another wisp. Open a terminal and run "
                    + "\(app.path)/Contents/MacOS/wisp install --force to point them at this app.",
                offersInstall: false)
        }
        return Welcome(
            title: title,
            text: "Install puts links to wisp and wisp-tui in \(shown), so a terminal can run them. It needs no "
                + "administrator's password, and wisp uninstall removes them.",
            offersInstall: true)
    }
}

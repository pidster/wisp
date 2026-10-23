import Foundation
import WispNotifierKit

/// Where the parts of an installed wisp are, as its package declares them
/// ([ADR 0072](../../../../docs/decisions/0072-a-dmg-and-a-declared-layout.md)): `Wisp.app` in its `Info.plist`, under
/// `WispLayout`, and the Homebrew formula in `wisp-layout.json` beside `wisp` in `libexec`. Each part is a path
/// relative to the folder `wisp` is in. A build directory, or a tarball unpacked by hand, declares nothing, and the
/// parts are found by searching beside `wisp` as before.
public struct PackageLayout: Equatable, Sendable {
    /// A part of the package besides `wisp` itself.
    public enum Part: String, CaseIterable, Sendable {
        /// `wisp-tui`, the terminal front end.
        case frontEnd
        /// `Wisp Notifier.app`, the notification helper.
        case notifier
        /// MLX's Metal library.
        case metalLibrary

        /// The part as a person knows it.
        public var label: String {
            switch self {
            case .frontEnd: FrontEnd.name
            case .notifier: NotifierProtocol.bundleName
            case .metalLibrary: "the Metal library"
            }
        }
    }

    /// What declared a layout.
    public enum Declaration: Equatable, Sendable {
        /// The app bundle `wisp` runs from, in its `Info.plist`.
        case app(URL)
        /// The manifest beside `wisp`.
        case manifest(URL)

        /// Where the declaration is, for the doctor.
        public var source: URL {
            switch self {
            case .app(let app): app.appending(path: "Contents/Info.plist")
            case .manifest(let file): file
            }
        }
    }

    /// What reading the declaration found.
    public enum Reading: Equatable, Sendable {
        /// No package declares a layout: the parts are searched for.
        case none
        /// A declared layout.
        case declared(PackageLayout)
        /// A declaration that could not be read, and why.
        case malformed(source: URL, reason: String)

        /// The layout, when one is declared and readable.
        public var layout: PackageLayout? {
            if case .declared(let layout) = self { return layout }
            return nil
        }
    }

    /// The key in `Wisp.app`'s `Info.plist`.
    public static let infoKey = "WispLayout"
    /// The manifest's file name, beside `wisp`.
    public static let manifestName = "wisp-layout.json"

    /// What declared it.
    public var declaration: Declaration
    /// Each declared part's absolute path.
    public var parts: [Part: URL]

    /// The app bundle `wisp` runs from, or nil when it is not in one.
    public var app: URL? {
        if case .app(let app) = declaration { return app }
        return nil
    }

    /// The app bundle holding `executable` in its `Contents/MacOS`, or nil.
    ///
    /// - Parameter executable: The running `wisp`, links resolved.
    /// - Returns: The bundle.
    public static func appBundle(of executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app"
        else { return nil }
        return app
    }

    /// Reads the layout declared for `executable`: its app bundle's `Info.plist` when it runs from one, else the
    /// manifest beside it.
    ///
    /// - Parameters:
    ///   - executable: The running `wisp`, links resolved.
    ///   - read: Reads a file, nil when it is absent.
    /// - Returns: What was found.
    public static func read(
        besides executable: URL, read: (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) -> Reading {
        let folder = executable.deletingLastPathComponent()
        if let app = appBundle(of: executable) {
            let declaration = Declaration.app(app)
            guard let data = read(declaration.source) else { return .none }
            let info: Any
            do {
                info = try PropertyListSerialization.propertyList(from: data, format: nil)
            } catch {
                return .malformed(source: declaration.source, reason: "not a property list")
            }
            guard let entry = (info as? [String: Any])?[infoKey] else { return .none }
            return parse(entry, declaration: declaration, folder: folder)
        }
        let declaration = Declaration.manifest(folder.appending(path: manifestName))
        guard let data = read(declaration.source) else { return .none }
        guard let entry = try? JSONSerialization.jsonObject(with: data) else {
            return .malformed(source: declaration.source, reason: "not JSON")
        }
        return parse(entry, declaration: declaration, folder: folder)
    }

    /// The parts from a declaration's dictionary, each a relative path from `folder`. Keys this wisp does not know are
    /// left alone, so a later package may declare more.
    private static func parse(_ entry: Any, declaration: Declaration, folder: URL) -> Reading {
        guard let dictionary = entry as? [String: Any] else {
            return .malformed(source: declaration.source, reason: "the layout is not a dictionary of paths")
        }
        var parts: [Part: URL] = [:]
        for part in Part.allCases {
            guard let value = dictionary[part.rawValue] else { continue }
            guard let path = value as? String, !path.isEmpty, !path.hasPrefix("/") else {
                return .malformed(
                    source: declaration.source, reason: "\(part.rawValue) is not a path relative to wisp's folder")
            }
            parts[part] = folder.appending(path: path).standardizedFileURL
        }
        return .declared(PackageLayout(declaration: declaration, parts: parts))
    }

    /// The running `wisp`'s declared layout, read once a process.
    public static let current: Reading = ExecutablePath.current.map { read(besides: $0) } ?? .none

    /// Opens the app bundle the running `wisp` is in, so MLX, which looks for its Metal library in every bundle the
    /// process has opened, finds it in the app's resources when `wisp` was started through a link outside the app,
    /// where Foundation's main bundle is the link's folder (probed 2026-10-23). Does nothing outside an app.
    public static func openAppBundle() {
        guard let app = current.layout?.app else { return }
        _ = Bundle(url: app)
    }
}

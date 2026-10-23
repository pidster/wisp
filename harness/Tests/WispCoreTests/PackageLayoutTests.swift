import Foundation
import Testing

@testable import WispCore

/// Where a package declares its parts, read from an app's `Info.plist` or the formula's manifest, without files on
/// disk (ADR 0072).
@Suite struct PackageLayoutTests {
    private let app = URL(fileURLWithPath: "/Applications/Wisp.app")
    private var appWisp: URL { app.appending(path: "Contents/MacOS/wisp") }
    private let cellarWisp = URL(fileURLWithPath: "/opt/homebrew/Cellar/wisp/0.31.0/libexec/wisp")

    private func plist(_ layout: [String: Any]?) throws -> Data {
        var info: [String: Any] = ["CFBundleIdentifier": "com.pidster.wisp"]
        if let layout { info[PackageLayout.infoKey] = layout }
        return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }

    @Test func findsTheAppAnExecutableRunsFrom() {
        #expect(PackageLayout.appBundle(of: appWisp)?.path == app.path)
        #expect(PackageLayout.appBundle(of: cellarWisp) == nil)
        #expect(PackageLayout.appBundle(of: URL(fileURLWithPath: "/opt/Contents/MacOS/wisp")) == nil)
        #expect(PackageLayout.appBundle(of: URL(fileURLWithPath: "/x/Wisp.app/Contents/Helpers/wisp")) == nil)
    }

    @Test func readsTheAppsInfoPlist() throws {
        let data = try plist([
            "frontEnd": "wisp-tui", "notifier": "../Helpers/Wisp Notifier.app",
            "metalLibrary": "../Resources/mlx-swift_Cmlx.bundle/default.metallib", "later": "ignored",
        ])
        let reading = PackageLayout.read(besides: appWisp) { $0.path.hasSuffix("Contents/Info.plist") ? data : nil }
        let layout = try #require(reading.layout)
        #expect(layout.app?.path == app.path)
        #expect(layout.declaration.source.path == "/Applications/Wisp.app/Contents/Info.plist")
        #expect(layout.parts[.frontEnd]?.path == "/Applications/Wisp.app/Contents/MacOS/wisp-tui")
        #expect(layout.parts[.notifier]?.path == "/Applications/Wisp.app/Contents/Helpers/Wisp Notifier.app")
        #expect(
            layout.parts[.metalLibrary]?.path
                == "/Applications/Wisp.app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")
        // An app whose Info.plist declares nothing, or that has none, searches as before.
        let bare = try plist(nil)
        #expect(PackageLayout.read(besides: appWisp) { _ in bare } == .none)
        #expect(PackageLayout.read(besides: appWisp) { _ in nil } == .none)
    }

    @Test func readsTheFormulasManifest() throws {
        let manifest = Data(
            #"{"frontEnd": "../bin/wisp-tui", "notifier": "Wisp Notifier.app", "metalLibrary": "mlx.metallib"}"#.utf8)
        var asked: [String] = []
        let reading = PackageLayout.read(besides: cellarWisp) {
            asked.append($0.path)
            return manifest
        }
        #expect(asked == ["/opt/homebrew/Cellar/wisp/0.31.0/libexec/wisp-layout.json"])
        let layout = try #require(reading.layout)
        #expect(layout.app == nil)
        #expect(layout.parts[.frontEnd]?.path == "/opt/homebrew/Cellar/wisp/0.31.0/bin/wisp-tui")
        #expect(layout.parts[.metalLibrary]?.path == "/opt/homebrew/Cellar/wisp/0.31.0/libexec/mlx.metallib")
        #expect(PackageLayout.read(besides: cellarWisp) { _ in nil } == .none)
    }

    @Test func refusesAMalformedDeclaration() throws {
        let manifest = "/opt/homebrew/Cellar/wisp/0.31.0/libexec/wisp-layout.json"
        func reason(_ reading: PackageLayout.Reading) -> String? {
            if case .malformed(let source, let reason) = reading,
                source.path.hasSuffix(manifest)
                    || source
                        .path.hasSuffix("Info.plist")
            {
                return reason
            }
            return nil
        }
        #expect(reason(PackageLayout.read(besides: cellarWisp) { _ in Data("{".utf8) }) == "not JSON")
        #expect(
            reason(PackageLayout.read(besides: cellarWisp) { _ in Data("[1]".utf8) })?.contains("dictionary") == true)
        let absolute = Data(#"{"frontEnd": "/usr/local/bin/wisp-tui"}"#.utf8)
        #expect(reason(PackageLayout.read(besides: cellarWisp) { _ in absolute })?.hasPrefix("frontEnd") == true)
        let number = Data(#"{"notifier": 3}"#.utf8)
        #expect(reason(PackageLayout.read(besides: cellarWisp) { _ in number })?.hasPrefix("notifier") == true)
        #expect(reason(PackageLayout.read(besides: appWisp) { _ in Data("not a plist".utf8) }) == "not a property list")
        let notADictionary = try plist(nil)
        var info = try #require(
            try PropertyListSerialization.propertyList(from: notADictionary, format: nil) as? [String: Any])
        info[PackageLayout.infoKey] = "wisp-tui"
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        #expect(reason(PackageLayout.read(besides: appWisp) { _ in data })?.contains("dictionary") == true)
    }

    /// The doctor's `package` finding: every declared part present passes; one missing fails, naming it; nothing
    /// declared passes; a declaration that cannot be read fails.
    @Test func theDoctorChecksEveryDeclaredPart() {
        let home = Home(
            root: FileManager.default.temporaryDirectory.appending(path: "wisp-doctor-\(UUID().uuidString)"))
        let layout = PackageLayout(
            declaration: .app(app),
            parts: [
                .frontEnd: app.appending(path: "Contents/MacOS/wisp-tui"),
                .notifier: app.appending(path: "Contents/Helpers/Wisp Notifier.app"),
            ])
        func finding(_ reading: PackageLayout.Reading, present: Set<String> = []) -> Doctor.Finding {
            Doctor(
                home: home, model: .system,
                probes: .init(systemModel: { nil }, configuredModel: { _, _, _ in nil }, layout: { reading })
            ).package(exists: present.contains)
        }
        let all = finding(
            .declared(layout),
            present: [
                "/Applications/Wisp.app/Contents/MacOS/wisp-tui",
                "/Applications/Wisp.app/Contents/Helpers/Wisp Notifier.app",
            ])
        #expect(
            all.ok
                && all.detail
                    == "/Applications/Wisp.app/Contents/Info.plist declares wisp-tui, Wisp Notifier.app; all present"
        )
        let one = finding(.declared(layout), present: ["/Applications/Wisp.app/Contents/MacOS/wisp-tui"])
        #expect(
            !one.ok
                && one.detail.hasSuffix(
                    "missing: Wisp Notifier.app at /Applications/Wisp.app/Contents/Helpers/Wisp Notifier.app")
        )
        let none = finding(.none)
        #expect(none.ok && none.detail.contains("no declared layout"))
        let broken = finding(.malformed(source: URL(fileURLWithPath: "/x/wisp-layout.json"), reason: "not JSON"))
        #expect(!broken.ok && broken.detail == "/x/wisp-layout.json cannot be read: not JSON")
        let empty = finding(
            .declared(PackageLayout(declaration: .manifest(URL(fileURLWithPath: "/x/m.json")), parts: [:])))
        #expect(empty.ok && empty.detail == "/x/m.json declares no parts")
    }
}

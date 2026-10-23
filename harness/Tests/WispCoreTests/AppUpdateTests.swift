import Foundation
import Synchronization
import Testing

@testable import WispCore

/// `wisp update` and `updates.check` (ADR 0074), without the network: GitHub's answer as data, downloads from files,
/// and the swap between folders under the temporary directory.
@Suite struct AppUpdateTests {
    /// A scratch folder, removed by the test.
    private static func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "wisp-update-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let latest = Data(
        #"""
        {"tag_name": "v0.31.1", "html_url": "https://github.com/pidster/wisp/releases/tag/v0.31.1",
         "assets": [
           {"name": "wisp-0.31.1-arm64.tar.gz", "browser_download_url": "https://example.com/t.tar.gz"},
           {"name": "Wisp-0.31.1.dmg", "browser_download_url": "https://example.com/Wisp-0.31.1.dmg"},
           {"name": "Wisp-0.31.1.dmg.sha256", "browser_download_url": "https://example.com/Wisp-0.31.1.dmg.sha256"}
         ]}
        """#.utf8)

    @Test func versionsCompareAsNumbers() throws {
        let parse = { (text: String) in try #require(AppUpdate.Version(text)) }
        #expect(try parse("v0.31.0").description == "0.31.0")
        #expect(try parse("0.31.0-dev+abc1234 (modified)").description == "0.31.0")
        #expect(try parse("0.9.0") < parse("0.10.0"))
        #expect(try parse("0.31.0") < parse("0.31.1") && !(try parse("1.0.0") < parse("0.99.99")))
        #expect(AppUpdate.Version("0.31") == nil && AppUpdate.Version("x.y.z") == nil && AppUpdate.Version("") == nil)
    }

    @Test func readsTheLatestRelease() throws {
        let release = try AppUpdate.release(fromJSON: Self.latest)
        #expect(release.version == "0.31.1" && release.imageName == "Wisp-0.31.1.dmg")
        #expect(release.checksum?.absoluteString.hasSuffix(".dmg.sha256") == true)
        #expect(release.page?.absoluteString.hasSuffix("v0.31.1") == true)
        // A release with no disk image (0.30.1, or one made with --unsigned) still names its version; only an
        // update needs the image.
        let noImage = try AppUpdate.release(fromJSON: Data(#"{"tag_name": "v0.30.1", "assets": []}"#.utf8))
        #expect(noImage.version == "0.30.1" && noImage.image == nil && noImage.imageName == "Wisp-0.30.1.dmg")
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.release(fromJSON: Data("{}".utf8)) }
        let badTag = Data(#"{"tag_name": "nightly", "assets": []}"#.utf8)
        #expect(throws: AppUpdate.Failure.unreadable("the tag nightly")) { try AppUpdate.release(fromJSON: badTag) }
    }

    @Test func aStateSaysWhenANewerReleaseIsOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppUpdate.State(checkedAt: now, latest: "0.31.1")
        #expect(state.newer(than: "0.31.0") == "0.31.1")
        #expect(state.newer(than: "0.31.1") == nil && state.newer(than: "0.32.0") == nil)
        #expect(AppUpdate.State(checkedAt: now, latest: nil, failure: "x").newer(than: "0.1.0") == nil)
        #expect(AppUpdate.isDue(nil, now: now))
        #expect(!AppUpdate.isDue(state, now: now.addingTimeInterval(3_600)))
        #expect(AppUpdate.isDue(state, now: now.addingTimeInterval(86_400)))
        #expect(AppUpdate.isDue(state, now: now.addingTimeInterval(-60)))
    }

    /// Off, nothing is asked; on, a check is made only when due, kept, and audited.
    @Test func checksOnlyWhenOnAndDue() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let asked = Counter()
        let fetch = {
            asked.add()
            return try AppUpdate.release(fromJSON: Self.latest)
        }
        #expect(
            await AppUpdate.checkIfDue(enabled: false, home: home, source: "chat", audit: audit, now: now, fetch: fetch)
                == nil)
        #expect(asked.value == 0 && AppUpdate.state(home: home) == nil)
        let first = await AppUpdate.checkIfDue(
            enabled: true, home: home, source: "chat", audit: audit, now: now, fetch: fetch)
        #expect(first?.latest == "0.31.1" && asked.value == 1)
        #expect(AppUpdate.state(home: home) == first)
        let again = await AppUpdate.checkIfDue(
            enabled: true, home: home, source: "chat", audit: audit, now: now.addingTimeInterval(60), fetch: fetch)
        #expect(again == first && asked.value == 1)
        let event = try #require(sink.events.last)
        #expect(event.kind == .updateCheck && event.details["source"] == "chat" && event.details["latest"] == "0.31.1")
        // A failed check is kept too, so it is not retried on every prompt.
        let failed = await AppUpdate.check(home: home, source: "doctor", audit: audit, now: now) {
            throw AppUpdate.Failure.network("offline")
        }
        #expect(failed.state.failure == "cannot reach GitHub: offline" && failed.release == nil)
        #expect(sink.events.last?.details["failure"] == "cannot reach GitHub: offline")
    }

    @Test func theDoctorSaysWhatTheCheckFound() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let off = AppUpdate.finding(enabled: false, state: nil, current: "0.31.0")
        #expect(off.ok && off.detail.hasPrefix("updates.check is off"))
        #expect(AppUpdate.finding(enabled: true, state: nil, current: "0.31.0").detail == "not checked yet")
        let newer = AppUpdate.finding(
            enabled: true, state: .init(checkedAt: now, latest: "0.31.1"), current: "0.31.0")
        #expect(newer.ok && newer.detail == "0.31.1 is available (this is 0.31.0): wisp update")
        let current = AppUpdate.finding(
            enabled: true, state: .init(checkedAt: now, latest: "0.31.0"), current: "0.31.0")
        #expect(current.detail.hasPrefix("0.31.0 is the latest (checked 2027-01-15"))
        let failed = AppUpdate.finding(
            enabled: true, state: .init(checkedAt: now, latest: nil, failure: "cannot reach GitHub: offline"),
            current: "0.31.0")
        #expect(failed.ok && failed.detail.hasSuffix("failed: cannot reach GitHub: offline"))
    }

    @Test func readsAChecksumFile() throws {
        let hash = String(repeating: "ab", count: 32)
        #expect(AppUpdate.checksumValue("\(hash)  Wisp-0.31.1.dmg\n") == hash)
        #expect(AppUpdate.checksumValue(hash.uppercased()) == hash)
        #expect(AppUpdate.checksumValue("not a hash  file") == nil && AppUpdate.checksumValue("") == nil)
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "x")
        try Data("abc".utf8).write(to: file)
        #expect(
            try AppUpdate.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The image is saved under its own name when its checksum matches, used again when already there, and refused
    /// when it does not match; downloads here are files.
    @Test func downloadsAndChecksTheImage() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.dmg")
        try Data("an image".utf8).write(to: source)
        let sum = root.appending(path: "source.sha256")
        try Data("\(try AppUpdate.sha256(of: source))  Wisp-0.31.1.dmg\n".utf8).write(to: sum)
        let downloads = root.appending(path: "Downloads")
        var release = AppUpdate.Release(version: "0.31.1", image: source, checksum: sum, page: nil)
        let notes = Notes()
        // A file URL's last component is the image's name; a real release's is Wisp-X.Y.Z.dmg.
        let saved = try await AppUpdate.download(release, into: downloads, note: notes.add)
        #expect(saved.lastPathComponent == "source.dmg" && FileManager.default.fileExists(atPath: saved.path))
        #expect(notes.lines.last?.hasSuffix("its sha256 matches the release's") == true)
        _ = try await AppUpdate.download(release, into: downloads, note: notes.add)
        #expect(notes.lines.last?.hasSuffix("already downloaded") == true)
        let wrong = root.appending(path: "wrong.sha256")
        try Data("\(String(repeating: "0", count: 64))  x\n".utf8).write(to: wrong)
        release.checksum = wrong
        try FileManager.default.removeItem(at: saved)
        await #expect(throws: AppUpdate.Failure.self) {
            try await AppUpdate.download(release, into: downloads, note: notes.add)
        }
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        release.image = nil
        await #expect(throws: AppUpdate.Failure.noImage("0.31.1")) {
            try await AppUpdate.download(release, into: downloads, note: notes.add)
        }
    }

    /// The new app is swapped in whole, the old one gone and nothing left beside it; a copy that fails its check
    /// changes nothing; an unwritable folder is a refusal, not an error.
    @Test func replacesTheAppWhole() throws {
        let root = try Self.scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        func app(_ name: String, marker: String) throws -> URL {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appending(path: "Contents/MacOS/wisp"))
            return url
        }
        func marker(_ app: URL) throws -> String {
            String(decoding: try Data(contentsOf: app.appending(path: "Contents/MacOS/wisp")), as: UTF8.self)
        }
        func leftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        }
        let installed = try app("Wisp.app", marker: "old")
        let new = try app("New.app", marker: "new")
        var checked: [String] = []
        let refused = try AppUpdate.replace(installed, with: new, version: "0.31.1") { app, version in
            checked.append("\(app.lastPathComponent.hasPrefix(".Wisp.app.update-")) \(version)")
        }
        #expect(refused == nil && checked == ["true 0.31.1"])
        #expect(try marker(installed) == "new" && (try leftovers()).isEmpty)

        let newer = try app("Newer.app", marker: "newer")
        #expect(throws: AppUpdate.Failure.notTrusted("no")) {
            try AppUpdate.replace(installed, with: newer, version: "0.31.2") { _, _ in
                throw AppUpdate.Failure.notTrusted("no")
            }
        }
        #expect(try marker(installed) == "new" && (try leftovers()).isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let blocked = try AppUpdate.replace(installed, with: newer, version: "0.31.2") { _, _ in }
        #expect(blocked?.hasSuffix("is not writable by you") == true)
        #expect(try marker(installed) == "new")
    }

    /// The whole update with folders for the image and the app: replaced, refused by the system, and stopped by a
    /// check, each audited, the image unmounted every time.
    @Test func updatesFromAnImageAndAuditsTheOutcome() async throws {
        let root = try Self.scratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Applications").path)
            try? FileManager.default.removeItem(at: root)
        }
        func app(at url: URL, marker: String) throws {
            try FileManager.default.createDirectory(
                at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appending(path: "Contents/MacOS/wisp"))
        }
        let installed = root.appending(path: "Applications/Wisp.app")
        try app(at: installed, marker: "old")
        let mounted = root.appending(path: "mounted")
        try app(at: mounted.appending(path: "Wisp.app"), marker: "new")
        let image = root.appending(path: "Wisp-0.31.1.dmg")
        try Data("image".utf8).write(to: image)
        let sum = root.appending(path: "Wisp-0.31.1.dmg.sha256")
        try Data("\(try AppUpdate.sha256(of: image))  Wisp-0.31.1.dmg\n".utf8).write(to: sum)
        let release = AppUpdate.Release(version: "0.31.1", image: image, checksum: sum, page: nil)
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        let unmounted = Counter()
        func steps(
            holding folder: URL = mounted, verify: @escaping (URL, String) throws -> Void = { _, _ in }
        )
            -> AppUpdate.Steps
        {
            AppUpdate.Steps(mount: { _ in folder }, unmount: { _ in unmounted.add() }, verify: verify)
        }
        let downloads = root.appending(path: "Downloads")
        let replaced = try await AppUpdate.update(
            installed, to: release, downloads: downloads, audit: audit, source: "cli", note: { _ in },
            steps: steps())
        #expect(replaced == .replaced(app: installed, from: WispVersion.current, to: "0.31.1"))
        let marker = {
            String(decoding: try Data(contentsOf: installed.appending(path: "Contents/MacOS/wisp")), as: UTF8.self)
        }
        #expect(try marker() == "new" && unmounted.value == 1)
        #expect(sink.events.last?.details["outcome"] == "replaced" && sink.events.last?.kind == .updateInstall)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: root.appending(path: "Applications").path)
        let blocked = try await AppUpdate.update(
            installed, to: release, downloads: downloads, audit: audit, source: "finder", note: { _ in },
            steps: steps())
        guard case .blocked(let reason, let kept) = blocked else {
            Issue.record("not blocked: \(blocked)")
            return
        }
        #expect(reason.hasSuffix("is not writable by you") && kept.lastPathComponent == "Wisp-0.31.1.dmg")
        #expect(sink.events.last?.details["outcome"] == "blocked" && sink.events.last?.details["source"] == "finder")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.appending(path: "Applications").path)

        await #expect(throws: AppUpdate.Failure.image("it holds no Wisp.app")) {
            try await AppUpdate.update(
                installed, to: release, downloads: downloads, audit: audit, source: "cli", note: { _ in },
                steps: steps(holding: root.appending(path: "Downloads")))
        }
        await #expect(throws: AppUpdate.Failure.notTrusted("no")) {
            try await AppUpdate.update(
                installed, to: release, downloads: downloads, audit: audit, source: "cli", note: { _ in },
                steps: steps { _, _ in throw AppUpdate.Failure.notTrusted("no") })
        }
        #expect(sink.events.last?.details["outcome"] == "failed" && sink.events.last?.details["reason"] != .null)
        #expect(try marker() == "new" && unmounted.value == 4)
    }

    /// The real check refuses an app that is not wisp's, not the release's version, or not signed; the real mount
    /// refuses a file that is not a disk image.
    @Test func theRealChecksRefuseWhatIsNotARelease() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        func app(identifier: String, version: String) throws -> URL {
            let url = root.appending(path: "\(UUID().uuidString).app")
            try FileManager.default.createDirectory(
                at: url.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "wisp",
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appending(path: "Contents/Info.plist"))
            try Data("#!/bin/sh\n".utf8).write(to: url.appending(path: "Contents/MacOS/wisp"))
            return url
        }
        func reason(_ app: URL, _ version: String) -> String? {
            do {
                try AppUpdate.verify(app: app, version: version)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(
            reason(try app(identifier: "com.example.other", version: "0.31.1"), "0.31.1")?.contains("com.example.other")
                == true)
        #expect(
            reason(try app(identifier: AppUpdate.bundleIdentifier, version: "0.31.0"), "0.31.1")?.contains(
                "version 0.31.0") == true)
        let unsigned = reason(try app(identifier: AppUpdate.bundleIdentifier, version: "0.31.1"), "0.31.1")
        #expect(unsigned?.hasPrefix("the app in the disk image was refused") == true, "\(unsigned ?? "passed")")
        let notAnImage = root.appending(path: "x.dmg")
        try Data("not an image".utf8).write(to: notAnImage)
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.attach(notAnImage) }
        #expect(AppUpdate.run("/nonexistent/tool", []).status == -1)
        let folder = root.appending(path: "not-mounted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        AppUpdate.detach(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// The request a check makes, answered in-process: GitHub's API, the user agent `wisp`, and its answer read; an
    /// error status is a network failure. Nothing reaches the network.
    @Test func asksGitHubForTheLatestRelease() async throws {
        #expect(URLProtocol.registerClass(GitHubStub.self))
        defer { URLProtocol.unregisterClass(GitHubStub.self) }
        let release = try await AppUpdate.fetchLatest()
        #expect(release.version == "0.31.1")
        let seen = try #require(GitHubStub.seen.withLock { $0 })
        #expect(seen.url == AppUpdate.latestRelease && seen.agent == "wisp")
        #expect(AppInstall.volumeIsReadOnly(FileManager.default.temporaryDirectory) == false)
        GitHubStub.status.withLock { $0 = 503 }
        defer { GitHubStub.status.withLock { $0 = 200 } }
        await #expect(throws: AppUpdate.Failure.network("HTTP 503")) { try await AppUpdate.fetchLatest() }
        // A checksum that cannot be fetched stops the download before anything is saved.
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = AppUpdate.Release(
            version: "0.31.1", image: root.appending(path: "a.dmg"), checksum: root.appending(path: "none.sha256"),
            page: nil)
        await #expect(throws: AppUpdate.Failure.self) {
            try await AppUpdate.download(missing, into: root, note: { _ in })
        }
    }

    /// Each failure says what stopped, as the person reads it; an error that is not wisp's is a network failure.
    @Test func failuresSayWhatStopped() async throws {
        let said: [AppUpdate.Failure: String] = [
            .network("offline"): "cannot reach GitHub: offline",
            .unreadable("not a release"): "GitHub's answer could not be read: not a release",
            .noImage("0.30.1"): "the release 0.30.1 has no disk image",
            .checksum(expected: "a", found: "b"): "the disk image's sha256 is b, not the published a; it was not used",
            .image("it holds no Wisp.app"): "the disk image: it holds no Wisp.app",
            .notTrusted("x"): "the app in the disk image was refused: x",
            .refused("move it"): "move it",
            .io("cannot save"): "cannot save",
        ]
        for (failure, text) in said { #expect("\(failure)" == text) }
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await AppUpdate.check(home: Home(root: root), source: "cli", audit: nil) {
            throw URLError(.notConnectedToInternet)
        }
        #expect(result.failure.map { "\($0)" }?.hasPrefix("cannot reach GitHub:") == true)
    }

    /// What goes wrong on the way is said, and nothing is left behind: a new app that is not there, an installed app
    /// that is not there to swap, a file that cannot be read, and a checksum file that holds no checksum.
    @Test func stepsThatFailSayWhy() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appending(path: "Wisp.app")
        let new = root.appending(path: "New.app")
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        func failure(_ body: () throws -> String?) -> String {
            do {
                return "returned \(try body() ?? "nil")"
            } catch {
                return "\(error)"
            }
        }
        #expect(
            failure {
                try AppUpdate.replace(installed, with: root.appending(path: "Gone.app"), version: "1") { _, _ in }
            }
            .hasPrefix("cannot copy the new app beside the old"))
        #expect(
            failure { try AppUpdate.replace(installed, with: new, version: "1") { _, _ in } }
                .hasPrefix("cannot put the new app in place"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["New.app"])
        #expect(AppUpdate.isRefusal(EPERM) && AppUpdate.isRefusal(EROFS) && !AppUpdate.isRefusal(ENOENT))
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.sha256(of: root.appending(path: "none")) }
        let image = root.appending(path: "a.dmg")
        try Data("image".utf8).write(to: image)
        let sum = root.appending(path: "a.sha256")
        try Data("not a checksum\n".utf8).write(to: sum)
        let release = AppUpdate.Release(version: "0.31.1", image: image, checksum: sum, page: nil)
        await #expect(throws: AppUpdate.Failure.unreadable("the sha256 file")) {
            try await AppUpdate.download(release, into: root.appending(path: "Downloads"), note: { _ in })
        }
        // Outside an app, opening the app bundle does nothing.
        PackageLayout.openAppBundle()
        #expect(AppInstall.Source.translocated(installed).refusal?.contains("temporary copy") == true)
        #expect(AppInstall.Source.elsewhere.refusal?.contains("not in Wisp.app") == true)
    }

    @Test func onlyTheAppUpdatesItself() throws {
        let app = URL(filePath: "/Applications/Wisp.app")
        #expect(try AppUpdate.app(of: .app(app)) == app)
        #expect(
            throws: AppUpdate.Failure.refused(
                "this wisp was installed by Homebrew; update it with: brew upgrade pidster/tap/wisp")
        ) {
            try AppUpdate.app(of: .homebrew)
        }
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.app(of: .elsewhere) }
        #expect(throws: AppUpdate.Failure.self) { try AppUpdate.app(of: .diskImage(app)) }
    }

    @Test func theDefaultPolicyRefusesTheModelAnUpdate() {
        let policy = CommandPolicy()
        #expect(policy.check("wisp update") != .allowed)
        #expect(policy.check("/Applications/Wisp.app/Contents/MacOS/wisp update --check") != .allowed)
        #expect(policy.check("wisp doctor") == .allowed)
    }
}

/// A count a `@Sendable` closure adds to.
private final class Counter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    func add() { storage.withLock { $0 += 1 } }
}

/// Lines a `@Sendable` note closure collects.
private final class Notes: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    @Sendable func add(_ line: String) { storage.withLock { $0.append(line) } }
}

/// Answers GitHub's API in-process with `AppUpdateTests`' release, and records the request.
private final class GitHubStub: URLProtocol {
    /// The last request's address and user agent.
    static let seen = Mutex<(url: String, agent: String?)?>(nil)
    /// The status it answers with.
    static let status = Mutex(200)

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock {
            $0 = (request.url?.absoluteString ?? "", request.value(forHTTPHeaderField: "User-Agent"))
        }
        let body = Data(
            #"{"tag_name": "v0.31.1", "assets": [{"name": "Wisp-0.31.1.dmg", "browser_download_url": "https://example.com/a"}]}"#
                .utf8)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: Self.status.withLock { $0 }, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

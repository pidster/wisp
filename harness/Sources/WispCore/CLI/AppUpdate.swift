import CryptoKit
import Darwin
import Foundation
import Security

/// `wisp update`: the latest release from GitHub, its disk image downloaded to `~/Downloads` and checked, and
/// `Wisp.app` replaced whole with the one inside; and `updates.check`, the opt-in daily check that says when a newer
/// version is out ([ADR 0074](../../../../docs/decisions/0074-wisp-update.md)). Nothing here reaches the network
/// unless the person runs `wisp update` or turned the check on.
public enum AppUpdate {
    /// The one request a check makes: GitHub's latest release of wisp.
    static let latestRelease = "https://api.github.com/repos/pidster/wisp/releases/latest"
    /// The team whose Developer ID signs a release (ADR 0071).
    public static let teamIdentifier = "LFQFWCB8Y3"
    /// `Wisp.app`'s bundle identifier.
    public static let bundleIdentifier = "com.pidster.wisp"
    /// The code requirement a downloaded app must meet: a Developer ID of wisp's team, notarised.
    static let requirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamIdentifier)" and notarized"#
    /// How long a check's answer stands before the next check: a day.
    public static let checkInterval: TimeInterval = 86_400
    /// The state file's name in wisp's home.
    static let stateName = "update.json"

    /// A release version, `major.minor.patch`; anything after a `-` or `+` is ignored, as is a leading `v`.
    public struct Version: Comparable, CustomStringConvertible, Sendable {
        /// The three numbers.
        public var parts: [Int]

        /// Parses `text`, or nil when it is not three numbers.
        ///
        /// - Parameter text: `0.31.0`, `v0.31.0`, or `0.31.0-dev+abc1234`.
        public init?(_ text: String) {
            var core = Substring(text.trimmingCharacters(in: .whitespaces))
            if core.hasPrefix("v") { core = core.dropFirst() }
            core = core.prefix { $0 != "-" && $0 != "+" && $0 != " " }
            let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 != nil && $0 ?? -1 >= 0 }) else { return nil }
            self.parts = parts.compactMap { $0 }
        }

        /// The version as written, `0.31.0`.
        public var description: String { parts.map(String.init).joined(separator: ".") }

        /// Whether `lhs` comes before `rhs`.
        public static func < (lhs: Version, rhs: Version) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
    }

    /// The latest release, as GitHub describes it.
    public struct Release: Codable, Equatable, Sendable {
        /// Its version.
        public var version: String
        /// The disk image's download, or nil when the release has none (one made with `--unsigned`, or before 0.31.0).
        public var image: URL?
        /// The image's `sha256` file's download, or nil with no image.
        public var checksum: URL?
        /// The release's page.
        public var page: URL?

        /// The image's file name, `Wisp-X.Y.Z.dmg`.
        public var imageName: String { image?.lastPathComponent ?? "Wisp-\(version).dmg" }
    }

    /// Why a check or an update stopped.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// GitHub could not be reached, or answered with an error.
        case network(String)
        /// GitHub's answer was not a release wisp can read.
        case unreadable(String)
        /// The release has no disk image.
        case noImage(String)
        /// The image's checksum is not the published one.
        case checksum(expected: String, found: String)
        /// The image would not mount, or holds no `Wisp.app`.
        case image(String)
        /// The app in the image is not one wisp installs: the wrong bundle, version, or signature.
        case notTrusted(String)
        /// Where `wisp update` cannot run, and what to do instead.
        case refused(String)
        /// A file could not be read or written.
        case io(String)

        /// The failure as said to the person.
        public var description: String {
            switch self {
            case .network(let message): "cannot reach GitHub: \(message)"
            case .unreadable(let message): "GitHub's answer could not be read: \(message)"
            case .noImage(let version): "the release \(version) has no disk image"
            case .checksum(let expected, let found):
                "the disk image's sha256 is \(found), not the published \(expected); it was not used"
            case .image(let message): "the disk image: \(message)"
            case .notTrusted(let message): "the app in the disk image was refused: \(message)"
            case .refused(let message): message
            case .io(let message): message
            }
        }
    }

    // MARK: - The check

    /// Reads GitHub's description of the latest release.
    ///
    /// - Parameter data: The body of `releases/latest`.
    /// - Returns: The release.
    /// - Throws: `Failure.unreadable`.
    static func release(fromJSON data: Data) throws -> Release {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        struct Body: Decodable {
            let tagName: String
            let htmlURL: URL?
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw Failure.unreadable("not a release")
        }
        guard let version = Version(body.tagName) else { throw Failure.unreadable("the tag \(body.tagName)") }
        let name = "Wisp-\(version).dmg"
        let image = body.assets.first { $0.name == name }?.browserDownloadURL
        let checksum = body.assets.first { $0.name == name + ".sha256" }?.browserDownloadURL
        return Release(
            version: "\(version)", image: checksum == nil ? nil : image, checksum: image == nil ? nil : checksum,
            page: body.htmlURL)
    }

    /// Asks GitHub for the latest release: one request, with the user agent `wisp` and nothing about the person.
    ///
    /// - Returns: The release.
    /// - Throws: `Failure`.
    public static func fetchLatest() async throws -> Release {
        guard let url = URL(string: latestRelease) else { throw Failure.network("no address") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("wisp", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw Failure.network("HTTP \(status)")
        }
        return try release(fromJSON: data)
    }

    /// What the last check found, kept in `~/.wisp/update.json`.
    public struct State: Codable, Equatable, Sendable {
        /// When GitHub was last asked.
        public var checkedAt: Date
        /// The latest version it named, or nil when the check failed.
        public var latest: String?
        /// Why the check failed, or nil.
        public var failure: String?

        /// Creates a state.
        public init(checkedAt: Date, latest: String?, failure: String? = nil) {
            self.checkedAt = checkedAt
            self.latest = latest
            self.failure = failure
        }

        /// The latest version when it is newer than `current`, else nil.
        ///
        /// - Parameter current: The running version.
        /// - Returns: The newer version.
        public func newer(than current: String) -> String? {
            guard let latest, let found = Version(latest), let running = Version(current), running < found else {
                return nil
            }
            return "\(found)"
        }
    }

    /// The last check's state, or nil when there was none or it cannot be read.
    ///
    /// - Parameter home: wisp's home.
    /// - Returns: The state.
    public static func state(home: Home) -> State? {
        guard let data = try? Data(contentsOf: home.root.appending(path: stateName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Writes the check's state; a failure to write only costs the next check sooner.
    ///
    /// - Parameters:
    ///   - state: What the check found.
    ///   - home: wisp's home.
    static func save(_ state: State, home: Home) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: home.root, withIntermediateDirectories: true)
        try? data.write(to: home.root.appending(path: stateName), options: .atomic)
    }

    /// Whether a check is due: none yet, or the last one a day or more ago (or in the future, after a clock change).
    ///
    /// - Parameters:
    ///   - state: The last check's state.
    ///   - now: The time.
    /// - Returns: True when GitHub may be asked again.
    public static func isDue(_ state: State?, now: Date) -> Bool {
        guard let state else { return true }
        let age = now.timeIntervalSince(state.checkedAt)
        return age >= checkInterval || age < 0
    }

    /// Checks when `updates.check` is on and a check is due, keeps what it found, and records it.
    ///
    /// - Parameters:
    ///   - enabled: `updates.check`.
    ///   - home: wisp's home.
    ///   - source: Who asked (`chat`, `doctor`, `finder`), for the audit.
    ///   - audit: Where the `update.check` event goes, or nil.
    ///   - now: The time.
    ///   - fetch: Asks GitHub.
    /// - Returns: The state after the check, or the last one when none was due; nil when off.
    @discardableResult
    public static func checkIfDue(
        enabled: Bool, home: Home, source: String, audit: AuditLog?, now: Date = Date(),
        fetch: () async throws -> Release = { try await fetchLatest() }
    ) async -> State? {
        guard enabled else { return nil }
        let last = state(home: home)
        guard isDue(last, now: now) else { return last }
        return await check(home: home, source: source, audit: audit, now: now, fetch: fetch).state
    }

    /// Asks GitHub now, keeps what it found, and records it.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - source: Who asked (`cli`, `chat`, `doctor`, `finder`), for the audit.
    ///   - audit: Where the `update.check` event goes, or nil.
    ///   - now: The time.
    ///   - fetch: Asks GitHub.
    /// - Returns: The state, and the release when the check succeeded.
    public static func check(
        home: Home, source: String, audit: AuditLog?, now: Date = Date(),
        fetch: () async throws -> Release = { try await fetchLatest() }
    ) async -> (state: State, release: Release?, failure: Failure?) {
        let result: (State, Release?, Failure?)
        do {
            let release = try await fetch()
            result = (State(checkedAt: now, latest: release.version), release, nil)
        } catch let failure as Failure {
            result = (State(checkedAt: now, latest: nil, failure: "\(failure)"), nil, failure)
        } catch {
            let failure = Failure.network(error.localizedDescription)
            result = (State(checkedAt: now, latest: nil, failure: "\(failure)"), nil, failure)
        }
        save(result.0, home: home)
        audit?.record(
            .updateCheck,
            details: [
                "source": .string(source), "current": .string(WispVersion.current),
                "latest": result.0.latest.map { .string($0) } ?? .null,
                "newer": .bool(result.0.newer(than: WispVersion.current) != nil),
                "failure": result.2.map { .string("\($0)") } ?? .null,
            ])
        return result
    }

    /// The doctor's `update` line.
    ///
    /// - Parameters:
    ///   - enabled: `updates.check`.
    ///   - state: The last check's state.
    ///   - current: The running version.
    /// - Returns: The finding: always passing, since an update is the person's to make.
    public static func finding(enabled: Bool, state: State?, current: String = WispVersion.current) -> Doctor.Finding {
        guard enabled else {
            return .init(
                name: "update", ok: true,
                detail: "updates.check is off; wisp update --check asks GitHub for the latest release")
        }
        guard let state else { return .init(name: "update", ok: true, detail: "not checked yet") }
        let when = state.checkedAt.formatted(.iso8601.year().month().day())
        if let failure = state.failure {
            return .init(name: "update", ok: true, detail: "the check on \(when) failed: \(failure)")
        }
        if let newer = state.newer(than: current) {
            return .init(name: "update", ok: true, detail: "\(newer) is available (this is \(current)): wisp update")
        }
        return .init(name: "update", ok: true, detail: "\(current) is the latest (checked \(when))")
    }

    // MARK: - The download

    /// The hash in a `shasum -a 256` line: its first word, when it is 64 hexadecimal digits.
    ///
    /// - Parameter text: The `.sha256` file.
    /// - Returns: The hash, lower case.
    static func checksumValue(_ text: String) -> String? {
        guard let word = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first,
            word.count == 64, word.allSatisfy(\.isHexDigit)
        else { return nil }
        return word.lowercased()
    }

    /// The `sha256` of a file, read in pieces.
    ///
    /// - Parameter url: The file.
    /// - Returns: The hash, lower case.
    /// - Throws: `Failure.io` when it cannot be read.
    static func sha256(of url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw Failure.io("cannot read \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the release's image into `folder`, or uses the one already there when it matches the published
    /// checksum, and checks it.
    ///
    /// - Parameters:
    ///   - release: The release.
    ///   - folder: `~/Downloads`.
    ///   - note: Says what is happening.
    /// - Returns: The checked image.
    /// - Throws: `Failure`.
    public static func download(
        _ release: Release, into folder: URL, note: @Sendable (String) -> Void
    ) async throws -> URL {
        guard let image = release.image, let checksum = release.checksum else {
            throw Failure.noImage(release.version)
        }
        let expected: String
        do {
            let (data, _) = try await URLSession.shared.data(from: checksum)
            guard let value = checksumValue(String(decoding: data, as: UTF8.self)) else {
                throw Failure.unreadable("the sha256 file")
            }
            expected = value
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let target = folder.appending(path: release.imageName)
        if FileManager.default.fileExists(atPath: target.path), (try? sha256(of: target)) == expected {
            note("using \(target.path), already downloaded")
            return target
        }
        note("downloading \(image.absoluteString)")
        let temporary: URL
        do {
            (temporary, _) = try await URLSession.shared.download(from: image)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let found = try sha256(of: temporary)
        guard found == expected else {
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.checksum(expected: expected, found: found)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            throw Failure.io("cannot save \(target.path): \(error.localizedDescription)")
        }
        note("saved \(target.path); its sha256 matches the release's")
        return target
    }

    // MARK: - Checking the app

    /// Checks that `app` is the `Wisp.app` of `version`, signed by wisp's team and notarised, its whole bundle intact.
    ///
    /// - Parameters:
    ///   - app: The app.
    ///   - version: The version the release names.
    /// - Throws: `Failure.notTrusted` saying what is wrong.
    public static func verify(app: URL, version: String) throws {
        let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else {
            throw Failure.notTrusted("its bundle identifier is \(identifier ?? "missing"), not \(bundleIdentifier)")
        }
        let shown = info["CFBundleShortVersionString"] as? String
        guard shown == version else {
            throw Failure.notTrusted("it is version \(shown ?? "unknown"), not \(version)")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.notTrusted("its signature cannot be read")
        }
        var required: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess else {
            throw Failure.notTrusted("the signing requirement does not compile")
        }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, required, &error) == errSecSuccess else {
            let status = error.map { OSStatus(truncatingIfNeeded: CFErrorGetCode($0.takeRetainedValue())) }
            let reason = status.flatMap { SecCopyErrorMessageString($0, nil) as String? } ?? "unknown"
            throw Failure.notTrusted("it is not signed by \(teamIdentifier) and notarised, or was changed: \(reason)")
        }
    }

    // MARK: - Mounting

    /// Runs a tool and returns its status and output, standard error included.
    ///
    /// - Parameters:
    ///   - tool: The executable.
    ///   - arguments: Its arguments.
    /// - Returns: The exit status and output.
    public static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// Mounts `image` read-only, out of the Finder's sight, at a new folder.
    ///
    /// - Parameter image: The disk image.
    /// - Returns: The mount point.
    /// - Throws: `Failure.image`.
    static func attach(_ image: URL) throws -> URL {
        let point = FileManager.default.temporaryDirectory.appending(path: "wisp-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
        let result = run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet", "-mountpoint", point.path, image.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: point)
            throw Failure.image("hdiutil attach failed: \(result.output)")
        }
        return point
    }

    /// Unmounts a mount point and removes its folder.
    ///
    /// - Parameter point: The mount point.
    static func detach(_ point: URL) {
        if run("/usr/bin/hdiutil", ["detach", "-quiet", point.path]).status != 0 {
            _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", point.path])
        }
        try? FileManager.default.removeItem(at: point)
    }

    // MARK: - Replacing the app

    /// What an update did.
    public enum Outcome: Equatable, Sendable {
        /// `Wisp.app` now holds the new version.
        case replaced(app: URL, from: String, to: String)
        /// The app could not be replaced: why, and the checked image the person can drag it from.
        case blocked(reason: String, image: URL)
    }

    /// Whether an error number means the system refused the change, rather than something going wrong.
    static func isRefusal(_ code: Int32) -> Bool { code == EPERM || code == EACCES || code == EROFS }

    /// Replaces `app` with `new`: copies it beside `app` under a hidden name, checks the copy, swaps the two in one
    /// step, and only then removes the old one.
    ///
    /// - Parameters:
    ///   - app: The installed `Wisp.app`.
    ///   - new: The app in the mounted image.
    ///   - version: The new version.
    ///   - verify: Checks the copy (`verify(app:version:)`).
    /// - Returns: Nil when replaced, else why the system refused.
    /// - Throws: `Failure` for anything but a refusal.
    static func replace(
        _ app: URL, with new: URL, version: String, verify: (URL, String) throws -> Void = verify(app:version:)
    ) throws -> String? {
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return "\(folder.path) is not writable by you"
        }
        let staged = folder.appending(path: ".\(app.lastPathComponent).update-\(UUID().uuidString)")
        let copied = run("/usr/bin/ditto", [new.path, staged.path])
        guard copied.status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            if copied.output.contains("Operation not permitted") || copied.output.contains("Permission denied") {
                return "macOS refused the copy into \(folder.path): \(copied.output)"
            }
            throw Failure.io("cannot copy the new app beside the old: \(copied.output)")
        }
        do {
            try verify(staged, version)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        guard renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staged)
            let reason = String(cString: strerror(code))
            if isRefusal(code) { return "macOS refused to replace \(app.path): \(reason)" }
            throw Failure.io("cannot put the new app in place: \(reason)")
        }
        // The old app is now at the staged name; the new one is in place whether or not it can be removed.
        try? FileManager.default.removeItem(at: staged)
        return nil
    }

    /// Updates `app` to `release`: downloads and checks the image, checks its app, and replaces `app` with it; when
    /// the system refuses the replacement, leaves `app` as it was and returns the checked image for the person.
    ///
    /// - Parameters:
    ///   - app: The installed `Wisp.app`.
    ///   - release: The newer release.
    ///   - downloads: `~/Downloads`.
    ///   - audit: Where the `update.install` event goes, or nil.
    ///   - source: Who asked (`cli`, `finder`), for the audit.
    ///   - note: Says what is happening.
    /// - Returns: What was done.
    /// - Throws: `Failure` when the update stopped before anything was changed.
    public static func update(
        _ app: URL, to release: Release, downloads: URL, audit: AuditLog?, source: String,
        note: @Sendable (String) -> Void
    ) async throws -> Outcome {
        func record(_ outcome: String, reason: String?, image: URL?) {
            audit?.record(
                .updateInstall,
                details: [
                    "source": .string(source), "app": .string(app.path), "from": .string(WispVersion.current),
                    "to": .string(release.version), "outcome": .string(outcome),
                    "reason": reason.map { .string($0) } ?? .null, "image": image.map { .string($0.path) } ?? .null,
                ])
        }
        var image: URL?
        do {
            let downloaded = try await download(release, into: downloads, note: note)
            image = downloaded
            let point = try attach(downloaded)
            defer { detach(point) }
            let new = point.appending(path: "Wisp.app")
            guard FileManager.default.fileExists(atPath: new.path) else { throw Failure.image("it holds no Wisp.app") }
            try verify(app: new, version: release.version)
            note("checked: Wisp.app \(release.version), signed by \(teamIdentifier) and notarised")
            if let refusal = try replace(app, with: new, version: release.version) {
                record("blocked", reason: refusal, image: downloaded)
                return .blocked(reason: refusal, image: downloaded)
            }
        } catch {
            record("failed", reason: "\(error)", image: image)
            throw error
        }
        record("replaced", reason: nil, image: image)
        return .replaced(app: app, from: WispVersion.current, to: release.version)
    }

    /// Where `wisp update` may run, or what to do instead, for the install the running `wisp` came from.
    ///
    /// - Parameter source: The install.
    /// - Returns: The app to replace.
    /// - Throws: `Failure.refused`.
    public static func app(of source: AppInstall.Source) throws -> URL {
        switch source {
        case .app(let app): return app
        case .homebrew:
            throw Failure.refused("this wisp was installed by Homebrew; update it with: brew upgrade pidster/tap/wisp")
        case .elsewhere:
            throw Failure.refused(
                "this wisp is not in Wisp.app, so it cannot update itself; a build is updated from source")
        case .diskImage, .translocated:
            throw Failure.refused(source.refusal ?? "")
        }
    }
}

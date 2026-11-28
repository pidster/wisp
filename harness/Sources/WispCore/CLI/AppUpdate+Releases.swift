import Foundation

extension AppUpdate {
    /// The request a listing makes: GitHub's recent releases of wisp, newest first.
    static let recentReleases = "https://api.github.com/repos/pidster/wisp/releases?per_page=10"
    /// How many releases a listing shows.
    public static let listed = 5

    /// A published release with what its page says: the notes and the day.
    public struct Published: Equatable, Sendable {
        /// The release.
        public var release: Release
        /// Its notes, the changelog section the release script publishes; empty when there are none.
        public var notes: String
        /// When it was published, when GitHub says.
        public var date: Date?

        /// Creates a published release.
        public init(release: Release, notes: String = "", date: Date? = nil) {
            self.release = release
            self.notes = notes
            self.date = date
        }

        /// The day it was published, `2026-11-20`, or an empty string.
        public var day: String { date?.formatted(.iso8601.year().month().day()) ?? "" }
    }

    /// Reads GitHub's list of releases: drafts and pre-releases left out, newest version first, at most `count`.
    ///
    /// - Parameters:
    ///   - data: The body of `releases`.
    ///   - count: How many to keep.
    /// - Returns: The releases; a tag that is not a version is skipped.
    /// - Throws: `Failure.unreadable` when the body is not a list of releases.
    static func releases(fromJSON data: Data, count: Int = listed) throws -> [Published] {
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
            let body: String?
            let publishedAt: String?
            let draft: Bool?
            let prerelease: Bool?

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case assets, body, draft, prerelease
                case publishedAt = "published_at"
            }
        }
        let bodies: [Body]
        do {
            bodies = try JSONDecoder().decode([Body].self, from: data)
        } catch {
            throw Failure.unreadable("not a list of releases")
        }
        let published = bodies.filter { $0.draft != true && $0.prerelease != true }.compactMap { body in
            (try? release(
                tag: body.tagName, page: body.htmlURL, assets: body.assets.map { ($0.name, $0.browserDownloadURL) }))
                .map { release in
                    Published(
                        release: release, notes: (body.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                        date: body.publishedAt.flatMap { try? Date($0, strategy: .iso8601) })
                }
        }
        return Array(
            published.sorted { lhs, rhs in
                guard let left = Version(lhs.release.version), let right = Version(rhs.release.version) else {
                    return false
                }
                return right < left
            }
            .prefix(count))
    }

    /// Asks GitHub for the recent releases: one request, with the user agent `wisp` and nothing about the person.
    ///
    /// - Returns: The releases, newest first.
    /// - Throws: `Failure`.
    public static func fetchRecent() async throws -> [Published] {
        guard let url = URL(string: recentReleases) else { throw Failure.network("no address") }
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
        return try releases(fromJSON: data)
    }

    /// Asks GitHub for the recent releases now, and keeps and records the newest as a check does (`check`), so the
    /// listing and `updates.check` agree on what is latest.
    ///
    /// - Parameters:
    ///   - home: wisp's home.
    ///   - source: Who asked (`cli`, `finder`), for the audit.
    ///   - audit: Where the `update.check` event goes, or nil.
    ///   - now: The time.
    ///   - fetch: Asks GitHub.
    /// - Returns: The state, the releases (empty when the check failed), and the failure.
    public static func checkListing(
        home: Home, source: String, audit: AuditLog?, now: Date = Date(),
        fetch: () async throws -> [Published] = { try await fetchRecent() }
    ) async -> (state: State, releases: [Published], failure: Failure?) {
        var releases: [Published] = []
        let result = await check(home: home, source: source, audit: audit, now: now) {
            releases = try await fetch()
            guard let newest = releases.first else { throw Failure.unreadable("no releases") }
            return newest.release
        }
        return (result.state, result.failure == nil ? releases : [], result.failure)
    }

    /// What a release's notes say in a few lines: the changelog's headings and bullets as plain text, a bullet's
    /// wrapped lines joined into one, blank lines dropped, at most `limit` lines, with `…` when there is more.
    ///
    /// - Parameters:
    ///   - notes: The notes, in Markdown.
    ///   - limit: How many lines to keep.
    /// - Returns: The lines.
    public static func summary(of notes: String, limit: Int = 6) -> [String] {
        var lines: [String] = []
        var joining = false
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if text.isEmpty {
                joining = false
                continue
            }
            if text.hasPrefix("#") {
                while text.hasPrefix("#") { text.removeFirst() }
                lines.append(text.trimmingCharacters(in: .whitespaces))
                joining = false
            } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
                lines.append("• " + text.dropFirst(2))
                joining = true
            } else if joining, let last = lines.popLast() {
                lines.append(last + " " + text)
            } else {
                lines.append(text)
                joining = true
            }
        }
        return lines.count > limit ? Array(lines.prefix(limit)) + ["…"] : lines
    }

    /// What can be done about the newest of `releases` from this install, in a sentence for the person.
    ///
    /// - Parameters:
    ///   - releases: The releases, newest first.
    ///   - current: The running version.
    ///   - source: The install the running `wisp` came from.
    ///   - command: How the person updates from here: `wisp update` in a terminal, `Update` in the window.
    /// - Returns: The sentence.
    public static func advice(
        _ releases: [Published], current: String, source: AppInstall.Source, command: String
    ) -> String {
        guard let newest = releases.first else { return "GitHub lists no releases of wisp" }
        guard let running = Version(current), let found = Version(newest.release.version), running < found else {
            return "This is the latest release, \(current)."
        }
        let head = "Wisp \(found) is newer than this one, \(current)."
        do {
            _ = try app(of: source)
        } catch {
            return "\(head) \(error)."
        }
        guard newest.release.image != nil else { return "\(head) It has no disk image, so it cannot be installed." }
        return "\(head) \(command) installs it; only the newest can be installed, and older ones are for reading."
    }

    /// The terminal's listing (`wisp update --releases`): each release with its day, which one is running, and its
    /// notes in a few lines, then what can be done.
    ///
    /// - Parameters:
    ///   - releases: The releases, newest first.
    ///   - current: The running version.
    ///   - source: The install the running `wisp` came from.
    /// - Returns: The lines.
    public static func listing(_ releases: [Published], current: String, source: AppInstall.Source) -> [String] {
        let running = Version(current)
        var lines: [String] = []
        for (index, published) in releases.enumerated() {
            let version = Version(published.release.version)
            var marks: [String] = []
            if index == 0 { marks.append("newest") }
            if let version, let running, version.parts == running.parts { marks.append("this one") }
            let day = published.day.isEmpty ? "" : "  \(published.day)"
            let mark = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
            lines.append("Wisp \(published.release.version)\(day)\(mark)")
            lines += summary(of: published.notes).map { "    \($0)" }
            if let page = published.release.page { lines.append("    \(page.absoluteString)") }
            lines.append("")
        }
        lines.append(advice(releases, current: current, source: source, command: "wisp update"))
        return lines
    }
}

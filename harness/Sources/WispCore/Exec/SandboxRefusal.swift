import Foundation

/// Whether the sandbox refused a command that failed with `Operation not permitted`: checked against the writable
/// roots where its error output names a path, a guess where it names none
/// ([ADR 0054](../../../../docs/decisions/0054-the-sandboxs-refusals-checked.md)).
///
/// Seatbelt is passive: a refused operation fails with `EPERM` and the kernel says nothing (probed on macOS 27 on
/// 2026-10-04: no `deny` record for a `sandbox-exec` profile, with `(debug deny)` or `(deny default)`; `(with report)`
/// is refused on a deny rule; `(with send-signal …)` delivered nothing). What is left is the command's own error
/// output. A write the profile refuses names a path outside every writable root; one inside them that fails with
/// `EPERM` is something else (file flags, System Integrity Protection, a file another process holds). Network and
/// process refusals name no path, so for them it stays a guess, marked as one.
public enum SandboxRefusal: Equatable, Sendable {
    /// A path the error names is outside every writable root: the sandbox refused writing to it. Checked.
    case refused(paths: [String])
    /// Every path the error names is inside the writable roots: not the sandbox. Checked.
    case notTheSandbox(paths: [String])
    /// `Operation not permitted` with no path to check: the sandbox may have refused it. A guess.
    case guess

    /// The error text whose lines are read.
    static let marker = "Operation not permitted"
    /// The most paths kept from one command's error output.
    static let pathLimit = 8

    /// The verdict's name in the audit: `refused`, `not-the-sandbox`, or `guess`.
    public var name: String {
        switch self {
        case .refused: "refused"
        case .notTheSandbox: "not-the-sandbox"
        case .guess: "guess"
        }
    }

    /// The paths checked, real paths; empty for a guess.
    public var paths: [String] {
        switch self {
        case .refused(let paths), .notTheSandbox(let paths): paths
        case .guess: []
        }
    }

    /// Whether the sandbox refused the command or may have: what a person's note and `sandboxRefused` say.
    public var mayBeTheSandbox: Bool {
        if case .notTheSandbox = self { false } else { true }
    }

    /// The verdict on a failed command, or nil when there is nothing to say: it ran unconfined, succeeded, or its
    /// error output has no `Operation not permitted`.
    ///
    /// - Parameters:
    ///   - stderr: The command's error output.
    ///   - exitStatus: Its exit status.
    ///   - sandboxed: Whether it ran under the sandbox.
    ///   - roots: The writable roots, real paths (`CommandPolicy.writableRoots`).
    ///   - directory: Where it ran, for a relative path.
    /// - Returns: The verdict, or nil.
    public static func check(
        stderr: String, exitStatus: Int32, sandboxed: Bool, roots: [String], directory: String
    ) -> SandboxRefusal? {
        guard sandboxed, exitStatus != 0, stderr.contains(marker) else { return nil }
        let named = paths(in: stderr)
        guard !named.isEmpty else { return .guess }
        let real = named.map { resolved($0, in: directory) }
        var seen: Set<String> = []
        let unique = real.filter { seen.insert($0).inserted }.prefix(pathLimit)
        let outside = unique.filter { !inside($0, roots: roots) }
        return outside.isEmpty ? .notTheSandbox(paths: Array(unique)) : .refused(paths: outside)
    }

    /// The paths named by the lines of `stderr` that report `Operation not permitted`, in order, as written.
    ///
    /// The shapes read: a tool's or the shell's `name: PATH: Operation not permitted` (`sh`, `touch`, `cp`,
    /// `mkdir`, `rm`, `ln`, and the like, `sh: line 1: PATH: …` too), GNU's `cp: cannot create regular file 'PATH':
    /// Operation not permitted`, `mv`'s `rename A to PATH: …`, and Python's `PermissionError: [Errno 1] Operation not
    /// permitted: 'PATH'`. A line with no absolute, home, or dotted path, such as `Error: Operation not permitted`,
    /// names none.
    ///
    /// - Parameter stderr: The error output.
    /// - Returns: The paths.
    static func paths(in stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let range = line.range(of: marker) else { return nil }
            // Python and others: the path after the marker, `…: 'PATH'`.
            let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(":") {
                let candidate = unquoted(after.dropFirst().trimmingCharacters(in: .whitespaces))
                if looksLikePath(candidate) { return candidate }
            }
            // Everything else: the segment before `: Operation not permitted`.
            var before = String(line[..<range.lowerBound])
            if before.hasSuffix(": ") { before.removeLast(2) }
            guard let segment = before.components(separatedBy: ": ").last else { return nil }
            let whole = unquoted(segment.trimmingCharacters(in: .whitespaces))
            if looksLikePath(whole) { return whole }
            // `cannot create regular file 'PATH'`, `rename A to PATH`: the last word that is a path.
            let words = segment.split(separator: " ").map { unquoted(String($0)) }
            return words.last(where: looksLikePath)
        }
    }

    /// `text` without one pair of surrounding quotes (`'`, `"`, or GNU's curly ones).
    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
            ["'", "\"", "‘", "“", "`"].contains(first), ["'", "\"", "’", "”", "`"].contains(last)
        else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// Whether `text` reads as a path: absolute, from the home directory, or relative with a dot.
    private static func looksLikePath(_ text: String) -> Bool {
        text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../")
    }

    /// `path` as the profile matches it: absolute (from `directory`, or the home directory for `~`), with its
    /// symlinks resolved as far as it exists (`/tmp` is `/private/tmp`).
    ///
    /// - Parameters:
    ///   - path: The path as written.
    ///   - directory: Where the command ran.
    /// - Returns: The real path.
    static func resolved(_ path: String, in directory: String) -> String {
        var absolute = path
        if path.hasPrefix("~/") {
            absolute = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
        } else if !path.hasPrefix("/") {
            absolute =
                URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true))
                .standardizedFileURL.path
        }
        return CommandPolicy.canonical(URL(fileURLWithPath: absolute).standardizedFileURL.path)
    }

    /// Whether real path `path` is a writable root or under one.
    static func inside(_ path: String, roots: [String]) -> Bool {
        roots.contains { root in path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
    }

    /// The most bytes of roots a note lists before it says how many more.
    static let noteRootsBytes = 240

    /// What the model's `run_command` result says of the verdict, short and bounded (three paths, the roots within
    /// `noteRootsBytes`): which write the sandbox refused and where commands may write; that a path inside
    /// the roots was refused by something else; or, with no path to check, that the sandbox may have refused it and
    /// no policy rule did, since the policy let the command run.
    ///
    /// - Parameter roots: The writable roots.
    /// - Returns: The note.
    public func note(roots: [String]) -> String {
        func listed(_ paths: [String]) -> String {
            let shown = paths.prefix(3).joined(separator: ", ")
            return paths.count > 3 ? shown + " and \(paths.count - 3) more" : shown
        }
        switch self {
        case .refused(let paths):
            var shown: [String] = []
            var bytes = 0
            for root in roots {
                bytes += root.utf8.count + 2
                guard bytes <= Self.noteRootsBytes || shown.isEmpty else { break }
                shown.append(root)
            }
            let more = roots.count > shown.count ? " and \(roots.count - shown.count) more" : ""
            return "sandbox: refused writing to \(listed(paths)); commands may write only under "
                + shown.joined(separator: ", ") + more
        case .notTheSandbox(let paths):
            return "sandbox: not the sandbox: \(listed(paths)) is inside the writable roots, so something else "
                + "refused it (file permissions, flags, or system protection)"
        case .guess:
            return "sandbox: the sandbox may have refused this (Operation not permitted, no path to check: a network "
                + "connection, a process, or a file the error does not name); no policy rule denied it"
        }
    }
}

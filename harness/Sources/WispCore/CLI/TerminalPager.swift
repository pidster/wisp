import Darwin
import Foundation

/// The terminal chat's pager for a stored output shown whole (`/show`, `/last`, ADR 0050): `$PAGER`, or `less -R`
/// when it is unset or empty, run through `/bin/sh -c` with the output on its standard input and the terminal for
/// the rest. Used only when standard output is a terminal; otherwise the output is printed whole, bounded by the
/// output store's ceiling alone, so a pipe or a file gets all of it.
public enum TerminalPager {
    /// The pager when `$PAGER` names none.
    public static let fallback = "less -R"

    /// The command line to page through, or nil when standard output is not a terminal.
    ///
    /// - Parameters:
    ///   - environment: The process environment, for `PAGER`.
    ///   - isTerminal: Whether standard output is a terminal.
    /// - Returns: The command line, or nil.
    public static func command(environment: [String: String], isTerminal: Bool) -> String? {
        guard isTerminal else { return nil }
        let named = environment["PAGER"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return named.isEmpty ? fallback : named
    }

    /// Runs `command` through `/bin/sh -c` with `text` on its standard input, inheriting standard output and error,
    /// and waits for it. A pager quit before reading everything ends the write quietly: the pipe is set not to raise
    /// `SIGPIPE`, so wisp is not killed by it.
    ///
    /// - Parameters:
    ///   - text: What to page.
    ///   - command: The pager's command line.
    /// - Returns: What became of it; the caller prints the text instead when the pager could not start.
    @discardableResult
    public static func run(_ text: String, command: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
        } catch {
            return .notStarted
        }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        var data = Data(text.utf8)
        if !data.isEmpty, data.last != 0x0A { data.append(0x0A) }
        data.withUnsafeBytes { buffer in
            guard var next = buffer.baseAddress else { return }
            var left = buffer.count
            while left > 0 {
                let written = Darwin.write(descriptor, next, left)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }  // EPIPE: the pager was quit before the end
                next += written
                left -= written
            }
        }
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? .paged : .failed(process.terminationStatus)
    }

    /// What became of a pager run.
    public enum Outcome: Equatable, Sendable {
        /// It ran and exited 0.
        case paged
        /// It ran and exited with this status.
        case failed(Int32)
        /// It could not be started.
        case notStarted

        /// Whether the pager showed the text: false when it could not start, or the shell could not find or run it
        /// (126, 127), so the caller prints the text instead.
        public var shown: Bool {
            switch self {
            case .paged: true
            case .failed(let status): status != 126 && status != 127
            case .notStarted: false
            }
        }
    }
}

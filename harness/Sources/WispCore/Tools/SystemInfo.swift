import Foundation
import FoundationModels

/// What `system_info` can report about this Mac.
@Generable
public enum SystemTopic: String, Sendable, CaseIterable {
    /// Listening TCP ports and the processes behind them, or everything on one port.
    case ports
    /// Free and used space on each volume.
    case freeSpace
    /// The largest items directly inside a folder.
    case folderSizes
    /// The processes using the most CPU.
    case processes
    /// Memory in use, pressure, and the processes using the most.
    case memory
    /// One process by id or name: its resources, command line, and listening ports.
    case process
    /// Battery charge and power source.
    case battery
    /// macOS version, hardware, and uptime.
    case system
    /// Network interfaces and the primary route.
    case network
}

/// Answers questions about this Mac with fixed, read-only commands that wisp chooses and parses, so the
/// model neither composes shell nor reads raw output ([ADR 0034](../../../../docs/decisions/0034-system-info.md)).
/// Each topic is one to three commands through `probe`; the result is a short table, bounded.
public struct SystemInfo: Sendable {
    /// Runs one fixed command line and returns its standard output, exit status, and whether it timed out.
    public typealias Probe = @Sendable (String) async throws -> (output: String, exitStatus: Int32, timedOut: Bool)

    /// Rows listed at most per table.
    static let maxRows = 15
    /// Bytes returned at most.
    public static let maxBytes = 4096

    /// Why a request cannot be answered.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// `target` was needed and missing, or was not a port, process id, or name.
        case badTarget(String)
        /// `path` is not an existing directory.
        case badPath(String)

        /// Human-readable explanation, as the model reads it.
        public var description: String {
            switch self {
            case .badTarget(let detail): "target \(detail)"
            case .badPath(let path): "path is not a folder on this Mac: \(path)"
            }
        }
    }

    /// Samples this user's processes with their CPU use.
    public typealias Processes = @Sendable () async -> [ProcessTable.Sample]

    /// Runs the commands.
    private let probe: Probe
    /// Samples the process table.
    private let processes: Processes
    /// Reads a process's command line.
    private let commandLine: @Sendable (Int32) -> String?
    /// Installed memory in bytes.
    private let installed: UInt64
    /// Where `~` and a missing `folderSizes` path point.
    private let home: String

    /// Creates the reporter.
    ///
    /// - Parameters:
    ///   - home: The user's home directory, for `~` and the default folder.
    ///   - probe: Runs a command line; the tool passes a runner under the sandbox without the approval gate.
    ///   - processes: Samples the process table; `ProcessTable` by default.
    ///   - commandLine: Reads a process's arguments; `ProcessTable` by default.
    ///   - installed: Installed memory in bytes.
    public init(
        home: String = NSHomeDirectory(), probe: @escaping Probe,
        processes: @escaping Processes = { await ProcessTable.sample() },
        commandLine: @escaping @Sendable (Int32) -> String? = ProcessTable.commandLine(of:),
        installed: UInt64 = ProcessTable.installedBytes
    ) {
        self.home = home
        self.probe = probe
        self.processes = processes
        self.commandLine = commandLine
        self.installed = installed
    }

    /// Reports on `topic`.
    ///
    /// - Parameters:
    ///   - topic: What to report.
    ///   - target: A port for `ports`, a process id or name for `process`; ignored otherwise.
    ///   - path: The folder for `folderSizes`; the home directory when nil.
    /// - Returns: Text of at most `maxBytes`.
    /// - Throws: `Failure` for a bad target or path, or whatever the probe throws.
    public func report(_ topic: SystemTopic, target: String? = nil, path: String? = nil) async throws -> String {
        let text: String
        switch topic {
        case .ports: text = try await ports(target)
        case .freeSpace: text = Self.disk(try await run("/bin/df -k -l"))
        case .folderSizes: text = try await diskUsage(path)
        case .processes:
            text = Self.table(
                await processes().sorted { $0.cpuPercent > $1.cpuPercent }, by: "CPU", installed: installed)
        case .memory:
            text = Self.memory(
                installed: installed, pressure: try await run("/usr/bin/memory_pressure -Q"),
                processes: await processes().sorted { $0.entry.residentBytes > $1.entry.residentBytes })
        case .process: text = try await process(target)
        case .battery: text = Self.plain(try await run("/usr/bin/pmset -g batt"), empty: "no battery information")
        case .system:
            text = Self.system(
                versions: try await run("/usr/bin/sw_vers"),
                hardware: try await run("/usr/sbin/sysctl -n hw.model machdep.cpu.brand_string hw.memsize hw.ncpu"),
                uptime: try await run("/usr/bin/uptime"))
        case .network: text = Self.plain(try await run("/usr/sbin/scutil --nwi"), empty: "no network information")
        }
        return Self.bounded(text)
    }

    /// Standard output of one command; a timeout is noted rather than thrown, so partial output is kept.
    private func run(_ line: String) async throws -> String {
        let result = try await probe(line)
        return result.timedOut ? result.output + "\n(timed out; partial)" : result.output
    }

    private func ports(_ target: String?) async throws -> String {
        if let target {
            guard let port = Int(target.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
                throw Failure.badTarget("for ports must be a port number, not \(target)")
            }
            return Self.ports(try await run("/usr/sbin/lsof -nP -i :\(port) -F pcPnT"), port: port)
        }
        return Self.ports(try await run("/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcPnT"), port: nil)
    }

    /// The `folderSizes` report for `path`, the home folder when it is nil or blank: models that fill every
    /// argument send `""` for "no folder". `du` exits 1 when it could not read some folders (privacy
    /// protection, the sandbox) and still prints the rest, so the report says the sizes may be low.
    private func diskUsage(_ path: String?) async throws -> String {
        let named = path?.trimmingCharacters(in: .whitespaces) ?? ""
        let folder = Self.expand(named.isEmpty ? "~" : named, home: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.badPath(folder)
        }
        let result = try await probe("/usr/bin/du -x -k -d 1 \(Self.quoted(folder)) 2>/dev/null")
        let report = Self.diskUsage(
            result.timedOut ? result.output + "\n(timed out; partial)" : result.output, folder: folder)
        guard !result.timedOut, result.exitStatus != 0 else { return report }
        return report + "\n(some folders could not be read, so sizes may be low)"
    }

    private func process(_ target: String?) async throws -> String {
        guard let target = target?.trimmingCharacters(in: .whitespaces), !target.isEmpty else {
            throw Failure.badTarget(
                "missing: call system_info again with topic process and process set to the app's name or id")
        }
        let matches = await processes().filter { sample in
            Int32(target).map { sample.entry.pid == $0 } ?? sample.entry.name.localizedCaseInsensitiveContains(target)
        }
        guard !matches.isEmpty else { return "no process of yours matches \(target)" }
        var lines = Self.rows(Array(matches.prefix(Self.maxRows)), installed: installed, parent: true)
        if matches.count > Self.maxRows { lines.append("… \(matches.count - Self.maxRows) more") }
        if matches.count == 1, let pid = matches.first?.entry.pid {
            if let command = commandLine(pid) {
                var redactor = Redactor()
                lines.append(
                    "command: " + redactor.apply(SecretScanner.scan(command, categories: [.secret]), to: command))
            }
            let listening = Self.portRows(try await run("/usr/sbin/lsof -nP -a -p \(pid) -iTCP -sTCP:LISTEN -F pcPnT"))
            lines.append(
                listening.isEmpty
                    ? "listening: none" : "listening: " + listening.map(\.address).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsers, pure over command output

    /// One socket from `lsof -F pcPnT` output.
    struct PortRow: Equatable {
        /// The owning process id.
        var pid: Int
        /// The owning command.
        var command: String
        /// TCP or UDP.
        var proto: String
        /// The address, `*:8080` or `127.0.0.1:5000->127.0.0.1:61234`.
        var address: String
        /// The TCP state, such as `LISTEN`, when given.
        var state: String?
    }

    /// Sockets from `lsof -F pcPnT`: `p` starts a process, `c` names it, `f` starts a file, `P`, `n`, and
    /// `TST=` describe it.
    static func portRows(_ output: String) -> [PortRow] {
        var rows: [PortRow] = []
        var pid = 0
        var command = ""
        var current: PortRow?
        func flush() {
            if let row = current, !row.address.isEmpty, !rows.contains(row) { rows.append(row) }
            current = nil
        }
        for line in output.split(separator: "\n") {
            let field = line.first
            let value = String(line.dropFirst())
            switch field {
            case "p":
                flush()
                pid = Int(value) ?? 0
            case "c": command = value
            case "f":
                flush()
                current = PortRow(pid: pid, command: command, proto: "", address: "", state: nil)
            case "P": current?.proto = value
            case "n": current?.address = value
            case "T" where value.hasPrefix("ST="): current?.state = String(value.dropFirst(3))
            default: break
            }
        }
        flush()
        return rows
    }

    /// The `ports` table.
    static func ports(_ output: String, port: Int?) -> String {
        let rows = portRows(output)
        let scope = port.map { "on port \($0)" } ?? "listening on TCP"
        guard !rows.isEmpty else {
            return "nothing \(scope) among your processes (other users' processes are visible only to root)"
        }
        var lines = ["\(rows.count) socket\(rows.count == 1 ? "" : "s") \(scope)"]
        lines += TextTable.render(
            header: ["COMMAND", "PID", "PROTO", "ADDRESS", "STATE"],
            rows: rows.prefix(maxRows).map { [$0.command, "\($0.pid)", $0.proto, $0.address, $0.state ?? ""] },
            rightAligned: [1])
        if rows.count > maxRows { lines.append("… \(rows.count - maxRows) more") }
        lines.append("(your processes only; other users' are visible only to root)")
        return lines.joined(separator: "\n")
    }

    /// The `freeSpace` table from `df -k -l`: the root, the data volume, and anything under `/Volumes`, without
    /// the system's other APFS volumes.
    static func disk(_ output: String) -> String {
        var rows: [[String]] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9, let size = Int(fields[1]), let used = Int(fields[2]),
                let free = Int(fields[3])
            else { continue }
            let mount = fields[8...].joined(separator: " ")
            guard mount == "/" || mount == "/System/Volumes/Data" || mount.hasPrefix("/Volumes/") else { continue }
            rows.append([
                mount, Self.size(kilobytes: size), Self.size(kilobytes: used), Self.size(kilobytes: free),
                String(fields[4]),
            ])
        }
        guard !rows.isEmpty else { return "no local volumes reported" }
        return
            (TextTable.render(
                header: ["MOUNT", "SIZE", "USED", "FREE", "CAPACITY"], rows: rows, rightAligned: [1, 2, 3, 4])
            + ["(on APFS, / and /System/Volumes/Data share one container's free space)"]).joined(separator: "\n")
    }

    /// The `folderSizes` table from `du -k -d 1`: the largest items first, the folder's total last.
    static func diskUsage(_ output: String, folder: String) -> String {
        var total: Int?
        var items: [(size: Int, path: String)] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let size = Int(parts[0]) else { continue }
            let path = String(parts[1])
            if path == folder || path == folder + "/" { total = size } else { items.append((size, path)) }
        }
        guard !items.isEmpty || total != nil else { return "nothing readable in \(folder)" }
        let sorted = items.sorted { $0.size > $1.size }
        var lines = [
            "\(folder): \(total.map { size(kilobytes: $0) } ?? "?") in \(items.count) item\(items.count == 1 ? "" : "s")"
        ]
        lines += TextTable.render(
            header: ["SIZE", "PATH"],
            rows: sorted.prefix(maxRows).map {
                [size(kilobytes: $0.size), String($0.path.dropFirst(folder.count).drop { $0 == "/" })]
            },
            rightAligned: [0])
        if sorted.count > maxRows { lines.append("… \(sorted.count - maxRows) smaller") }
        if output.contains("(timed out; partial)") { lines.append("(timed out; sizes are partial)") }
        return lines.joined(separator: "\n")
    }

    /// The table of the busiest processes, with a headline saying how many and by what.
    static func table(_ samples: [ProcessTable.Sample], by: String, installed: UInt64) -> String {
        guard !samples.isEmpty else { return "no processes of yours reported" }
        let shown = Array(samples.prefix(maxRows))
        return (["top \(shown.count) of your \(samples.count) processes by \(by)"] + rows(shown, installed: installed))
            .joined(separator: "\n")
    }

    /// Process rows as a table: pid, CPU, memory share, resident size, elapsed, name, and the parent's pid
    /// when asked.
    static func rows(
        _ samples: [ProcessTable.Sample], installed: UInt64, parent: Bool = false, now: Date = Date()
    )
        -> [String]
    {
        let header = ["PID"] + (parent ? ["PPID"] : []) + ["CPU%", "MEM%", "RSS", "ELAPSED", "NAME"]
        return TextTable.render(
            header: header,
            rows: samples.map { sample in
                let entry = sample.entry
                let share = installed > 0 ? Double(entry.residentBytes) / Double(installed) * 100 : 0
                return ["\(entry.pid)"] + (parent ? ["\(entry.ppid)"] : []) + [
                    String(format: "%.1f", sample.cpuPercent), String(format: "%.1f", share),
                    size(kilobytes: Int(entry.residentBytes / 1024)), elapsed(since: entry.started, now: now),
                    entry.name,
                ]
            }, rightAligned: Set(0..<(parent ? 6 : 5)))
    }

    /// Time since `start` as `3d 4h`, `2h 5m`, or `40s`.
    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (days, hours, minutes) = (seconds / 86_400, seconds / 3600 % 24, seconds / 60 % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    /// The `memory` report: installed memory, the system's free percentage, and the processes using the most.
    static func memory(installed: UInt64, pressure: String, processes: [ProcessTable.Sample]) -> String {
        var lines: [String] = []
        if installed > 0 { lines.append("installed: \(size(kilobytes: Int(installed / 1024)))") }
        if let free = pressure.split(separator: "\n").first(where: { $0.contains("free percentage") }) {
            lines.append(free.trimmingCharacters(in: .whitespaces))
        }
        lines.append(table(processes, by: "memory", installed: installed))
        return lines.joined(separator: "\n")
    }

    /// The `system` report.
    static func system(versions: String, hardware: String, uptime: String) -> String {
        let facts = hardware.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var lines = versions.split(separator: "\n").map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        if facts.count == 4 {
            lines.append("ProductModel: \(facts[0])")
            lines.append("CPU: \(facts[1]), \(facts[3]) cores")
            if let bytes = Int(facts[2]) { lines.append("Memory: \(size(kilobytes: bytes / 1024))") }
        }
        lines.append("Uptime: " + uptime.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    /// A command's output as it is, trimmed, or `empty` when there is none.
    static func plain(_ output: String, empty: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? empty : text
    }

    /// A size in kilobytes as a person reads it: `512 KB`, `3.4 GB`.
    static func size(kilobytes: Int) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(kilobytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 || value >= 100
            ? "\(Int(value.rounded())) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }

    /// `~` and `~/…` expanded against `home`; other paths as given.
    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    /// A string single-quoted for `/bin/sh`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `text` cut to `maxBytes` at a line end, with a note when cut.
    static func bounded(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var kept = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard kept.utf8.count + line.utf8.count + 40 < maxBytes else { break }
            kept += line + "\n"
        }
        return kept + "(cut to \(maxBytes) bytes)"
    }
}

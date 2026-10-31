import Darwin
import Foundation

/// The processes of this user, read through `libproc` and `sysctl` rather than `ps`: `/bin/ps` and
/// `/usr/bin/top` are setuid root, and Seatbelt refuses to execute a setuid binary, so neither can run
/// inside wisp's sandbox. Without root, `libproc` describes only the calling user's processes; every
/// report that uses this says so ([ADR 0034](../../../../docs/decisions/0034-system-info.md)).
public enum ProcessTable {
    /// One process at one moment.
    public struct Entry: Equatable, Sendable {
        /// Its id.
        public var pid: Int32
        /// Its parent's id.
        public var ppid: Int32
        /// Its name.
        public var name: String
        /// Resident memory in bytes.
        public var residentBytes: UInt64
        /// User and system CPU time consumed so far, in nanoseconds.
        public var cpuNanoseconds: UInt64
        /// When it started.
        public var started: Date
    }

    /// One process with its CPU use over a sampling interval.
    public struct Sample: Equatable, Sendable {
        /// The process as it was at the end of the interval.
        public var entry: Entry
        /// Percent of one core used over the interval.
        public var cpuPercent: Double
    }

    /// Every process of this user that `libproc` will describe, now.
    public static func snapshot() -> [Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return [] }
        let timebase = Self.timebase
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
            let ticks = info.ptinfo.pti_total_user + info.ptinfo.pti_total_system
            return Entry(
                pid: pid, ppid: Int32(info.pbsd.pbi_ppid), name: Self.name(of: info.pbsd),
                residentBytes: info.ptinfo.pti_resident_size,
                cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(max(1, timebase.denom)),
                started: Date(timeIntervalSince1970: TimeInterval(info.pbsd.pbi_start_tvsec)))
        }
    }

    /// Two snapshots `interval` apart, giving each process's CPU use between them: what `top` shows, where one
    /// snapshot gives only the CPU time used since a process started. A process absent from the first snapshot,
    /// or whose counter went backwards (a reused pid), counts as none.
    ///
    /// - Parameter interval: How long to sample over.
    /// - Returns: Each process in the second snapshot, with its CPU use.
    public static func sample(over interval: Duration = .milliseconds(500)) async -> [Sample] {
        let before = Dictionary(snapshot().map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { first, _ in first })
        let start = ContinuousClock.now
        try? await Task.sleep(for: interval)
        let components = (ContinuousClock.now - start).components
        let elapsed = Double(components.seconds) * 1e9 + Double(components.attoseconds) / 1e9
        return snapshot().map { entry in
            let used = before[entry.pid].map { entry.cpuNanoseconds >= $0 ? entry.cpuNanoseconds - $0 : 0 } ?? 0
            return Sample(entry: entry, cpuPercent: cpuPercent(used: used, over: elapsed))
        }
    }

    /// Percent of one core that `used` nanoseconds of CPU time is over `elapsed` nanoseconds.
    static func cpuPercent(used: UInt64, over elapsed: Double) -> Double {
        elapsed > 0 ? Double(used) / elapsed * 100 : 0
    }

    /// The process's arguments, joined by spaces, from `KERN_PROCARGS2`; nil when they cannot be read (another
    /// user's process, or one that has exited). Arguments can carry secrets; `SystemInfo` masks them before the model
    /// sees the line.
    ///
    /// - Parameter pid: The process.
    /// - Returns: The command line, or nil.
    public static func commandLine(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return arguments(fromProcArgs: Array(buffer.prefix(size)))
    }

    /// The arguments in a `KERN_PROCARGS2` buffer: an `Int32` count, the executable path, padding NULs,
    /// then that many NUL-terminated arguments.
    static func arguments(fromProcArgs buffer: [UInt8]) -> String? {
        guard buffer.count > 4 else { return nil }
        let count = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.isEmpty ? nil : arguments.joined(separator: " ")
    }

    /// Installed memory in bytes, from `hw.memsize`.
    public static var installedBytes: UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 ? value : 0
    }

    /// The Mach timebase, to turn CPU ticks into nanoseconds.
    private static var timebase: mach_timebase_info_data_t {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }

    /// The longer name `libproc` keeps, or the short command name when it is empty.
    private static func name(of info: proc_bsdinfo) -> String {
        let long = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

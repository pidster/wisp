import Foundation
import Synchronization
import Testing

@testable import WispCore

@Suite struct SystemInfoTests {
    /// Canned output per command line, and the lines asked for.
    final class Commands: Sendable {
        let outputs: [String: String]
        let statuses: [String: Int32]
        let asked = Mutex<[String]>([])
        init(_ outputs: [String: String], statuses: [String: Int32] = [:]) {
            self.outputs = outputs
            self.statuses = statuses
        }

        var probe: SystemInfo.Probe {
            { line in
                self.asked.withLock { $0.append(line) }
                return (self.outputs[line] ?? "", self.statuses[line] ?? 0, false)
            }
        }
    }

    static let started = Date(timeIntervalSinceNow: -7200)
    static let samples: [ProcessTable.Sample] = [
        .init(
            entry: .init(pid: 10, ppid: 1, name: "Xcode", residentBytes: 2 << 30, cpuNanoseconds: 0, started: started),
            cpuPercent: 3.5),
        .init(
            entry: .init(pid: 20, ppid: 1, name: "node", residentBytes: 300 << 20, cpuNanoseconds: 0, started: started),
            cpuPercent: 91.2),
    ]

    func info(_ commands: Commands, home: String = "/Users/me") -> SystemInfo {
        SystemInfo(
            home: home, probe: commands.probe, processes: { Self.samples },
            commandLine: { pid in
                pid == 20 ? "node server.js --token=" + "ghp_" + String(repeating: "aB3", count: 12) : nil
            },
            installed: 16 << 30)
    }

    @Test func portsListSocketsFromLsofFields() async throws {
        let listening =
            "p947\ncrapportd\nf9\nPTCP\nn*:62183\nTST=LISTEN\nf10\nPTCP\nn*:62183\nTST=LISTEN\np2884\ncOllama\nf5\nPTCP\nn127.0.0.1:11434\nTST=LISTEN\n"
        let commands = Commands([
            "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcPnT": listening,
            "/usr/sbin/lsof -nP -i :11434 -F pcPnT": "p2884\ncOllama\nf5\nPTCP\nn127.0.0.1:11434\nTST=LISTEN\n",
        ])
        let all = try await info(commands).report(.ports)
        #expect(all.hasPrefix("2 sockets listening on TCP"), "\(all)")
        #expect(all.contains("rapportd") && all.contains("127.0.0.1:11434") && all.hasSuffix("visible only to root)"))
        let one = try await info(commands).report(.ports, target: " 11434 ")
        #expect(one.hasPrefix("1 socket on port 11434"))
        let none = try await info(commands).report(.ports, target: "8080")
        #expect(none.hasPrefix("nothing on port 8080 among your processes"))
        await #expect(throws: SystemInfo.Failure.self) { try await info(commands).report(.ports, target: "http") }
        await #expect(throws: SystemInfo.Failure.self) { try await info(commands).report(.ports, target: "70000") }
    }

    @Test func diskShowsTheVolumesAPersonHasAndDiskUsageTheLargestItems() async throws {
        let df = """
            Filesystem     1024-blocks      Used Available Capacity iused ifree %iused  Mounted on
            /dev/disk3s1s1  1942700360  13336380 1073537560     2%  453k  4.2G    0%   /
            devfs                  211       211          0   100%   732     0  100%   /dev
            /dev/disk3s6    1942700360   1048600 1073537560     1%     1  10G    0%   /System/Volumes/VM
            /dev/disk3s5    1942700360 826000000 1073537560    44%  3.1M  10G    0%   /System/Volumes/Data
            /dev/disk5s1      500000000 100000000 400000000    20%    10  10G    0%   /Volumes/My Backup
            """
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-du-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let du = "2048\t\(dir.path)/b\n4194304\t\(dir.path)/a\n4196400\t\(dir.path)\n"
        let commands = Commands([
            "/bin/df -k -l": df, "/usr/bin/du -x -k -d 1 '\(dir.path)' 2>/dev/null": du,
        ])
        let disk = try await info(commands).report(.freeSpace)
        #expect(disk.contains("/System/Volumes/Data") && disk.contains("/Volumes/My Backup") && disk.contains("44%"))
        #expect(!disk.contains("/dev") && !disk.contains("/System/Volumes/VM"), "\(disk)")
        let usage = try await info(commands).report(.folderSizes, path: dir.path)
        #expect(usage.hasPrefix("\(dir.path): 4.0 GB in 2 items"), "\(usage)")
        let lines = usage.split(separator: "\n")
        #expect(lines[2].hasSuffix("  a") && lines[3].hasSuffix("  b") && lines[2].contains("4.0 GB"))
        await #expect(throws: SystemInfo.Failure.badPath("/nope")) {
            try await info(commands).report(.folderSizes, path: "/nope")
        }
        #expect(!usage.contains("may be low"))
        // A blank path is the home folder; du that could not read some folders says the sizes may be low.
        let line = "/usr/bin/du -x -k -d 1 '\(dir.path)' 2>/dev/null"
        let blank = try await info(Commands([line: du], statuses: [line: 1]), home: dir.path).report(
            .folderSizes, path: " ")
        #expect(
            blank.hasPrefix("\(dir.path): 4.0 GB")
                && blank.hasSuffix("(some folders could not be read, so sizes may be low)"))
        #expect(SystemInfo.diskUsage("", folder: "/x") == "nothing readable in /x")
        #expect(SystemInfo.disk("header only") == "no local volumes reported")
    }

    @Test func processTopicsRankTheSamplesAndOneProcessShowsItsCommandRedacted() async throws {
        let commands = Commands([
            "/usr/bin/memory_pressure -Q":
                "The system has 17179869184 (4194304 pages with a page size of 4096).\nSystem-wide memory free percentage: 64%\n",
            "/usr/sbin/lsof -nP -a -p 20 -iTCP -sTCP:LISTEN -F pcPnT": "p20\ncnode\nf21\nPTCP\nn*:3000\nTST=LISTEN\n",
        ])
        let busy = try await info(commands).report(.processes)
        #expect(busy.hasPrefix("top 2 of your 2 processes by CPU"))
        let rows = busy.split(separator: "\n")
        #expect(rows[2].contains("node") && rows[2].contains("91.2") && rows[3].contains("Xcode"), "\(busy)")
        let memory = try await info(commands).report(.memory)
        #expect(memory.hasPrefix("installed: 16.0 GB\nSystem-wide memory free percentage: 64%\ntop 2"), "\(memory)")
        #expect(memory.split(separator: "\n")[4].contains("Xcode") && memory.contains("12.5"))
        let node = try await info(commands).report(.process, target: "NODE")
        #expect(node.contains("PPID") && node.contains("command: node server.js --token=[REDACTED:github-token#1]"))
        #expect(node.hasSuffix("listening: *:3000"), "\(node)")
        let byPid = try await info(commands).report(.process, target: "10")
        #expect(byPid.contains("Xcode") && byPid.hasSuffix("listening: none") && !byPid.contains("command:"))
        #expect(try await info(commands).report(.process, target: "absent") == "no process of yours matches absent")
        await #expect(throws: SystemInfo.Failure.self) { try await info(commands).report(.process) }
        #expect(SystemInfo.table([], by: "CPU", installed: 1) == "no processes of yours reported")
    }

    @Test func systemBatteryAndNetworkReadTheirCommands() async throws {
        let commands = Commands([
            "/usr/bin/sw_vers": "ProductName:\t\tmacOS\nProductVersion:\t\t27.0\nBuildVersion:\t\t26A428\n",
            "/usr/sbin/sysctl -n hw.model machdep.cpu.brand_string hw.memsize hw.ncpu":
                "Mac16,6\nApple M4 Max\n51539607552\n16\n",
            "/usr/bin/uptime": "22:24  up 6 days, 10:15, 9 users, load averages: 2.86 6.97 8.00\n",
            "/usr/bin/pmset -g batt": "Now drawing from 'AC Power'\n",
        ])
        let system = try await info(commands).report(.system)
        #expect(
            system == """
                ProductName: macOS
                ProductVersion: 27.0
                BuildVersion: 26A428
                ProductModel: Mac16,6
                CPU: Apple M4 Max, 16 cores
                Memory: 48.0 GB
                Uptime: 22:24  up 6 days, 10:15, 9 users, load averages: 2.86 6.97 8.00
                """, "\(system)")
        #expect(try await info(commands).report(.battery) == "Now drawing from 'AC Power'")
        #expect(try await info(commands).report(.network) == "no network information")
    }

    @Test func theDefaultProcessSourceReadsThisMacsProcessTable() async throws {
        let live = SystemInfo(probe: { _ in ("", 0, false) })
        let report = try await live.report(.process, target: String(ProcessInfo.processInfo.processIdentifier))
        #expect(report.contains("PID") && report.contains("command:"), "\(report)")
    }

    @Test func helpersFormatQuoteExpandAndBound() {
        #expect(SystemInfo.size(kilobytes: 512) == "512 KB" && SystemInfo.size(kilobytes: 3_565_158) == "3.4 GB")
        #expect(SystemInfo.size(kilobytes: 150 * 1024) == "150 MB")
        #expect(SystemInfo.quoted("it's here") == #"'it'\''s here'"#)
        #expect(SystemInfo.expand("~/Library", home: "/Users/me") == "/Users/me/Library")
        #expect(
            SystemInfo.expand("~", home: "/Users/me") == "/Users/me" && SystemInfo.expand("/tmp", home: "/x") == "/tmp")
        let long = (1...400).map { "line \($0) with some words" }.joined(separator: "\n")
        let bounded = SystemInfo.bounded(long)
        #expect(bounded.utf8.count <= SystemInfo.maxBytes && bounded.hasSuffix("(cut to 4096 bytes)"))
        #expect(SystemInfo.bounded("short") == "short")
        let now = Date()
        #expect(SystemInfo.elapsed(since: now.addingTimeInterval(-40), now: now) == "40s")
        #expect(SystemInfo.elapsed(since: now.addingTimeInterval(-125), now: now) == "2m 5s")
        #expect(SystemInfo.elapsed(since: now.addingTimeInterval(-7500), now: now) == "2h 5m")
        #expect(SystemInfo.elapsed(since: now.addingTimeInterval(-3 * 86_400 - 3600), now: now) == "3d 1h")
    }

    @Test func aTimedOutCommandKeepsItsPartialOutputAndTheToolReportsErrorsAsText() async throws {
        let dir = FileManager.default.temporaryDirectory
        let slow = SystemInfo(
            home: dir.path, probe: { _ in ("1024\t\(dir.path)/x\n", -15, true) }, processes: { [] }, installed: 0)
        let partial = try await slow.report(.folderSizes)
        #expect(partial.hasSuffix("(timed out; sizes are partial)"), "\(partial)")
        let tool = SystemInfoTool(info: slow)
        #expect(
            await tool.call(arguments: .init(topic: .process, port: nil, process: "", path: nil)).hasPrefix(
                "error: target"))
        #expect(await tool.call(arguments: .init(topic: .ports, port: 0, process: "", path: nil)).hasPrefix("error:"))
        #expect(
            tool.name == "system_info" && tool.limits.contains("4096") && tool.examplePrompt.contains("system_info"))
        #expect(SystemInfo.Failure.badPath("/p").description == "path is not a folder on this Mac: /p")
    }
}

@Suite struct ProcessTableTests {
    @Test func theTableSeesThisProcessAndItsArguments() async {
        let me = ProcessInfo.processInfo.processIdentifier
        let entry = ProcessTable.snapshot().first { $0.pid == me }
        #expect(entry != nil && (entry?.residentBytes ?? 0) > 0 && (entry?.cpuNanoseconds ?? 0) > 0)
        #expect(ProcessTable.commandLine(of: me)?.isEmpty == false)
        #expect(ProcessTable.installedBytes > 1 << 30)
        let samples = await ProcessTable.sample(over: .milliseconds(50))
        #expect(samples.contains { $0.entry.pid == me } && samples.allSatisfy { $0.cpuPercent >= 0 })
        #expect(ProcessTable.commandLine(of: -1) == nil)
    }

    @Test func procArgsAndCPUArithmetic() {
        // argc 2, the executable path and its padding, two arguments, then the environment.
        let parts: [[UInt8]] = [
            [2, 0, 0, 0], Array("/bin/echo".utf8), [0, 0, 0], Array("echo".utf8), [0], Array("hi".utf8), [0],
            Array("PATH=/bin".utf8), [0],
        ]
        let buffer = parts.flatMap { $0 }
        #expect(ProcessTable.arguments(fromProcArgs: buffer) == "echo hi")
        #expect(ProcessTable.arguments(fromProcArgs: [1, 0]) == nil)
        #expect(ProcessTable.cpuPercent(used: 250_000_000, over: 500_000_000) == 50)
        #expect(ProcessTable.cpuPercent(used: 1, over: 0) == 0)
    }
}

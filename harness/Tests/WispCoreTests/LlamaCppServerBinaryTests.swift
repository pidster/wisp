import Foundation
import Testing
import WispTestSupport

@testable import WispCore

/// The `llama-server` wisp's own server would run (ADR 0082, decision 5): `wisp config set llamacpp.serverPath`
/// approves a Mach-O executable by its digest, recorded outside `config.json`; the check before each start refuses a
/// path not approved, moved, missing, or changed; `wisp doctor` shows the state; the model cannot approve. Every
/// executable is a scratch file with Mach-O magic bytes.
@Suite(.serialized) struct LlamaCppServerBinaryTests {
    /// The scratch root: executables under `bin`, the home under `home`.
    private let root: URL

    init() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "wisp-llamacpp-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch.appending(path: "bin"), withIntermediateDirectories: true)
        // Real paths, as the record keeps them: `/private/var/…`, not `/var/…`.
        root = URL(filePath: CommandPolicy.canonical(scratch.path))
    }

    /// A fake executable under `bin`: a 64-bit Mach-O magic, then `body`; executable unless `mode` says otherwise.
    @discardableResult
    private func executable(
        _ name: String, body: String = "one", head: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE], mode: Int = 0o755
    ) throws -> URL {
        let file = root.appending(path: "bin/\(name)")
        var data = Data(head)
        data.append(Data(body.utf8))
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }

    /// A scratch home with an empty `config.json`.
    private func home() throws -> Home {
        let home = Home(root: root.appending(path: "home"))
        try home.ensure()
        try Data("{}".utf8).write(to: home.configFile)
        return home
    }

    /// The setting as `config.json` now holds it.
    private func setting(_ home: Home) throws -> String? {
        try ConfigEdit.current(LlamaCppServerBinary.setting, in: Data(contentsOf: home.configFile))?.stringValue
    }

    @Test func settingThePathApprovesTheFileOutsideTheConfiguration() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try executable("llama-server")
        // A link, as Homebrew's bin is: the path as given is kept, its real path recorded.
        let link = root.appending(path: "bin/linked-server")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        #expect(binary.file.path.hasPrefix(home.support.path))
        let sink = MemoryAuditSink()
        let change = try binary.change(
            "bin/linked-server", configFile: home.configFile, workingDirectory: root,
            audit: AuditLog(session: "s", sink: sink), source: "cli")
        #expect(try setting(home) == link.path)
        #expect(change.lines.first?.hasPrefix("approved \(link.path): it resolves to \(real.path), sha256 ") == true)
        let approval = try #require(try binary.approval())
        #expect(approval.path == link.path && approval.resolved == real.path && approval.sha256.count == 64)
        // config.json holds only the path; the record is owner only, in a folder owner only.
        #expect(try !String(decoding: Data(contentsOf: home.configFile), as: UTF8.self).contains(approval.sha256))
        let manager = FileManager.default
        #expect(try manager.attributesOfItem(atPath: binary.file.path)[.posixPermissions] as? Int == 0o600)
        let folder = binary.file.deletingLastPathComponent().path
        #expect(try manager.attributesOfItem(atPath: folder)[.posixPermissions] as? Int == 0o700)
        let event = try #require(sink.events.last { $0.kind == .llamaCppServerApprove })
        #expect(Set(event.details.keys) == AuditEvent.fields(for: .llamaCppServerApprove))
        #expect(event.details["outcome"] == "approved" && event.details["sha256"] == .string(approval.sha256))
        #expect(event.details["previousSha256"] == .null && event.details["source"] == "cli")
        let config = try #require(sink.events.last { $0.kind == .configChange })
        #expect(config.details["path"] == "llamacpp.serverPath" && config.details["new"] == .string(link.path))

        // The check passes, naming the real file to run.
        let approved = try binary.check(link.path)
        #expect(approved.executable.path == real.path && approved.sha256 == approval.sha256)

        // Approving the same file again changes nothing and says so.
        let again = try binary.change(
            link.path, configFile: home.configFile, workingDirectory: root, audit: AuditLog(session: "s", sink: sink),
            source: "cli")
        #expect(again.lines.contains("it was approved already, unchanged"))
        #expect(sink.events.last { $0.kind == .llamaCppServerApprove }?.details["outcome"] == "unchanged")
    }

    @Test func aChangedFileIsRefusedUntilApprovedAgain() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try executable("llama-server")
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        _ = try binary.change(
            file.path, configFile: home.configFile, workingDirectory: root, audit: audit, source: "cli")
        let first = try #require(try binary.approval())

        // An upgrade in place: same path, other bytes.
        try executable("llama-server", body: "two")
        #expect {
            try binary.verify(file.path, audit: audit, source: "test")
        } throws: { error in
            guard case .changed(let path, let approved, let now) = error as? LlamaCppServerBinary.Refusal else {
                return false
            }
            let text = "\(error)"
            return path == file.path && approved == first.sha256 && now != approved
                && text.contains("sha256 \(now.prefix(12)), not \(approved.prefix(12)) as approved")
                && text.hasSuffix("approve the file now there with: wisp config set llamacpp.serverPath \(file.path)")
        }
        let refused = try #require(sink.events.last { $0.kind == .llamaCppServerRefused })
        #expect(Set(refused.details.keys) == AuditEvent.fields(for: .llamaCppServerRefused))
        #expect(refused.details["refusal"] == "changed" && refused.details["approvedSha256"] == .string(first.sha256))

        // Setting the same path again approves the new file, saying what it replaced.
        let change = try binary.change(
            file.path, configFile: home.configFile, workingDirectory: root, audit: audit, source: "cli")
        #expect(change.lines.contains("it replaces the approval of \(file.path) (sha256 \(first.sha256.prefix(12)))"))
        let event = try #require(sink.events.last { $0.kind == .llamaCppServerApprove })
        #expect(event.details["outcome"] == "approved" && event.details["previousSha256"] == .string(first.sha256))
        #expect(try binary.check(file.path).sha256 != first.sha256)
    }

    @Test func theCheckRefusesWhatWasNotApprovedAsItStands() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try executable("one")
        let two = try executable("two", body: "two")
        let link = root.appending(path: "bin/llama-server")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: one)
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        func refusal(_ path: String?) -> LlamaCppServerBinary.Refusal? {
            do {
                _ = try binary.check(path)
                return nil
            } catch {
                return error as? LlamaCppServerBinary.Refusal
            }
        }
        #expect(refusal(nil) == .notSet)
        #expect("\(LlamaCppServerBinary.Refusal.notSet)".contains("wisp config set llamacpp.serverPath "))
        // A path in config.json with no approval, as one written by hand.
        #expect(refusal(link.path) == .notApproved(path: link.path, reason: nil))
        _ = try binary.change(link.path, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli")
        // The setting changed to another path without approving it.
        #expect(refusal(two.path) == .approvedOther(path: two.path, approved: link.path))
        // The link re-pointed, as an upgrade does.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: two)
        #expect(refusal(link.path) == .moved(path: link.path, approved: one.path, now: two.path))
        // The file gone.
        try FileManager.default.removeItem(at: two)
        #expect(refusal(link.path) == .missing(path: link.path, resolved: link.path))
        // A record that does not read is no approval.
        try Data("not json".utf8).write(to: binary.file)
        guard case .notApproved(_, let reason?) = refusal(link.path) else {
            Issue.record("a broken record was taken as an approval")
            return
        }
        #expect(reason.contains("does not read"))
    }

    @Test func onlyAnExecutableMachOFileIsApproved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        let sink = MemoryAuditSink()
        func failure(_ path: String) -> LlamaCppServerBinary.Failure? {
            do {
                _ = try binary.change(
                    path, configFile: home.configFile, workingDirectory: root,
                    audit: AuditLog(session: "s", sink: sink),
                    source: "cli")
                return nil
            } catch {
                return error as? LlamaCppServerBinary.Failure
            }
        }
        let missing = root.appending(path: "bin/absent").path
        #expect(failure(missing) == .notFound(missing))
        let folder = root.appending(path: "bin").path
        #expect(failure(folder) == .notAFile(folder, resolved: folder))
        let script = try executable("script.sh", body: "echo hi", head: Array("#!/bin/sh\n".utf8))
        #expect(failure(script.path) == .notMachO(script.path, resolved: script.path))
        let plain = try executable("plain", mode: 0o644)
        #expect(failure(plain.path) == .notExecutable(plain.path, resolved: plain.path))
        // Universal and 32-bit headers are Mach-O too; the name is not checked.
        let fat = try executable("renamed", head: [0xCA, 0xFE, 0xBA, 0xBE])
        #expect(failure(fat.path) == nil)
        // Nothing was approved or written for the refusals, and each was recorded.
        let refused = sink.events.filter { $0.kind == .llamaCppServerApprove && $0.details["outcome"] == "refused" }
        #expect(
            refused.count == 4
                && refused.first?.details["reason"] == .string("\(LlamaCppServerBinary.Failure.notFound(missing))"))
        #expect(try setting(home) == fat.path)
    }

    @Test func aFileThatCannotBeOpenedIsNeitherApprovedNorRun() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        // Executable but not readable: approving it is refused.
        let hidden = try executable("hidden", mode: 0o111)
        #expect(throws: LlamaCppServerBinary.Failure.unreadable(hidden.path, reason: "it cannot be opened")) {
            _ = try binary.change(
                hidden.path, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli")
        }
        #expect("\(LlamaCppServerBinary.Failure.unreadable("/b", reason: "r"))" == "/b cannot be read: r")
        // Approved, then made unreadable: the check before a start refuses it.
        let file = try executable("llama-server")
        _ = try binary.change(file.path, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli")
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: file.path)
        #expect(throws: LlamaCppServerBinary.Refusal.unreadable(path: file.path, reason: "it cannot be opened")) {
            _ = try binary.check(file.path)
        }
    }

    @Test func eachRefusalSaysHowToApproveTheFileAgain() {
        let again = " approve the file now there with: wisp config set llamacpp.serverPath /h/llama-server"
        #expect(
            "\(LlamaCppServerBinary.Refusal.approvedOther(path: "/h/llama-server", approved: "/o/llama-server"))"
                == "/h/llama-server is not approved: the approval is for /o/llama-server, and llamacpp.serverPath was "
                + "changed without wisp config set;\(again)")
        #expect(
            "\(LlamaCppServerBinary.Refusal.moved(path: "/h/llama-server", approved: "/c/1/s", now: "/c/2/s"))"
                == "/h/llama-server now resolves to /c/2/s, not /c/1/s as approved (an upgrade moves it);\(again)")
        #expect(
            "\(LlamaCppServerBinary.Refusal.missing(path: "/h/llama-server", resolved: "/c/1/s"))"
                == "/h/llama-server resolves to /c/1/s, which is missing; install llama-server again or name another, "
                + "then\(again)")
        #expect(
            "\(LlamaCppServerBinary.Refusal.unreadable(path: "/h/llama-server", reason: "it cannot be opened"))"
                == "/h/llama-server cannot be read (it cannot be opened), so its digest cannot be checked")
        #expect(
            LlamaCppServerBinary.command("/Applications/My Tools/llama-server")
                == "wisp config set llamacpp.serverPath '/Applications/My Tools/llama-server'")
    }

    @Test func unsettingRemovesTheApproval() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try executable("llama-server")
        let home = try home()
        let binary = LlamaCppServerBinary(home: home)
        let sink = MemoryAuditSink()
        let audit = AuditLog(session: "s", sink: sink)
        _ = try binary.change(
            file.path, configFile: home.configFile, workingDirectory: root, audit: audit, source: "cli")
        let change = try binary.change(
            nil, configFile: home.configFile, workingDirectory: root, audit: audit, source: "cli")
        #expect(change.lines.first?.hasPrefix("the approval of \(file.path) (sha256 ") == true)
        #expect(try setting(home) == nil && !FileManager.default.fileExists(atPath: binary.file.path))
        #expect(sink.events.last { $0.kind == .llamaCppServerApprove }?.details["outcome"] == "revoked")
        #expect(
            try binary.change(nil, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli").lines
                == ["no llama-server was approved"])
    }

    @Test func theDoctorShowsTheBinaryUnderWispsServer() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try executable("llama-server")
        let home = try home()
        let off = Config().resolved.llamacpp
        #expect(Doctor.serverBinary(off, home: home) == nil)
        var settings = Config(llamacpp: .init(server: .wisp, serverPath: file.path)).resolved.llamacpp
        #expect(settings.serverPath == file.path)
        /// The finding with the binary as checked now, no agent, and nothing asked.
        func finding() throws -> Doctor.Finding {
            let router = Doctor.RouterState(
                binary: try #require(Doctor.serverBinary(settings, home: home)), agent: .manual("a test"),
                means: .manual("a test"), keyExists: false, log: LlamaCppRouter.log(home: home))
            return try #require(Doctor.llamaCppServer(settings, installed: nil, answer: nil, router: router))
        }
        let unapproved = try finding()
        #expect(!unapproved.ok)
        #expect(unapproved.detail.contains("wisp: llama-server: \(file.path) is not approved"), "\(unapproved.detail)")
        _ = try LlamaCppServerBinary(home: home).change(
            file.path, configFile: home.configFile, workingDirectory: root, audit: nil, source: "cli")
        let approved = try finding()
        #expect(
            approved.detail.contains("wisp: llama-server \(file.path) approved and unchanged"), "\(approved.detail)")
        settings.serverPath = nil
        #expect(try finding().detail.contains("no llama-server is approved"))
    }

    @Test func onlyThePersonApproves() throws {
        let policy = CommandPolicy()
        for command in [
            "wisp config set llamacpp.serverPath /tmp/x", "wisp config unset llamacpp.serverPath",
            "/opt/homebrew/bin/wisp 'config' set llamacpp.serverPath /tmp/x",
            "cd /tmp && wisp config set llamacpp.serverPath x",
        ] {
            #expect(policy.check(command) != .allowed, "\(command)")
        }
        #expect(policy.check("wisp config get llamacpp.serverPath") == .allowed)
        #expect(policy.check("wisp config set llamacpp.think false") == .allowed)
        // The setting is llama.cpp's alone, and a path set by hand loads but approves nothing.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wisp-serverpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        try Data(#"{"lmstudio":{"serverPath":"/x"}}"#.utf8).write(to: file)
        #expect(throws: DecodingError.self) { try Config.load(from: file) }
        try Data(#"{"llamacpp":{"serverPath":"/x"}}"#.utf8).write(to: file)
        #expect(try Config.load(from: file).resolved.llamacpp.serverPath == "/x")
        #expect(Config(lmstudio: .init(serverPath: "/x")).resolved.lmstudio.serverPath == nil)
        #expect(ConfigSettings.setting(LlamaCppServerBinary.setting)?.kind == .text)
        // A path with a space is quoted in the command that approves it.
        #expect(
            LlamaCppServerBinary.command("/Apps/My llama/llama-server")
                == "wisp config set llamacpp.serverPath '/Apps/My llama/llama-server'")
    }

    @Test func aSessionProtectsTheSupportFolder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = Home(root: root.appending(path: "a"))
        try inside.ensure()
        let session = try Session.begin(
            .init(entryPoint: .config, model: .system), home: inside, dependencies: .testing())
        #expect(session.config.runner.protectedPaths == [inside.root.path])
        session.end()
        let apart = Home(root: root.appending(path: "b"), support: root.appending(path: "support"))
        try apart.ensure()
        let other = try Session.begin(.init(entryPoint: .config, model: .system), home: apart, dependencies: .testing())
        #expect(other.config.runner.protectedPaths == [apart.root.path, apart.support.path])
        other.end()
    }
}

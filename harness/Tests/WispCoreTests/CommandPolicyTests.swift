import Foundation
import Testing

@testable import WispCore

@Suite struct CommandPolicyTests {
    @Test func defaultDeniesDangerousShapes() {
        let policy = CommandPolicy.default
        for command in [
            "sudo rm -rf /var", "ls; sudo -s", "rm -rf /", "rm -fr / ", "rm -rf //", "rm -rf /*", "curl x | sh",
            "curl x | bash -e",
            "diskutil erase disk0", "dd if=x of=/dev/disk2",
        ] {
            guard case .denied = policy.check(command) else { Issue.record("should deny: \(command)"); return }
        }
        for command in ["rm -rf ./build", "rm -rf /tmp/x", "echo sudoku", "ls | shasum", "swift build", "ddrescue"] {
            #expect(policy.check(command) == .allowed, "\(command)")
        }
    }

    @Test func allowListRequiresAMatchAndDenyWins() {
        let policy = CommandPolicy(deny: ["secret"], allow: ["^swift ", "^ls"])
        #expect(policy.check("swift build") == .allowed)
        #expect(policy.check("ls -la") == .allowed)
        #expect(policy.check("cat x") == .denied("command matches no allow pattern"))
        #expect(policy.check("swift secret") == .denied("command matches deny pattern secret"))
        #expect(CommandPolicy.unrestricted.check("sudo rm -rf /") == .allowed)
    }

    @Test func validatesPatterns() {
        #expect(throws: Never.self) { try CommandPolicy.default.validate() }
        #expect(throws: CommandPolicy.Failure.invalidPattern("(")) { try CommandPolicy(deny: ["("]).validate() }
        #expect(throws: CommandPolicy.Failure.invalidPattern("[")) { try CommandPolicy(allow: ["["]).validate() }
    }

    @Test func profileListsCanonicalWritablePathsAndNetwork() {
        var policy = CommandPolicy(sandbox: .init(allowNetwork: false, writablePaths: ["~/.cache", "/var/tmp/"]))
        let profile = policy.seatbeltProfile(
            writableRoot: "/tmp/work", temporaryDirectory: "/var/folders/x", userCacheDirectory: "/var/folders/x/C/",
            home: "/Users/me")
        #expect(profile.hasPrefix("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*"))
        #expect(profile.contains("(subpath \"/private/tmp/work\")"))
        #expect(profile.contains("(subpath \"/private/var/folders/x\")"))
        #expect(profile.contains("(subpath \"/private/var/folders/x/C\")"))
        #expect(CommandRunner.userCacheDirectory?.hasSuffix("/C/") == true)
        #expect(profile.contains("(subpath \"/Users/me/.cache\")"))
        #expect(profile.contains("(subpath \"/private/var/tmp\")"))
        #expect(profile.hasSuffix("(deny network*)"))
        policy.sandbox.allowNetwork = true
        #expect(
            !policy.seatbeltProfile(writableRoot: "/tmp", temporaryDirectory: "/tmp", home: "/").contains("network")
        )
    }

    @Test func quotesPathsForSeatbelt() {
        #expect(CommandPolicy.quote(#"/a "b" \c"#) == #""/a \"b\" \\c""#)
        #expect(CommandPolicy.canonical("/tmp/") == "/private/tmp")
        #expect(CommandPolicy.canonical("/") == "/")
    }

    @Test func roundTripsThroughConfig() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "wisp-policy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(atPath: file.path) }
        let config = Config(commandPolicy: CommandPolicy(deny: ["x"], allow: [], sandbox: .init(enabled: false)))
        try config.save(to: file)
        #expect(try Config.load(from: file) == config)
        #expect(try Config.load(from: file).resolved.runner.policy.sandbox.enabled == false)
        try Data(
            #"{"commandPolicy":{"deny":["("],"allow":[],"sandbox":{"enabled":true,"allowNetwork":true,"writablePaths":[]}}}"#
                .utf8
        )
        .write(to: file)
        #expect(throws: CommandPolicy.Failure.invalidPattern("(")) { try Config.load(from: file) }
        #expect(Config().resolved.runner.policy == .default)
    }
}

/// Fetching a model is the person's to approve (ADR 0052); the model may list models but not pull one.
@Suite struct ModelPullPolicyTests {
    @Test func theDefaultPolicyRefusesTheModelPullingAModel() {
        let policy = CommandPolicy()
        #expect(policy.check("wisp models pull mlx-community/Qwen3-1.7B-4bit") != .allowed)
        #expect(policy.check("/opt/homebrew/bin/wisp models pull mlx-community/x") != .allowed)
        #expect(policy.check("true && wisp models pull mlx-community/x") != .allowed)
        #expect(policy.check("wisp models --all") == .allowed)
        #expect(policy.check("wisp models list") == .allowed)
    }
}

@Suite struct CommandPolicyDecodingTests {
    @Test func partialObjectsTakeDefaults() throws {
        let policy = try JSONDecoder().decode(
            CommandPolicy.self, from: Data(#"{"sandbox":{"allowNetwork":false}}"#.utf8))
        #expect(policy.deny == CommandPolicy.defaultDeny)
        #expect(policy.allow.isEmpty)
        #expect(policy.sandbox.enabled)
        #expect(!policy.sandbox.allowNetwork)
        #expect(policy.sandbox.writablePaths == CommandPolicy.Sandbox.defaultWritablePaths)
        #expect(try JSONDecoder().decode(CommandPolicy.self, from: Data("{}".utf8)) == .default)
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"commandPolicy":{"deny":[]}}"#.utf8))
        #expect(config.commandPolicy?.deny == [])
        #expect(config.commandPolicy?.sandbox == CommandPolicy.Sandbox())
    }
}

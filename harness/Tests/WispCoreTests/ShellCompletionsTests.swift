import Foundation
import Testing

@testable import WispCore

/// The embedded completion scripts, where `wisp completions install` puts them, how it treats a file already
/// there, and the dynamic completions' candidates.
@Suite struct ShellCompletionsTests {
    /// The committed script for `shell`, as `scripts/check completions` wrote it.
    static func file(_ shell: ShellCompletions.Shell) -> URL {
        let name =
            switch shell {
            case .zsh: "_wisp"
            case .bash: "wisp.bash"
            case .fish: "wisp.fish"
            }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WispCore/Resources/completions/\(name)")
    }

    /// A fresh directory under the temporary directory, standing in for a home.
    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wisp-completions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Each embedded script is its file, byte for byte once print adds the newline back, so editing (or
    /// regenerating) the file is changing what wisp prints.
    @Test(arguments: ShellCompletions.Shell.allCases)
    func embeddedScriptIsTheFile(_ shell: ShellCompletions.Shell) throws {
        let onDisk = try String(contentsOf: Self.file(shell), encoding: .utf8)
        #expect(ShellCompletions.script(shell) + "\n" == onDisk)
        #expect(ShellCompletions.script(shell).contains("wisp"))
    }

    /// Every script carries the marker near its top, and zsh's still starts with #compdef, which compinit needs.
    @Test(arguments: ShellCompletions.Shell.allCases)
    func everyScriptCarriesTheMarker(_ shell: ShellCompletions.Shell) {
        let script = ShellCompletions.script(shell)
        #expect(ShellCompletions.isOwn(script))
        if shell == .zsh { #expect(script.hasPrefix("#compdef wisp\n")) }
        if shell == .bash { #expect(script.hasPrefix("#!/bin/bash\n")) }
    }

    /// The marker counts only near the top, so a script that merely mentions it lower down is not wisp's.
    @Test func markerMustBeNearTheTop() {
        #expect(ShellCompletions.isOwn("#compdef wisp\n\(ShellCompletions.markerPrefix) x\n"))
        #expect(!ShellCompletions.isOwn("# my completions\n"))
        let late = String(repeating: "line\n", count: 10) + ShellCompletions.markerPrefix
        #expect(!ShellCompletions.isOwn(late))
    }

    /// The shell comes from $SHELL's last component; anything else is refused with a message naming the choices.
    @Test func detectsTheShellFromItsPath() {
        #expect(ShellCompletions.detect(shellPath: "/bin/zsh") == .zsh)
        #expect(ShellCompletions.detect(shellPath: "/opt/homebrew/bin/bash") == .bash)
        #expect(ShellCompletions.detect(shellPath: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellCompletions.detect(shellPath: "/bin/tcsh") == nil)
        #expect(ShellCompletions.detect(shellPath: "") == nil)
        #expect(ShellCompletions.detect(shellPath: nil) == nil)
        #expect(ShellCompletions.Shell(rawValue: "powershell") == nil)
        #expect("\(ShellCompletions.Failure.unknownShell("/bin/tcsh"))".contains("zsh|bash|fish"))
    }

    /// Each shell's per-user location, with the XDG and bash-completion variables honoured when absolute.
    @Test func installLocations() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        func path(_ shell: ShellCompletions.Shell, _ environment: [String: String] = [:]) -> String {
            ShellCompletions.installURL(shell, environment: environment, home: home).path
        }
        #expect(path(.zsh) == "/Users/someone/.zsh/completions/_wisp")
        #expect(path(.zsh, ["XDG_DATA_HOME": "/x"]) == "/Users/someone/.zsh/completions/_wisp")
        #expect(path(.bash) == "/Users/someone/.local/share/bash-completion/completions/wisp")
        #expect(path(.bash, ["XDG_DATA_HOME": "/data"]) == "/data/bash-completion/completions/wisp")
        #expect(
            path(.bash, ["XDG_DATA_HOME": "relative"]) == "/Users/someone/.local/share/bash-completion/completions/wisp"
        )
        #expect(
            path(.bash, ["BASH_COMPLETION_USER_DIR": "/mine:/other", "XDG_DATA_HOME": "/data"])
                == "/mine/completions/wisp")
        #expect(path(.fish) == "/Users/someone/.config/fish/completions/wisp.fish")
        #expect(path(.fish, ["XDG_CONFIG_HOME": "/conf"]) == "/conf/fish/completions/wisp.fish")
        #expect(path(.fish, ["XDG_CONFIG_HOME": ""]) == "/Users/someone/.config/fish/completions/wisp.fish")
        #expect(ShellCompletions.home(environment: ["HOME": "/Users/x"]).path == "/Users/x")
    }

    /// Installing creates the directories, writes the script, and leaves a current one alone.
    @Test(arguments: ShellCompletions.Shell.allCases)
    func installWritesAndCreatesDirectories(_ shell: ShellCompletions.Shell) throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = ShellCompletions.installURL(shell, environment: [:], home: home)
        #expect(try ShellCompletions.install(shell, at: url) == .written)
        #expect(try String(contentsOf: url, encoding: .utf8) == ShellCompletions.script(shell) + "\n")
        #expect(try ShellCompletions.install(shell, at: url) == .unchanged)
    }

    /// An older wisp script is replaced; a file of the person's, or a directory, is refused and left as it was.
    @Test func overwritesOnlyItsOwnFile() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = ShellCompletions.installURL(.fish, environment: [:], home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(ShellCompletions.markerPrefix) an older wisp\ncomplete -c wisp\n".utf8).write(to: url)
        #expect(try ShellCompletions.install(.fish, at: url) == .replaced)
        #expect(try String(contentsOf: url, encoding: .utf8) == ShellCompletions.script(.fish) + "\n")

        let mine = "# my own wisp completions\ncomplete -c wisp -f\n"
        try Data(mine.utf8).write(to: url)
        #expect(throws: ShellCompletions.Failure.foreign(path: url.path)) {
            try ShellCompletions.install(.fish, at: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == mine)

        let zsh = ShellCompletions.installURL(.zsh, environment: [:], home: home)
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        #expect(throws: ShellCompletions.Failure.foreign(path: zsh.path)) {
            try ShellCompletions.install(.zsh, at: zsh)
        }
    }

    /// A symlink to wisp's own script (a dotfiles manager's) stays a link: the script is written through it. A link
    /// to someone else's file, or to nothing, is refused and left as it was.
    @Test func writesThroughALinkToItsOwnFileAndKeepsTheLink() throws {
        let home = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        let url = ShellCompletions.installURL(.fish, environment: [:], home: home)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dotfiles = home.appending(path: "dotfiles")
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appending(path: "wisp.fish")
        try Data("\(ShellCompletions.markerPrefix) an older wisp\ncomplete -c wisp\n".utf8).write(to: target)
        try manager.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(try ShellCompletions.install(.fish, at: url) == .replaced)
        #expect(try manager.destinationOfSymbolicLink(atPath: url.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == ShellCompletions.script(.fish) + "\n")
        #expect(try ShellCompletions.install(.fish, at: url) == .unchanged)

        let mine = "# my own\n"
        try Data(mine.utf8).write(to: target)
        #expect(throws: ShellCompletions.Failure.foreign(path: url.path)) {
            try ShellCompletions.install(.fish, at: url)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == mine)

        try manager.removeItem(at: target)
        #expect(throws: ShellCompletions.Failure.foreign(path: url.path)) {
            try ShellCompletions.install(.fish, at: url)
        }
        #expect(!manager.fileExists(atPath: target.path))
    }

    /// Only an unknown shell is a usage error; a file in the way or a path that cannot be written is a runtime
    /// failure, which the command exits 1 for.
    @Test func onlyAnUnknownShellIsAUsageError() throws {
        #expect(ShellCompletions.Failure.unknownShell(nil).isUsage)
        #expect(!ShellCompletions.Failure.foreign(path: "/x").isUsage)
        #expect(!ShellCompletions.Failure.unwritable(path: "/x", reason: "r").isUsage)
        let home = try Self.scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        let url = ShellCompletions.installURL(.zsh, environment: [:], home: home)
        #expect {
            try ShellCompletions.install(.zsh, at: url)
        } throws: { error in
            guard let failure = error as? ShellCompletions.Failure, case .unwritable = failure else { return false }
            return !failure.isUsage
        }
    }

    /// What to do next: zsh's fpath lines unless FPATH shows the directory, bash-completion or a source line, and
    /// nothing to do for fish.
    @Test func activationAdvice() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let zsh = ShellCompletions.installURL(.zsh, environment: [:], home: home)
        let advice = ShellCompletions.activation(.zsh, at: zsh, environment: [:], home: home)
        #expect(advice.contains("  fpath+=(~/.zsh/completions)"))
        #expect(advice.contains("  autoload -U compinit; compinit"))
        let onPath = ShellCompletions.activation(
            .zsh, at: zsh, environment: ["FPATH": "/usr/share/zsh/functions:/Users/someone/.zsh/completions"],
            home: home)
        #expect(onPath.count == 1)
        #expect(!onPath.joined().contains("fpath+="))
        let bash = ShellCompletions.installURL(.bash, environment: [:], home: home)
        #expect(
            ShellCompletions.activation(.bash, at: bash, environment: [:], home: home).last
                == "Without bash-completion, add to ~/.bashrc: source ~/.local/share/bash-completion/completions/wisp")
        let fish = ShellCompletions.installURL(.fish, environment: [:], home: home)
        #expect(ShellCompletions.activation(.fish, at: fish, environment: [:], home: home).count == 1)
        #expect(ShellCompletions.tilde("/Users/someone2/x", home: home) == "/Users/someone2/x")
        #expect(ShellCompletions.tilde("/Users/someone", home: home) == "~")
    }

    /// The shells themselves accept the scripts: zsh -n and bash -n, and fish -n where fish is installed.
    @Test(arguments: ShellCompletions.Shell.allCases)
    func shellParsesTheScript(_ shell: ShellCompletions.Shell) throws {
        let candidates =
            switch shell {
            case .zsh: ["/bin/zsh"]
            case .bash: ["/bin/bash"]
            case .fish: ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = ["-n", Self.file(shell).path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(message)")
    }

    /// The candidates come from local state only: Apple's models and the default, tools, settings, and the ids
    /// waiting in the home.
    @Test func candidates() async throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = Home(root: root)
        #expect(CompletionCandidates.models(config: nil) == ["system", "private-cloud"])
        var config = Config().resolved
        config.model = .local(backend: "ollama", name: "granite4.1:8b")
        config.disabledModels = [.local(backend: "mlx", name: "small")]
        #expect(CompletionCandidates.models(config: config) == ["system", "private-cloud", "ollama:granite4.1:8b"])
        #expect(CompletionCandidates.disabledModels(config: config) == ["mlx:small"])
        #expect(CompletionCandidates.disabledModels(config: nil).isEmpty)
        #expect(CompletionCandidates.tools(config: nil) == ToolRegistry.builtInNames)
        #expect(CompletionCandidates.settings(home: home) == ConfigSettings.all.map(\.path))

        #expect(await CompletionCandidates.approvals(home: home).isEmpty)
        let entry = try await ApprovalStore(url: home.approvalsFile)
            .grant(pattern: "git push *", directory: "/tmp", scope: .always, level: .moderate, source: "test")
        #expect(await CompletionCandidates.approvals(home: home) == [entry.id])

        #expect(CompletionCandidates.pending(.fact, home: home).isEmpty)
        let channel = PendingApprovals(home: home)
        try channel.ensureDirectory()
        let request = PendingApprovals.request(
            keeping: .init(id: "c1", subject: "entity", name: "repo", value: "wisp", source: "test"), thread: "t",
            client: nil, timeout: nil)
        try channel.file(request)
        #expect(CompletionCandidates.pending(.fact, home: home) == [request.id])
        #expect(CompletionCandidates.pending(.command, home: home).isEmpty)
    }
}

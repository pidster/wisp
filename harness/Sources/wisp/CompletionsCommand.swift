import ArgumentParser
import Foundation
import WispCore

/// `wisp completions`: the shell completion scripts the binary embeds, printed or installed for the person's
/// shell (`ShellCompletions`). Neither reads nor writes `~/.wisp`, so Homebrew can run it at install time.
struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Print or install wisp's shell completions for zsh, bash, or fish.",
        discussion:
            "'wisp completions zsh' prints the script, for source <(wisp completions zsh) or a file of your choice; "
            + "'wisp completions install' writes it where the shell looks for it (the shell from $SHELL unless "
            + "named) and says how to turn it on. Install replaces only a file wisp wrote. Homebrew installs the "
            + "scripts with wisp.",
        subcommands: [PrintScript.self, Install.self],
        defaultSubcommand: PrintScript.self)

    /// Prints one shell's script.
    struct PrintScript: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "print", abstract: "Print the completion script for a shell (the default).")

        @Argument(help: "zsh, bash, or fish.")
        var shell: ShellCompletions.Shell

        func run() {
            print(ShellCompletions.script(shell))
        }
    }

    /// Writes one shell's script to its per-user location.
    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install the completion script where your shell looks for it.",
            discussion:
                "zsh: ~/.zsh/completions/_wisp. bash: bash-completion's user directory, "
                + "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-~/.local/share}/bash-completion}/completions/wisp. "
                + "fish: ${XDG_CONFIG_HOME:-~/.config}/fish/completions/wisp.fish. Directories are created; a file "
                + "already there is replaced only when wisp wrote it. Shell start-up files are never edited.")

        @Argument(help: "zsh, bash, or fish; the shell $SHELL names when omitted.")
        var shell: ShellCompletions.Shell?

        @Flag(name: .customLong("print-path"), help: "Print where the script would go, and write nothing.")
        var printPath = false

        func run() throws {
            let environment = ProcessInfo.processInfo.environment
            guard let shell = shell ?? ShellCompletions.detect(shellPath: environment["SHELL"]) else {
                throw ValidationError("\(ShellCompletions.Failure.unknownShell(environment["SHELL"]))")
            }
            let home = ShellCompletions.home(environment: environment)
            let url = ShellCompletions.installURL(shell, environment: environment, home: home)
            if printPath {
                print(url.path)
                return
            }
            let outcome: ShellCompletions.Outcome
            do {
                outcome = try ShellCompletions.install(shell, at: url)
            } catch let failure as ShellCompletions.Failure {
                guard !failure.isUsage else { throw ValidationError("\(failure)") }
                // A file in the way or an unwritable path is not a usage mistake: say why, without the usage text.
                FileHandle.standardError.write(Data("Error: \(failure)\n".utf8))
                throw ExitCode.failure
            }
            switch outcome {
            case .written: print("wrote the \(shell) completions to \(url.path)")
            case .replaced: print("replaced the \(shell) completions at \(url.path)")
            case .unchanged: print("the \(shell) completions at \(url.path) are already current")
            }
            for line in ShellCompletions.activation(shell, at: url, environment: environment, home: home) {
                print(line)
            }
        }
    }
}

extension ShellCompletions.Shell: ExpressibleByArgument {}

/// The dynamic completions wisp's arguments offer, each read from files under `~/.wisp` when the shell asks
/// (`CompletionCandidates`): nothing here reaches the network or a model.
enum DynamicCompletions {
    /// The configuration, or nil when it does not load (completion then offers what needs none).
    static var config: Config.Resolved? { try? Session.loadConfig(home: Wisp.home) }

    /// `--model`.
    static let models = CompletionKind.custom { _, _, _ in CompletionCandidates.models(config: config) }
    /// `wisp models enable`.
    static let disabledModels = CompletionKind.custom { _, _, _ in
        CompletionCandidates.disabledModels(config: config)
    }
    /// `--tool`.
    static let tools = CompletionKind.custom { _, _, _ in CompletionCandidates.tools(config: config) }
    /// `wisp config get|set|unset`.
    static let settings = CompletionKind.custom { _, _, _ in CompletionCandidates.settings(home: Wisp.home) }
    /// `wisp approvals revoke`.
    static let approvals = CompletionKind.custom { _, _, _ in await CompletionCandidates.approvals(home: Wisp.home) }
    /// `wisp approvals approve|deny`.
    static let pendingCommands = CompletionKind.custom { _, _, _ in
        CompletionCandidates.pending(.command, home: Wisp.home)
    }
    /// `wisp facts keep|drop`.
    static let pendingFacts = CompletionKind.custom { _, _, _ in CompletionCandidates.pending(.fact, home: Wisp.home) }
}

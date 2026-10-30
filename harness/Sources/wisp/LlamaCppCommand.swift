import ArgumentParser
import Darwin
import Foundation
import WispCore

/// `wisp llamacpp`: what wisp's own llama.cpp server's LaunchAgent runs
/// ([ADR 0082](../../../docs/decisions/0082-a-llama-cpp-server-wisp-starts.md), decision 4). Internal, and left out of
/// `--help`: the person turns the server on and off with `wisp config set llamacpp.server`.
struct LlamaCppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "llamacpp", abstract: "wisp's own llama.cpp server (internal; run by its LaunchAgent).",
        shouldDisplay: false, subcommands: [Serve.self, Agent.self])

    /// Checks everything and replaces this process with the approved `llama-server`.
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start wisp's own llama.cpp server in this process's place (its LaunchAgent runs this).",
            discussion:
                "Refuses unless llamacpp.server is wisp and the llama-server at llamacpp.serverPath is the one you "
                + "approved; makes the key file once; then runs llama-server as a router over the models wisp models "
                + "add linked, on 127.0.0.1 with the key, its output going to llamacpp.log in ~/Library/Logs/Wisp.",
            shouldDisplay: false)

        /// The exit status of a refusal: 0, a clean exit, so launchd, which starts the server again after any other
        /// exit (`KeepAlive` `SuccessfulExit` false), does not start it again until the person changes something. The
        /// refusal is in the log, the audit, and `wisp doctor`.
        static let refused: Int32 = 0

        func run() throws {
            let session = try Wisp.begin(.init(entryPoint: .llamacpp))
            let log = LlamaCppRouter.log(home: Wisp.home)
            let launch: LlamaCppRouter.Launch
            let descriptor: Int32
            do {
                launch = try LlamaCppRouter.prepare(session.config.llamacpp, home: Wisp.home, audit: session.audit)
                descriptor = try LlamaCppRouter.openLog(log)
            } catch {
                session.end()
                Wisp.note("Error: \(error)")
                // launchd keeps no output of its own, so the refusal goes to the server's log as well.
                if let descriptor = try? LlamaCppRouter.openLog(log) {
                    let line = Array("\(Date().formatted(.iso8601)) wisp llamacpp serve: refused: \(error)\n".utf8)
                    _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                    close(descriptor)
                }
                throw ExitCode(Self.refused)
            }
            session.end()
            let started = Date().formatted(.iso8601)
            Wisp.note(
                "wisp llamacpp serve: starting \(launch.executable.path) on 127.0.0.1:\(launch.settings.port) "
                    + "(\(launch.settings.summary)); its output goes to \(log.path)")
            // The log takes standard output and error, for wisp's line and then llama-server's own.
            dup2(descriptor, STDOUT_FILENO)
            dup2(descriptor, STDERR_FILENO)
            close(descriptor)
            Wisp.note(
                "\(started) wisp llamacpp serve: \(launch.executable.path) \(launch.arguments.joined(separator: " "))")
            Self.exec(launch)
        }

        /// Replaces this process with the launch, so launchd supervises `llama-server` itself; returns only when that
        /// fails, which is said and exits as a refusal.
        ///
        /// - Parameter launch: What to run.
        static func exec(_ launch: LlamaCppRouter.Launch) -> Never {
            let arguments = [launch.executable.path] + launch.arguments
            let environment = LlamaCppRouter.environment(ProcessInfo.processInfo.environment)
            let argv = arguments.map { strdup($0) } + [nil]
            let envp = environment.map { strdup($0) } + [nil]
            // A new program keeps the calling thread's signal mask and every ignored signal. This runs on a thread of
            // Swift's concurrency pool, which blocks signals, and before this was cleared llama-server ignored the
            // SIGTERM launchd stops it with (probed 2026-10-30): every signal is unblocked and set to its default.
            var none = sigset_t()
            sigemptyset(&none)
            pthread_sigmask(SIG_SETMASK, &none, nil)
            for number in 1..<NSIG where number != SIGKILL && number != SIGSTOP { signal(number, SIG_DFL) }
            execve(launch.executable.path, argv, envp)
            Wisp.note("Error: \(launch.executable.path) could not be started: \(String(cString: strerror(errno)))")
            Darwin.exit(refused)
        }
    }

    /// `SMAppService` calls made by `Wisp.app`'s own `wisp`, where the main bundle is the app: what a `wisp` started
    /// through a link asks it to do.
    struct Agent: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Register, unregister, or read Wisp.app's Login Item for the server (internal).",
            shouldDisplay: false)

        @Argument(help: "register, unregister, or status.")
        var verb: String

        func run() throws {
            do {
                print(try LlamaCppAgent.loginItem(verb))
            } catch {
                Wisp.note("Error: \(error)")
                throw ExitCode.failure
            }
        }
    }
}

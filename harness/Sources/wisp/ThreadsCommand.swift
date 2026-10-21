import ArgumentParser
import Darwin
import Foundation
import WispCore

/// `wisp threads`: the thread store for the person ([ADR 0066](../../../docs/decisions/0066-one-thread-store.md),
/// phase 3). `list` and `show` read; `delete` and `hand` change what an agent may open, so they run only from a
/// terminal, and the default command policy refuses them to wisp's model.
struct ThreadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads",
        abstract: "List, show, delete, and hand over saved threads.",
        discussion:
            "Every thread, chat's and an MCP agent's, is saved in ~/.wisp/threads after each turn and resumed by "
            + "any face (wisp chat --resume ID, or an agent naming its thread_id). 'list' shows them, 'show' one in "
            + "full. 'delete' removes one with its stored outputs, and 'hand' gives one to another client, so that "
            + "client's agent may resume it; both are refused while a process holds the thread, and run only from a "
            + "terminal.",
        subcommands: [List.self, Show.self, Delete.self, Hand.self],
        defaultSubcommand: List.self)

    /// Lists every saved thread.
    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the saved threads, most recently used first.")

        @Flag(name: .long, help: "Print the threads as JSON.")
        var json = false

        func run() async throws {
            let admin = ThreadAdmin(home: Wisp.home)
            if json {
                try ThreadsCommand.printJSON(["threads": admin.list])
                return
            }
            let transcripts = TranscriptStore(directory: Wisp.home.transcripts)
            for line in ChatThread.listing(store: admin.store, transcripts: transcripts, current: nil) { print(line) }
        }
    }

    /// Shows one thread in full.
    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a thread's settings, turns, sessions, size on disk, and when it is swept.")

        @Argument(help: "The thread's id, as 'wisp threads' lists it.", completion: DynamicCompletions.threads)
        var id: String

        @Flag(name: .long, help: "Print the thread as JSON.")
        var json = false

        func run() async throws {
            let keepDays = ThreadsCommand.keepDays
            let details = try ThreadsCommand.attempt { try ThreadAdmin(home: Wisp.home).show(id, keepDays: keepDays) }
            if json {
                try ThreadsCommand.printJSON(details)
            } else {
                for line in ThreadAdmin.lines(details, keepDays: keepDays) { print(line) }
            }
        }
    }

    /// Deletes one thread with its stored outputs.
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a saved thread and its stored outputs, from a terminal.",
            discussion:
                "Refused while a process holds the thread. Its history stays in the audit log. Asks first unless "
                + "--yes.")

        @Argument(help: "The thread's id, as 'wisp threads' lists it.", completion: DynamicCompletions.threads)
        var id: String

        @Flag(name: [.short, .long], help: "Delete it without asking.")
        var yes = false

        @Flag(name: .long, help: "Print what was deleted as JSON.")
        var json = false

        func run() async throws {
            try ThreadsCommand.requireTerminal("delete")
            let admin = ThreadAdmin(home: Wisp.home)
            if !yes {
                let described =
                    (try? admin.store.settings(id)).flatMap { $0 }.map {
                        "\($0.owner)'s, \($0.turns) turn\($0.turns == 1 ? "" : "s"), model \($0.model)"
                    } ?? "its settings cannot be read"
                Wisp.note("Delete thread \(id) (\(described)) and its stored outputs? [y/N]")
                let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    print("left as it was")
                    return
                }
            }
            let session = try Wisp.begin(.init(entryPoint: .threads))
            defer { session.end() }
            let deleted = try ThreadsCommand.attempt { try admin.delete(id) }
            session.audit.record(.threadDeleted, details: deleted.details)
            if json {
                try ThreadsCommand.printJSON(deleted.details)
            } else {
                print(
                    "deleted thread \(id)"
                        + (deleted.outputSessions.isEmpty
                            ? "" : " and its stored outputs (\(ThreadAdmin.bytes(deleted.outputBytes)))"))
            }
        }
    }

    /// Gives one thread to another client.
    struct Hand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give a saved thread to another client, so its agent may resume it, from a terminal.",
            discussion:
                "CLIENT is the client's name as wisp mcp sees it (its clientInfo.name: claude-code, codex), or chat. "
                + "The thread keeps its record and settings. Refused while a process holds it.")

        @Argument(help: "The thread's id, as 'wisp threads' lists it.", completion: DynamicCompletions.threads)
        var id: String

        @Argument(help: "The client to give it to.")
        var client: String

        @Flag(name: .long, help: "Print the change as JSON.")
        var json = false

        func run() async throws {
            try ThreadsCommand.requireTerminal("hand")
            let admin = ThreadAdmin(home: Wisp.home)
            let session = try Wisp.begin(.init(entryPoint: .threads))
            defer { session.end() }
            guard let handed = try ThreadsCommand.attempt({ try admin.hand(id, to: client) }) else {
                if json {
                    try ThreadsCommand.printJSON(["thread": id, "from": client, "to": client])
                } else {
                    print("thread \(id) is \(client)'s already")
                }
                return
            }
            session.audit.record(.threadHanded, details: handed.details)
            if json {
                try ThreadsCommand.printJSON(handed.details)
            } else {
                print("thread \(id) is \(client)'s now (it was \(handed.from)'s)")
            }
        }
    }

    /// `threads.keepDays`, or its default when the configuration does not load.
    static var keepDays: Int {
        (try? Session.loadConfig(home: Wisp.home))?.threadsKeepDays ?? Config.ThreadsConfig.defaultKeepDays
    }

    /// Refuses `delete` and `hand` without a terminal: an agent's shell has none, and these change what an agent may
    /// open (ADR 0046's rule, as `wisp approvals approve` has it).
    ///
    /// - Parameter verb: The subcommand.
    /// - Throws: A validation error when standard input is not a terminal.
    static func requireTerminal(_ verb: String) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw ValidationError(
                "wisp threads \(verb) changes what an agent may open, so it runs only from a terminal")
        }
    }

    /// Runs `operation`, printing a thread store refusal to stderr and exiting with failure.
    ///
    /// - Parameter operation: The work.
    /// - Returns: Its result.
    /// - Throws: `ExitCode.failure` when it fails.
    static func attempt<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch {
            Wisp.note("\(error)")
            throw ExitCode.failure
        }
    }

    /// Prints `value` as JSON with sorted keys and ISO 8601 dates.
    ///
    /// - Parameter value: The value.
    /// - Throws: Encoding errors.
    static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

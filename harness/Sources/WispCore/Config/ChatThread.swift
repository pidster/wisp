import Foundation
import FoundationModels
import Synchronization

/// A chat's thread in the thread store ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md), D2, D11):
/// what `ChatLoop` saves after every turn, holding the thread's lock while the chat has it open, so an MCP agent that
/// names it is refused and told why.
///
/// A chat starts a thread with a generated id, `chat-<8 characters>`, owned by `chat`; `/save NAME` renames it, and
/// `/new` saves it and starts another. `wisp chat --resume ID` opens any thread in the store, an agent's included
/// (the person may open any, D3), and falls back to a transcript in `~/.wisp/transcripts`, which it saves into the
/// store under its name, leaving the transcript where it is. An agent's thread keeps its owner and its start
/// settings: chat runs it with them, and saves only its record, its turns, and when it was used, so the agent
/// resumes it as it left it.
///
/// A `final class` with a `Mutex`: every operation is a short synchronous critical section.
public final class ChatThread: Sendable {
    /// The owner of a thread a chat starts.
    public static let owner = "chat"

    /// Why a thread could not be opened, renamed, or started.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Neither the store nor `~/.wisp/transcripts` has a thread of this name.
        case notFound(String)
        /// A thread of this name is already saved.
        case taken(String)
        /// The thread is an agent's, whose id its agent names it by: it cannot be renamed from chat.
        case agents(String, owner: String)
        /// Settings given for an agent's thread differ from those it was saved with: its id, the saved settings
        /// described, and the names that differ.
        case settings(String, String, differing: [String])

        /// Human-readable explanation.
        public var description: String {
            switch self {
            case .notFound(let name):
                "no saved thread or transcript named '\(name)'; wisp chat --list and /threads list them"
            case .taken(let name): "a thread named '\(name)' is already saved; choose another name"
            case .agents(let id, let owner):
                "thread \(id) is \(owner)'s, which names it by that id, so it keeps it; /new starts a thread of your "
                    + "own"
            case .settings(let id, let described, let differing):
                "thread \(id) is an agent's, saved with \(described); these settings differ: "
                    + "\(differing.joined(separator: ", ")). Leave them out to open it with its own"
            }
        }
    }

    /// A thread about to be opened in chat, locked for this process: a new one, one saved in the store, or a transcript
    /// from `~/.wisp/transcripts`. Taken before the session starts, so its `session.start` can name what it resumes and
    /// no other wisp opens it meanwhile.
    public struct Opening: Sendable {
        /// The id it is saved under in the store.
        public let id: String
        /// Its lock, held from now until the chat lets it go.
        let lock: ThreadLock
        /// Its saved settings; nil for a new thread or a transcript.
        public let settings: ThreadStore.Settings?
        /// What is resumed: the record saved in the store or the transcript; nil for a new thread.
        public let saved: TranscriptStore.Saved?
        /// The transcript's name when it was found in `~/.wisp/transcripts`.
        public let legacy: String?

        /// Whether it is an agent's thread, whose settings hold in chat.
        public var isAgents: Bool { settings.map { $0.owner != ChatThread.owner } ?? false }

        /// Lets it go unopened, as a chat that could not start does: releases the lock, and deletes the directory the
        /// lock made when nothing is saved there.
        ///
        /// - Parameter store: The store it was taken in.
        public func abandon(in store: ThreadStore) {
            lock.release()
            if settings == nil, (try? store.settings(id)) == nil { try? store.delete(id) }
        }

        /// The audit sessions it had before, oldest first, for `session.start`'s `carriedFrom`.
        public var carriedFrom: [String] { settings?.sessions ?? saved?.links.sessions ?? [] }

        /// The tools an agent's thread was saved with, as a selection; nil for any other.
        public var tools: ToolSelection? {
            guard isAgents, let settings else { return nil }
            return settings.tools.isEmpty ? ToolSelection.none : .named(settings.tools)
        }

        /// The settings the person gave on the command line that differ from an agent's thread's: `model`, `tools`, and
        /// `instructions`, each only when given. Empty for any other thread, whose settings are the person's to change.
        ///
        /// - Parameters:
        ///   - model: `--model`, as given.
        ///   - tools: `--tool` or `--no-tools` as a selection; `.all` when neither was given.
        ///   - instructions: `--instructions`, as given.
        /// - Returns: The names that differ.
        public func differences(model: ModelSelection?, tools: ToolSelection, instructions: String?) -> [String] {
            guard isAgents, let settings else { return [] }
            var differing: [String] = []
            if let model, model.description != settings.model { differing.append("model") }
            if tools != .all, tools.resolved(or: []) != settings.tools { differing.append("tools") }
            if let instructions, instructions != settings.instructions { differing.append("instructions") }
            return differing
        }

        /// `request`, the person's flags, made the request that opens this thread: naming what it resumes and the
        /// sessions it had, and for an agent's thread with its own model, tools, and instructions, which hold in chat
        /// (D11). Flags that differ from an agent's thread's settings are refused, as a name to save it under is.
        ///
        /// - Parameters:
        ///   - request: The session request the flags describe.
        ///   - resume: The name `--resume` gave.
        ///   - save: The name `--save` gave.
        /// - Returns: The request.
        /// - Throws: `Failure.settings` or `agents`, or `ModelSelection.Failure` for a saved model that does not parse.
        public func applied(to request: Session.Request, resume: String?, save: String?) throws -> Session.Request {
            var request = request
            request.resume = resume
            request.carriedFrom = carriedFrom
            guard let settings, let tools else { return request }
            let differing = differences(model: request.model, tools: request.tools, instructions: request.instructions)
            guard differing.isEmpty else { throw Failure.settings(id, settings.described, differing: differing) }
            if let save, save != id { throw Failure.agents(id, owner: settings.owner) }
            request.model = try ModelSelection(parsing: settings.model)
            request.tools = tools
            request.instructions = settings.instructions
            return request
        }

        /// The line the chat shows first: an agent's thread with its settings, a resumed thread with its turns and when
        /// it was saved, a transcript with where it is now saved; nil for a new thread.
        ///
        /// - Parameter transcripts: The directory of transcripts, as shown.
        /// - Returns: The line, or nil.
        public func announcement(transcripts: String = "~/.wisp/transcripts") -> String? {
            if let settings, isAgents {
                var parts = [
                    settings.model,
                    settings.tools.isEmpty ? "no tools" : "tools " + settings.tools.joined(separator: ", "),
                ]
                if settings.instructions != nil { parts.append("instructions set") }
                if let think = settings.think { parts.append("think \(think)") }
                if let limit = settings.commandTimeoutSeconds { parts.append("commandTimeoutSeconds \(limit)") }
                return "\(id): \(parts.joined(separator: ", ")) (an agent's thread: \(settings.owner)'s, "
                    + "\(ChatThread.turns(settings.turns))); its settings hold here, and /new starts a thread of your "
                    + "own"
            }
            if let settings {
                return "resumed thread \(id) (\(ChatThread.turns(settings.turns)), saved "
                    + "\(ChatThread.shortTime(settings.lastUsed)))"
            }
            guard let legacy, let saved else { return nil }
            return "resumed '\(legacy)' from \(transcripts) (\(ChatThread.turns(saved.transcript.turnCount))), now "
                + "saved as thread \(id)"
        }
    }

    /// What one opening of the thread keeps.
    private struct State {
        /// `thread.json` as it stands.
        var settings: ThreadStore.Settings
        /// The lock on the thread's directory.
        var lock: ThreadLock
        /// Whether anything of it is in the store: false for a new thread until its first save.
        var written: Bool
    }

    /// The store.
    public let store: ThreadStore
    /// The transcripts saved by earlier wisps, listed by `/threads`; nil lists none.
    public let transcripts: TranscriptStore?
    /// The thread as it stands.
    private let state: Mutex<State>

    /// Opens `opening` for a chat whose audit session is `session`: an agent's thread keeps its settings; any other
    /// takes the chat's (the model, tools, instructions, and thinking it runs with), with its saved history.
    ///
    /// - Parameters:
    ///   - opening: The thread, locked.
    ///   - store: The store.
    ///   - transcripts: The transcripts `/threads` lists beside the store.
    ///   - session: The chat's audit session.
    ///   - model: The chat's model, as `ModelSelection` spells it.
    ///   - tools: The chat's tools.
    ///   - instructions: The chat's instructions.
    ///   - think: The chat's thinking, as text.
    ///   - now: The time.
    public init(
        _ opening: Opening, store: ThreadStore, transcripts: TranscriptStore?, session: String, model: String,
        tools: [String], instructions: String?, think: String?, now: Date = Date()
    ) {
        self.store = store
        self.transcripts = transcripts
        let settings = Self.settings(
            opening, session: session, model: model, tools: tools, instructions: instructions, think: think, now: now)
        state = Mutex(State(settings: settings, lock: opening.lock, written: opening.settings != nil))
    }

    /// The settings `opening` is held with: an agent's thread's own, reopened under `session`; a chat's own with the
    /// chat's model, tools, and thinking; a new thread's or a transcript's from the chat's.
    ///
    /// - Parameters:
    ///   - opening: The thread.
    ///   - session: The chat's audit session.
    ///   - model: The chat's model.
    ///   - tools: The chat's tools.
    ///   - instructions: The chat's instructions.
    ///   - think: The chat's thinking.
    ///   - now: The time.
    /// - Returns: The settings.
    private static func settings(
        _ opening: Opening, session: String, model: String, tools: [String], instructions: String?, think: String?,
        now: Date
    ) -> ThreadStore.Settings {
        var settings =
            opening.settings?.reopened(as: session)
            ?? ThreadStore.Settings(
                id: opening.id, owner: owner, model: model, tools: tools, instructions: instructions, think: think,
                session: session, now: now)
        if opening.settings?.owner == owner {
            settings.model = model
            settings.tools = tools
            settings.think = think
        }
        if opening.settings == nil, let saved = opening.saved { settings.turns = saved.transcript.turnCount }
        return settings
    }

    /// The thread's id.
    public var id: String { state.withLock { $0.settings.id } }

    /// `thread.json` as it stands.
    public var settings: ThreadStore.Settings { state.withLock { $0.settings } }

    /// Whether it is an agent's thread, whose settings hold in chat.
    public var isAgents: Bool { settings.owner != Self.owner }

    /// A new id for a chat's thread, `chat-<8 characters>`, not saved in `store`.
    ///
    /// - Parameter store: The store.
    /// - Returns: The id.
    static func newID(in store: ThreadStore) -> String {
        var id = "chat-" + ShortID.make()
        while (try? store.settings(id)) != nil { id = "chat-" + ShortID.make() }
        return id
    }

    /// A new thread for a chat, locked: under `name` when given, which must be a valid id no thread has, or a generated
    /// `chat-<8 characters>`.
    ///
    /// - Parameters:
    ///   - name: The id to start it under; nil generates one.
    ///   - store: The store.
    /// - Returns: The opening.
    /// - Throws: `ThreadStore.Failure.invalidID` or `held`, or `Failure.taken`.
    public static func reserve(_ name: String? = nil, store: ThreadStore) throws -> Opening {
        let id = name ?? newID(in: store)
        let lock = try store.lock(id, owner: owner)
        do {
            guard try store.settings(id) == nil else { throw Failure.taken(id) }
        } catch {
            lock.release()
            throw error
        }
        return Opening(id: id, lock: lock, settings: nil, saved: nil, legacy: nil)
    }

    /// The thread named `name`, locked: from the store first, any owner's, then from `transcripts`, saved by an earlier
    /// wisp. A transcript whose name cannot be an id in the store (longer than 48 characters, or starting with a dot)
    /// is saved under a generated one.
    ///
    /// - Parameters:
    ///   - name: The thread's id, or the transcript's name.
    ///   - store: The store.
    ///   - transcripts: The transcripts; nil looks only in the store.
    /// - Returns: The opening.
    /// - Throws: `ThreadStore.Failure` (unreadable, version, record, or `held`, saying who holds it),
    ///   `TranscriptStore.Failure` for a transcript that cannot be resumed, or `Failure.notFound`.
    public static func find(_ name: String, store: ThreadStore, transcripts: TranscriptStore?) throws -> Opening {
        if ThreadStore.isValid(name), try store.settings(name) != nil {
            let lock = try store.lock(name, owner: owner)
            do {
                guard let saved = try store.load(name) else { throw Failure.notFound(name) }
                return Opening(
                    id: name, lock: lock, settings: saved.settings,
                    saved: TranscriptStore.Saved(transcript: saved.transcript, links: saved.links), legacy: nil)
            } catch {
                lock.release()
                throw error
            }
        }
        guard let transcripts else { throw Failure.notFound(name) }
        let saved: TranscriptStore.Saved
        do {
            saved = try transcripts.loadThread(name)
        } catch TranscriptStore.Failure.notFound, TranscriptStore.Failure.invalidName {
            throw Failure.notFound(name)
        }
        let id = ThreadStore.isValid(name) ? name : newID(in: store)
        let lock = try store.lock(id, owner: owner)
        return Opening(id: id, lock: lock, settings: nil, saved: saved, legacy: name)
    }

    /// Saves the thread: its record, and `thread.json` with the turns, the time, and `state`. A chat's own thread takes
    /// the model and thinking it runs with now (`/model`, `/think`); an agent's keeps those it was saved with.
    ///
    /// - Parameters:
    ///   - record: The conversation's store.
    ///   - turn: Whether a turn has just ended, which it counts.
    ///   - model: The model the chat runs on now.
    ///   - think: The thinking it asks for now, as text.
    ///   - state: `open` while the chat has it, `saved` when it lets it go.
    ///   - now: The time.
    /// - Throws: File-system and encoding errors.
    public func save(
        record: ThreadRecord, turn: Bool = false, model: String, think: String?, state: ThreadStore.State = .open,
        now: Date = Date()
    ) throws {
        let settings = self.state.withLock { current in
            if turn { current.settings.turns += 1 }
            if current.settings.owner == Self.owner {
                current.settings.model = model
                current.settings.think = think
            }
            current.settings.lastUsed = now
            current.settings.state = state
            current.written = true
            return current.settings
        }
        try store.save(settings, record: record)
    }

    /// Renames the thread to `name` (`/save NAME`): saves it under the new id, deletes it under the old, and moves the
    /// lock across. Refused for an agent's thread, whose agent names it by its id, for a name that cannot be an id, and
    /// for one a thread already has.
    ///
    /// - Parameters:
    ///   - name: The new id.
    ///   - record: The conversation's store.
    ///   - model: The model the chat runs on now.
    ///   - think: The thinking it asks for now.
    /// - Throws: `Failure.agents` or `taken`, `ThreadStore.Failure.invalidID` or `held`, or file-system errors.
    public func rename(to name: String, record: ThreadRecord, model: String, think: String?) throws {
        let current = settings
        guard current.owner == Self.owner else { throw Failure.agents(current.id, owner: current.owner) }
        guard name != current.id else {
            try save(record: record, model: model, think: think)
            return
        }
        guard ThreadStore.isValid(name) else { throw ThreadStore.Failure.invalidID(name) }
        let opening = try Self.reserve(name, store: store)
        var renamed = current
        renamed.id = name
        renamed.model = model
        renamed.think = think
        renamed.lastUsed = Date()
        renamed.state = .open
        do {
            try store.save(renamed, record: record)
        } catch {
            opening.lock.release()
            try? store.delete(name)
            throw error
        }
        let old = state.withLock { state in
            defer {
                state.settings = renamed
                state.lock = opening.lock
                state.written = true
            }
            return state.lock
        }
        try? store.delete(current.id)
        old.release()
    }

    /// Lets the thread go and starts another for `/new`: the old one saved as `saved` when anything of it is in the store
    /// or its record holds more than its instructions, and deleted otherwise; the new one a chat's, `chat-<8
    /// characters>`, with the same tools, instructions, and command limit, since the conversation keeps them.
    ///
    /// - Parameters:
    ///   - record: The conversation's store before it is reset.
    ///   - model: The model the chat runs on now.
    ///   - think: The thinking it asks for now.
    /// - Returns: The new thread's id.
    /// - Throws: Errors saving the old thread or locking the new one; the old one is let go either way.
    @discardableResult
    public func renew(record: ThreadRecord, model: String, think: String?) throws -> String {
        try finish(record: record, model: model, think: think)
        let opening = try Self.reserve(store: store)
        state.withLock { state in
            let old = state.settings
            var next = ThreadStore.Settings(
                id: opening.id, owner: Self.owner, model: model, tools: old.tools, instructions: old.instructions,
                think: think, commandTimeoutSeconds: old.commandTimeoutSeconds, session: old.sessions.last ?? "")
            next.sessions = old.sessions.last.map { [$0] } ?? []
            state.settings = next
            state.lock = opening.lock
            state.written = false
        }
        return opening.id
    }

    /// Lets the thread go and holds `opening` in its place, for `/resume`: the thread open now saved as `saved` (or
    /// deleted when nothing of it is kept, as `finish` does) and its lock released; `opening`'s settings taken as the
    /// chat's opening of it takes them, under the same audit session. The switch happens whether or not the save does.
    ///
    /// - Parameters:
    ///   - opening: The thread to hold, locked.
    ///   - record: The conversation's store, the thread open now's.
    ///   - model: The model the chat ran it on.
    ///   - think: The thinking it asked for.
    ///   - tools: The tools of the agent opened on `opening`.
    ///   - instructions: The instructions a new thread starts with; nil keeps those the chat's thread had.
    ///   - opened: The model of the agent opened on `opening`.
    ///   - thinking: The thinking that agent asks for.
    /// - Returns: The error saving the thread let go, or nil.
    public func resume(
        _ opening: Opening, leaving record: ThreadRecord, model: String, think: String?, tools: [String],
        instructions: String?, opened: String, thinking: String?
    ) -> (any Error)? {
        var failure: (any Error)?
        do {
            try finish(record: record, model: model, think: think)
        } catch {
            failure = error
        }
        state.withLock { state in
            let session = state.settings.sessions.last ?? ""
            state.settings = Self.settings(
                opening, session: session, model: opened, tools: tools,
                instructions: instructions ?? state.settings.instructions, think: thinking, now: Date())
            state.lock = opening.lock
            state.written = opening.settings != nil
        }
        return failure
    }

    /// Lets the thread go as the chat ends or starts another: saves it as `saved` when anything of it is in the store or
    /// the record holds more than its instructions, deletes the directory its lock made otherwise, and releases the
    /// lock.
    ///
    /// - Parameters:
    ///   - record: The conversation's store.
    ///   - model: The model the chat runs on now.
    ///   - think: The thinking it asks for now.
    /// - Throws: Errors saving it; the lock is released either way.
    public func finish(record: ThreadRecord, model: String, think: String?) throws {
        let (lock, written, id) = state.withLock { ($0.lock, $0.written, $0.settings.id) }
        defer { lock.release() }
        if written || record.entries.contains(where: { $0.kind != .instructions }) {
            try save(record: record, model: model, think: think, state: .saved)
        } else if (try? store.settings(id)) == nil {
            try? store.delete(id)
        }
    }

    /// The threads the person may open, for `/threads` and `wisp chat --list`: every thread in the store, any owner's,
    /// most recently used first, with its owner, model, turns, when it was last used, and its state (`open` here,
    /// `open elsewhere` when another wisp holds it, `saved`); then the threads whose `thread.json` cannot be read here;
    /// then the transcripts saved by earlier wisps that are not in
    /// the store, which `--resume` opens and saves into it.
    ///
    /// - Parameters:
    ///   - store: The store.
    ///   - transcripts: The transcripts; nil lists none.
    ///   - current: The thread open here, if any.
    /// - Returns: The lines.
    public static func listing(store: ThreadStore, transcripts: TranscriptStore?, current: String?) -> [String] {
        let threads = store.all
        var lines: [String]
        if threads.isEmpty {
            lines = ["no saved threads"]
        } else {
            lines = TextTable.render(
                header: ["THREAD", "OWNER", "MODEL", "TURNS", "LAST USED", "STATE"],
                rows: threads.map { settings in
                    let state =
                        settings.id == current
                        ? "open" : store.holder(of: settings.id) == nil ? "saved" : "open elsewhere"
                    return [
                        settings.id, settings.owner, settings.model, String(settings.turns),
                        shortTime(settings.lastUsed), state,
                    ]
                }, rightAligned: [3])
        }
        let unreadable = store.unreadable
        if !unreadable.isEmpty {
            lines.append(
                "cannot be read here: \(unreadable.joined(separator: ", ")); wisp threads show ID says why")
        }
        let ids = Set(store.ids)
        let older = ((try? transcripts?.list()) ?? []).filter { !ids.contains($0) }
        if let transcripts, !older.isEmpty {
            lines.append(
                "in \(ChatStatus.abbreviated(transcripts.directory.path)), opened with --resume and saved into the "
                    + "store then: " + older.joined(separator: ", "))
        }
        return lines
    }

    /// The threads `wisp-tui`'s picker offers (`/threads`): every saved thread no other process holds, most recently
    /// used first, the one open here among them, each with its owner, model, turns, and when it was last used; and the
    /// ids of those another process holds, which are not offered.
    ///
    /// - Parameters:
    ///   - store: The store.
    ///   - current: The thread open here.
    /// - Returns: The options, and the ids held elsewhere.
    public static func choices(store: ThreadStore, current: String?) -> (options: [ChatChoice.Option], held: [String]) {
        var options: [ChatChoice.Option] = []
        var held: [String] = []
        for settings in store.all {
            if settings.id != current, store.holder(of: settings.id) != nil {
                held.append(settings.id)
                continue
            }
            options.append(
                ChatChoice.Option(
                    value: settings.id,
                    detail: "\(settings.owner) · \(settings.model) · \(turns(settings.turns)) · "
                        + shortTime(settings.lastUsed)))
        }
        return (options, held)
    }

    /// `N turn` or `N turns`.
    static func turns(_ count: Int) -> String { "\(count) turn\(count == 1 ? "" : "s")" }

    /// A time as the listings show it, `2026-10-16 09:12`, in the local time zone.
    ///
    /// - Parameter date: The time.
    /// - Returns: The text.
    static func shortTime(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0)
    }
}

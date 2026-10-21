import Foundation

/// The chat's thread in the thread store ([ADR 0066](../../../../docs/decisions/0066-one-thread-store.md), D2, D11):
/// saved after every turn, renamed by `/save NAME`, listed with every other by `/threads` (a picker in `wisp-tui`), let
/// go by `/new`, which starts another, and by `/resume ID`, which opens a saved one in its place. An agent's thread opened here keeps its settings: `/model` and `/think` refuse to change them.
extension ChatLoop {
    /// Saves the thread as it stands; a failure is a note, never a failed turn.
    ///
    /// - Parameter turn: Whether a turn has just ended, which the thread counts.
    func saveThread(turn: Bool = false) {
        guard let thread else { return }
        do {
            try thread.save(
                record: agent.store, turn: turn, model: agent.model.selection.description, think: agent.thinking?.text)
        } catch {
            io.note(style.ember("error: could not save thread \(thread.id): \(error)"))
        }
    }

    /// `/save [NAME]`: with a name, renames the thread to it, refused for an agent's thread, a name that cannot be an
    /// id, and one another thread has; bare, saves it now under its id.
    ///
    /// - Parameter name: The new name; nil saves it as it is.
    func save(as name: String?) {
        guard let thread else {
            io.note("threads are not saved here")
            return
        }
        do {
            if let name {
                let old = thread.id
                try thread.rename(
                    to: name, record: agent.store, model: agent.model.selection.description,
                    think: agent.thinking?.text)
                io.note(old == name ? "saved thread \(name)" : "saved thread \(old) as \(name)")
            } else {
                try thread.save(
                    record: agent.store, model: agent.model.selection.description, think: agent.thinking?.text)
                io.note("saved thread \(thread.id); /save NAME renames it")
            }
        } catch {
            io.note(style.ember("error: \(error)"))
        }
    }

    /// The lines of `/threads`: every thread the person may open (`ChatThread.listing`).
    ///
    /// - Returns: The lines.
    func threadListing() -> [String] {
        guard let thread else { return ["threads are not saved here"] }
        return ChatThread.listing(store: thread.store, transcripts: thread.transcripts, current: thread.id)
    }

    /// `/threads`, and `/resume` with no id: the listing, or in a face with a chooser of its own (`wisp-tui`) a picker
    /// over the same threads, the one open here marked, and choosing one resumes it as `/resume ID` does. A thread
    /// another process holds is not offered, and a note names it. No answer, or the thread open here, leaves it.
    mutating func threads() async {
        guard let thread, let choose = io.choose, context.openThread != nil else {
            for line in threadListing() { io.print(line) }
            return
        }
        let (options, held) = ChatThread.choices(store: thread.store, current: thread.id)
        if !held.isEmpty { io.note(style.muted("open elsewhere, so not offered: " + held.joined(separator: ", "))) }
        guard !options.isEmpty else {
            for line in threadListing() { io.print(line) }
            return
        }
        let answer = await choose(ChatChoice(title: "Open which thread?", options: options, current: thread.id))
        guard let id = answer?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id != thread.id else {
            io.note(style.muted("thread unchanged"))
            return
        }
        resume(id)
    }

    /// `/new`'s thread: the one before saved and let go, another started; a failure is a note.
    ///
    /// - Parameter record: The conversation's store before `/new` reset it.
    /// - Returns: The new thread's id, or nil when there is no thread or it could not be started.
    func renewThread(after record: ThreadRecord) -> String? {
        guard let thread else { return nil }
        do {
            return try thread.renew(
                record: record, model: agent.model.selection.description, think: agent.thinking?.text)
        } catch {
            io.note(style.ember("error: \(error)"))
            return nil
        }
    }

    /// Why a setting of the conversation cannot be changed: it is an agent's thread, whose settings hold in chat so its
    /// agent resumes it as it left it; nil when it can.
    ///
    /// - Parameter setting: What would change, for the note.
    /// - Returns: The note, or nil.
    func agentsThreadRefusal(_ setting: String) -> String? {
        guard let thread, thread.isAgents else { return nil }
        return "thread \(thread.id) is \(thread.settings.owner)'s: its \(setting) holds here, so its agent resumes it "
            + "as it left it; /new starts a thread of your own"
    }
}

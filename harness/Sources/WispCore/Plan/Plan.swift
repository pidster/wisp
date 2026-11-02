import Foundation

/// A conversation's plan: trees of tasks, each tree rooted at a turn of the conversation, its spine
/// ([ADR 0081](../../../../docs/decisions/0081-the-plan-tool.md), from
/// [ADR 0079](../../../../docs/decisions/0079-the-conversation-as-a-spine-with-task-trees.md)). The model builds and
/// tracks it through the `plan` tool; nothing runs from it. Saved with the conversation's record, so a resumed
/// thread has its plan. Every operation is pure: it returns the changed plan or a failure the model can act on.
public struct Plan: Codable, Sendable, Equatable {
    /// One tree: the tasks the model added in one turn without a parent, and everything added under them later.
    public struct Tree: Codable, Sendable, Equatable {
        /// Its number in the conversation, from 1: the tree is `t<id>`.
        public var id: Int
        /// The store id of the prompt of the turn that rooted it; nil until that turn ends.
        public var entry: Int?
        /// When it was rooted.
        public var created: Date

        /// The tree's name, `t<id>`.
        public var name: String { "t\(id)" }
    }

    /// How far a task has got. The model sets it as it works; `ready` is not stored but derived (`isReady`).
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Not started.
        case pending
        /// Being worked on.
        case running
        /// Running, and waiting on a question the model put to the person with `ask`; set and cleared by wisp, never
        /// by the model (ADR 0079, decision 24).
        case waiting
        /// Finished.
        case done
        /// Tried, and did not succeed; what depends on it cannot go on.
        case failed
        /// Not done, on purpose; what depends on it cannot go on.
        case skipped

        /// Whether the task is over, one way or another.
        var isSettled: Bool { self == .done || self == .failed || self == .skipped }
    }

    /// One task.
    public struct Task: Codable, Sendable, Equatable {
        /// `t<tree>.<n>`, `n` one more than the highest number the tree's tasks and their dependencies name, so never
        /// reused; or the id the model asked for, when `adding` keeps it, which may be deeper (`t1.2.1`) for a task
        /// under another.
        public var id: String
        /// The tree it belongs to.
        public var tree: Int
        /// The task it sits under; nil for a task at the top of its tree.
        public var parent: String?
        /// What it is for, as the model wrote it.
        public var goal: String
        /// How far it has got.
        public var status: Status
        /// Tasks it depends on, anywhere in the conversation's plan.
        public var dependsOn: [String]
        /// The model's last note on it: what it found, or why it failed or was skipped.
        public var note: String?
        /// When it was added.
        public var created: Date
        /// When it last changed.
        public var updated: Date
        /// The tool calls that did its work, in the order linked, at most `callsPerTask`: those made while it was the one task
        /// running, and those made this turn while no single task was running, which go to the next task settled
        /// ([ADR 0079](../../../../docs/decisions/0079-the-conversation-as-a-spine-with-task-trees.md), decision 21).
        public var calls: [Call] = []
        /// Calls linked to it earlier than those `calls` keeps, past its bound.
        public var droppedCalls = 0
        /// The id of the question it waits on, while it is `waiting`.
        public var question: String?
    }

    /// A tool call linked to a task: enough to say what ran, and its audit call id, which joins it to its `tool.call`
    /// and `tool.result` events and to its output in the output store.
    public struct Call: Codable, Sendable, Equatable {
        /// The audit call id.
        public var id: String
        /// The tool called.
        public var tool: String
        /// What it was asked, short: a command, a path, or the arguments, up to `summaryLimit` characters.
        public var summary: String
        /// Whether the tool threw rather than returning a result.
        public var failed: Bool

        /// The most characters a summary keeps.
        static let summaryLimit = 80

        /// A call to link.
        ///
        /// - Parameters:
        ///   - id: The audit call id.
        ///   - tool: The tool.
        ///   - arguments: The arguments, as the JSON the model generated, from which the summary is taken.
        ///   - failed: Whether the tool threw.
        public init(id: String, tool: String, arguments: String, failed: Bool) {
            self.id = id
            self.tool = tool
            self.summary = Self.summary(of: arguments)
            self.failed = failed
        }

        /// The short form of a call's arguments: the `command` a command tool ran, else the `path` a file tool read
        /// or changed, else the arguments' JSON, cut to `summaryLimit` characters.
        ///
        /// - Parameter arguments: The arguments' JSON.
        /// - Returns: The summary, on one line.
        static func summary(of arguments: String) -> String {
            let object = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            let picked = ["command", "path"].lazy.compactMap { object?[$0] as? String }.first ?? arguments
            let line = picked.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > summaryLimit ? String(line.prefix(summaryLimit - 1)) + "…" : line
        }
    }

    /// Why an operation was refused, said to the model so it can correct the call.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// No task or tree by that id.
        case unknown(String)
        /// The goal is empty or too long.
        case badGoal(String)
        /// The note is too long.
        case badNote
        /// A limit would be passed.
        case limit(String)
        /// The dependency would make a cycle, through the ids given.
        case cycle([String])
        /// A task cannot depend on itself.
        case selfDependency(String)
        /// A task cannot start or finish while a task it depends on is not done.
        case blocked(task: String, by: [String])
        /// The same goal is already a task in the same place.
        case duplicate(String)
        /// A tree's name where a task is needed.
        case tree(String)
        /// The id the model gave a new task cannot be its id; the reason says what would be.
        case badID(String)

        /// The failure as the model reads it.
        public var description: String {
            switch self {
            case .unknown(let id): "no task or tree \(id) in this conversation's plan"
            case .badGoal(let reason): "the goal \(reason)"
            case .badNote: "the note is longer than \(Plan.noteLimit) characters"
            case .limit(let reason): reason
            case .cycle(let path): "that would make a cycle: \(path.joined(separator: " -> "))"
            case .selfDependency(let id): "\(id) cannot depend on itself"
            case .blocked(let task, let by):
                "\(task) depends on \(by.joined(separator: ", ")), not done yet; finish or settle "
                    + (by.count == 1 ? "it" : "them") + " first, or mark \(task) skipped"
            case .duplicate(let id): "\(id) already has that goal there; nothing added"
            case .tree(let name): "\(name) is a tree, not a task; name one of its tasks, such as \(name).1"
            case .badID(let reason): reason
            }
        }
    }

    /// The most characters a goal may have.
    static let goalLimit = 200
    /// The most characters a note may have.
    static let noteLimit = 300
    /// The most tasks a tree may hold.
    static let tasksPerTree = 64
    /// The most tasks a conversation's plan may hold.
    static let tasksPerPlan = 256
    /// The deepest a task may sit: a task at the top of its tree is at depth 1.
    static let depthLimit = 6
    /// The most tasks one task may depend on.
    static let dependencyLimit = 8
    /// The most calls a task keeps; earlier ones are counted, not kept.
    static let callsPerTask = 32

    /// The trees, in the order they were rooted.
    public private(set) var trees: [Tree] = []
    /// Every task, in the order it was added.
    public private(set) var tasks: [Task] = []
    /// Changes made from outside the model's turns, by the person or an MCP caller, not yet told to the model: a line
    /// each naming who made it (`the person: t1.2 skipped`), oldest first, at most `untoldKept`. The next turn's
    /// requests carry them in the now block, and the turn takes them (ADR 0079, decision 22).
    public internal(set) var untold: [String] = []

    /// The most changes kept for the model; earlier ones are let go, the latest being what holds.
    static let untoldKept = 8

    /// An empty plan.
    public init() {}

    /// Whether it holds nothing.
    public var isEmpty: Bool { tasks.isEmpty }

    /// The task `id`, or nil.
    ///
    /// - Parameter id: `t<tree>.<n>`.
    /// - Returns: The task.
    public func task(_ id: String) -> Task? { tasks.first { $0.id == id } }

    /// The tree `t<id>`, or nil.
    ///
    /// - Parameter id: The tree's number.
    /// - Returns: The tree.
    public func tree(_ id: Int) -> Tree? { trees.first { $0.id == id } }

    /// The tree a name such as `t3` names, or nil.
    ///
    /// - Parameter name: `t<number>`.
    /// - Returns: The tree.
    public func tree(named name: String) -> Tree? {
        guard name.hasPrefix("t"), !name.contains("."), let id = Int(name.dropFirst()) else { return nil }
        return tree(id)
    }

    /// The failure for `id`, which names no task: that it is a tree's, when it is, else that it is unknown.
    ///
    /// - Parameter id: The id given.
    /// - Returns: The failure.
    func missing(_ id: String) -> Failure { tree(named: id) == nil ? .unknown(id) : .tree(id) }

    /// The tasks of tree `id`, in the order they were added.
    ///
    /// - Parameter id: The tree's number.
    /// - Returns: Its tasks.
    public func tasks(inTree id: Int) -> [Task] { tasks.filter { $0.tree == id } }

    /// The tasks that depend on `id`, in the order they were added.
    ///
    /// - Parameter id: A task.
    /// - Returns: Its dependents.
    public func dependents(of id: String) -> [Task] { tasks.filter { $0.dependsOn.contains(id) } }

    /// The tasks directly under `id`.
    ///
    /// - Parameter id: A task.
    /// - Returns: Its children, in the order they were added.
    public func children(of id: String) -> [Task] { tasks.filter { $0.parent == id } }

    /// Whether `task` can start: pending, and every task it depends on done.
    ///
    /// - Parameter task: The task.
    /// - Returns: Whether it is ready.
    public func isReady(_ task: Task) -> Bool {
        task.status == .pending && unfinished(task.dependsOn).isEmpty
    }

    /// The tasks that can start, in the order they were added.
    public var ready: [Task] { tasks.filter(isReady) }

    /// Of `ids`, those not done.
    ///
    /// - Parameter ids: Tasks.
    /// - Returns: The ones whose status is not `done`, in the order given.
    func unfinished(_ ids: [String]) -> [String] { ids.filter { task($0)?.status != .done } }

    /// How deep `id` sits: 1 at the top of its tree.
    ///
    /// - Parameter id: A task.
    /// - Returns: Its depth; 0 for an unknown task.
    func depth(of id: String) -> Int {
        var depth = 0
        var current: String? = id
        while let at = current, let task = task(at), depth <= Self.depthLimit + 1 {
            depth += 1
            current = task.parent
        }
        return depth
    }

    /// Adds a task. Without a parent it goes at the top of `currentTree`, the tree of the turn under way, which is
    /// rooted first when there is none; with one it goes under that task, in the parent's tree, or at the top of a
    /// tree named `t<n>`. A parent naming the turn's own tree before its first task roots it, or written `none` or
    /// `null`, counts as none, since a model names the tree it expects. A dependency may name a task of the same tree
    /// that is not added yet, as a model calling the tool for several tasks at once does; the task is not ready until
    /// that one is added and done.
    ///
    /// A model's own id for the task is kept, or refused with the id to give instead, never silently replaced, since
    /// a model that is not told the real id goes on using its own (the planning probe of 2026-10-28): a level id
    /// (`t1.4`) when it is in the task's tree and unused; a deeper one (`t1.2.1`) as a child of the task its prefix
    /// names, `parent` left out or naming that task. A tree's name, an id taken, one of another tree, a deeper one
    /// under a task not in the plan or under another than `parent`, and a name written as an id (`t1.find`) are refused.
    /// Anything else is ignored and the next number given. The same goal added again in the same place is refused, as
    /// a model repeating a call would otherwise add it each time.
    ///
    /// - Parameters:
    ///   - goal: What it is for.
    ///   - parent: A task id, a tree name, or nil.
    ///   - dependsOn: Tasks it depends on.
    ///   - currentTree: The tree the turn under way rooted, if any.
    ///   - requestedID: The id the model gave the task, if any.
    ///   - now: The time.
    /// - Returns: The plan with the task added, the task's id, the tree the turn under way now has, and the task.
    /// - Throws: `Failure` when the goal, the parent, a dependency, a cycle, or a limit is wrong.
    func adding(
        goal: String, parent: String?, dependsOn: [String], currentTree: Int?, requestedID: String? = nil, now: Date
    ) throws(Failure) -> (plan: Plan, id: String, currentTree: Int?, task: Task) {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { throw Failure.badGoal("is empty") }
        guard goal.count <= Self.goalLimit else {
            throw Failure.badGoal("is longer than \(Self.goalLimit) characters")
        }
        guard tasks.count < Self.tasksPerPlan else {
            throw Failure.limit("the plan holds \(Self.tasksPerPlan) tasks, the most it may; settle or reuse them")
        }
        let dependencies = Self.distinct(dependsOn)
        guard dependencies.count <= Self.dependencyLimit else {
            throw Failure.limit("a task may depend on at most \(Self.dependencyLimit) tasks")
        }
        var plan = self
        let turnTree = currentTree.flatMap { tree($0) == nil ? nil : $0 }
        let newTree = (trees.map(\.id).max() ?? 0) + 1
        var parent = parent?.trimmingCharacters(in: .whitespaces)
        if let named = parent,
            named.isEmpty || ["none", "null"].contains(named.lowercased())
                || (task(named) == nil && tree(named: named) == nil
                    && named == "t\(turnTree ?? newTree)")
        {
            parent = nil
        }
        let requested = requestedID.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let shape = requested.flatMap(Self.parts)
        let above = shape.flatMap { $0.path.count > 1 ? Self.id(tree: $0.tree, path: $0.path.dropLast()) : nil }
        if parent == nil, let requested, let above {
            guard task(above) != nil else {
                throw Failure.badID(
                    "\(requested) would go under \(above), which is not in the plan; add \(above) first, or leave id out"
                )
            }
            parent = above
        }
        var current = currentTree
        let treeID: Int
        var parentTask: String?
        if let parent {
            if let task = task(parent) {
                guard depth(of: parent) < Self.depthLimit else {
                    throw Failure.limit("a task may sit at most \(Self.depthLimit) deep; add it higher up")
                }
                treeID = task.tree
                parentTask = parent
            } else if let tree = tree(named: parent) {
                treeID = tree.id
            } else {
                throw Failure.unknown(parent)
            }
        } else if let turnTree {
            treeID = turnTree
        } else {
            treeID = newTree
            plan.trees.append(Tree(id: treeID, entry: nil, created: now))
            current = treeID
        }
        if let unknown = dependencies.first(where: { id in
            task(id) == nil && Self.parts(id).map { $0.tree == treeID && !$0.path.isEmpty } != true
        }) {
            throw missing(unknown)
        }
        let inTree = tasks(inTree: treeID)
        if let same = inTree.first(where: { $0.parent == parentTask && $0.goal == goal }) {
            throw Failure.duplicate(same.id)
        }
        guard inTree.count < Self.tasksPerTree else {
            throw Failure.limit("tree t\(treeID) holds \(Self.tasksPerTree) tasks, the most a tree may")
        }
        let named = inTree.flatMap { [$0.id] + $0.dependsOn }
        let next = (named.compactMap { Self.number($0, inTree: treeID) }.max() ?? 0) + 1
        let numbered = "t\(treeID).\(next)"
        let instead = "give this task \(numbered), or leave id out"
        if let requested, shape == nil, Self.looksNumbered(requested) {
            throw Failure.badID("\(requested) is not an id; \(instead)")
        }
        if let requested, let shape {
            guard !shape.path.isEmpty else { throw Failure.badID("\(requested) names a tree; \(instead)") }
            guard shape.tree == treeID else {
                throw Failure.badID("\(requested) is not in t\(treeID), where this task goes; \(instead)")
            }
            if let above, above != parentTask {
                throw Failure.badID(
                    "\(requested) would go under \(above), but parent is \(parent ?? "none"); make them agree, or leave id out"
                )
            }
            guard task(requested) == nil else { throw Failure.badID("\(requested) is already a task; \(instead)") }
        }
        let id = shape == nil ? numbered : requested ?? numbered
        for dependency in dependencies {
            if let path = path(from: dependency, to: id) { throw Failure.cycle([id] + path) }
        }
        let task = Task(
            id: id, tree: treeID, parent: parentTask, goal: goal, status: .pending, dependsOn: dependencies, note: nil,
            created: now, updated: now)
        plan.tasks.append(task)
        return (plan, id, current, task)
    }

    /// Makes `id` depend on `on`, anywhere in the plan; a dependency already there changes nothing.
    ///
    /// - Parameters:
    ///   - id: The task that waits.
    ///   - on: The task it waits for.
    ///   - now: The time.
    /// - Returns: The plan with the dependency.
    /// - Throws: `Failure` for an unknown task, a task depending on itself, a cycle, or the limit.
    func depending(_ id: String, on: String, now: Date) throws(Failure) -> Plan {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw missing(id) }
        guard task(on) != nil else { throw missing(on) }
        guard id != on else { throw Failure.selfDependency(id) }
        guard !tasks[index].dependsOn.contains(on) else { return self }
        guard tasks[index].dependsOn.count < Self.dependencyLimit else {
            throw Failure.limit("a task may depend on at most \(Self.dependencyLimit) tasks")
        }
        if let path = path(from: on, to: id) { throw Failure.cycle([id] + path) }
        var plan = self
        plan.tasks[index].dependsOn.append(on)
        plan.tasks[index].updated = now
        return plan
    }

    /// A chain of dependencies from `start` to `goal`, both included, or nil when there is none.
    ///
    /// - Parameters:
    ///   - start: Where to begin.
    ///   - goal: Where to arrive.
    /// - Returns: The ids along the way.
    func path(from start: String, to goal: String) -> [String]? {
        var seen: Set<String> = []
        func walk(_ id: String) -> [String]? {
            if id == goal { return [id] }
            guard seen.insert(id).inserted, let task = task(id) else { return nil }
            for next in task.dependsOn {
                if let rest = walk(next) { return [id] + rest }
            }
            return nil
        }
        return walk(start)
    }

    /// Sets a task's status, and its note when one is given. Starting or finishing a task whose dependencies are not
    /// done is refused; failing or skipping it is not. The person may finish one anyway, knowing it done some other way
    /// (ADR 0079, decision 22).
    ///
    /// - Parameters:
    ///   - id: The task.
    ///   - status: Its new status; nil keeps the one it has, for a note alone.
    ///   - note: What the model found, or why; nil keeps the note it had.
    ///   - now: The time.
    ///   - byPerson: Whether the person made the change, who may mark a task done while one it depends on is not.
    /// - Returns: The plan with the task changed.
    /// - Throws: `Failure` for an unknown task, a long note, or a task still waiting on another.
    func updating(
        _ id: String, status: Status?, note: String?, now: Date, byPerson: Bool = false
    ) throws(Failure)
        -> Plan
    {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw missing(id) }
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note, note.count > Self.noteLimit { throw Failure.badNote }
        if status == .running || (status == .done && !byPerson) {
            let waiting = unfinished(tasks[index].dependsOn)
            guard waiting.isEmpty else { throw Failure.blocked(task: id, by: waiting) }
        }
        var plan = self
        if let status { plan.tasks[index].status = status }
        if let note, !note.isEmpty { plan.tasks[index].note = note }
        plan.tasks[index].updated = now
        return plan
    }

    /// The plan with `calls` linked to task `id`, the oldest past `callsPerTask` counted rather than kept.
    ///
    /// - Parameters:
    ///   - calls: The calls, oldest first.
    ///   - id: The task; a task not in the plan leaves the plan as it is.
    ///   - dropped: Calls made before `calls` that were already let go, to count.
    /// - Returns: The plan.
    func linking(_ calls: [Call], to id: String, dropped: Int = 0) -> Plan {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !calls.isEmpty || dropped > 0 else { return self }
        var plan = self
        let all = plan.tasks[index].calls + calls
        let over = max(0, all.count - Self.callsPerTask)
        plan.tasks[index].calls = Array(all.dropFirst(over))
        plan.tasks[index].droppedCalls += over + dropped
        return plan
    }

    /// Keeps `line`, a change made from outside the model's turns, for its next turn, letting go of the oldest past the bound.
    ///
    /// - Parameter line: The change.
    mutating func tellModel(_ line: String) {
        untold.append(line)
        if untold.count > Self.untoldKept { untold.removeFirst() }
    }

    /// The plan with its untold changes taken, and the changes, for the turn that tells the model of them.
    ///
    /// - Returns: The plan with none left to tell, and the lines.
    func takingUntold() -> (plan: Plan, lines: [String]) {
        var plan = self
        plan.untold = []
        return (plan, untold)
    }

    /// The plan with the task the question is taken to be about set `waiting` on question `id` (ADR 0079, decision 24):
    /// the one task running, or, with none running, the first ready, the task the reminder names, since small models
    /// often go from `pending` to `done` without `running`. Unchanged when several are running, which leaves no way to
    /// tell, or when none is running or ready, when no task needs to wait.
    ///
    /// - Parameters:
    ///   - id: The question's id.
    ///   - now: The time.
    /// - Returns: The plan, and the task that waits, if one does.
    func waiting(on id: String, now: Date) -> (plan: Plan, task: String?) {
        let running = tasks.filter { $0.status == .running }
        guard let task = running.isEmpty ? ready.first : (running.count == 1 ? running.first : nil),
            let index = tasks.firstIndex(where: { $0.id == task.id })
        else { return (self, nil) }
        var plan = self
        plan.tasks[index].status = .waiting
        plan.tasks[index].question = id
        plan.tasks[index].updated = now
        return (plan, task.id)
    }

    /// The plan with the task that waits on question `id` running again, `note` saying how the question ended
    /// (decision 24). A task the model or the person moved on from `waiting` meanwhile keeps its status and loses only
    /// the question.
    ///
    /// - Parameters:
    ///   - id: The question's id.
    ///   - note: How it ended, cut to a note's limit.
    ///   - now: The time.
    /// - Returns: The plan, and the task that was running again, if one was waiting.
    func resuming(after id: String, note: String, now: Date) -> (plan: Plan, task: String?) {
        guard let index = tasks.firstIndex(where: { $0.question == id }) else { return (self, nil) }
        var plan = self
        plan.tasks[index].question = nil
        guard plan.tasks[index].status == .waiting else { return (plan, nil) }
        plan.tasks[index].status = .running
        plan.tasks[index].note = note.count > Self.noteLimit ? String(note.prefix(Self.noteLimit - 1)) + "…" : note
        plan.tasks[index].updated = now
        return (plan, plan.tasks[index].id)
    }

    /// The one task running, which a call made now does the work of; nil when none or several are.
    var soleRunning: Task? {
        let running = tasks.filter { $0.status == .running }
        return running.count == 1 ? running.first : nil
    }

    /// The plan with tree `id`'s prompt entry set, once the turn that rooted it has been stored.
    ///
    /// - Parameters:
    ///   - id: The tree.
    ///   - entry: The store id of its turn's prompt.
    /// - Returns: The plan.
    func rooting(_ id: Int, at entry: Int) -> Plan {
        var plan = self
        if let index = plan.trees.firstIndex(where: { $0.id == id }) { plan.trees[index].entry = entry }
        return plan
    }

    /// The tasks matching every criterion given, in the order they were added.
    ///
    /// - Parameters:
    ///   - status: Only tasks with this status; `ready` is matched by `ready`.
    ///   - ready: Only tasks that can start.
    ///   - tree: Only tasks of this tree.
    ///   - text: Only tasks whose goal or note contains this, ignoring case.
    ///   - dependsOn: Only tasks that depend on this one.
    ///   - dependedOnBy: Only tasks this one depends on.
    /// - Returns: The tasks.
    func find(
        status: Status? = nil, ready: Bool = false, tree: Int? = nil, text: String? = nil, dependsOn: String? = nil,
        dependedOnBy: String? = nil
    ) -> [Task] {
        let needle = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let required = dependedOnBy.map { task($0)?.dependsOn ?? [] }
        return tasks.filter { task in
            (status.map { task.status == $0 } ?? true)
                && (!ready || isReady(task))
                && (tree.map { task.tree == $0 } ?? true)
                && (needle.map {
                    $0.isEmpty || task.goal.lowercased().contains($0) || (task.note?.lowercased().contains($0) ?? false)
                } ?? true)
                && (dependsOn.map { task.dependsOn.contains($0) } ?? true)
                && (required.map { $0.contains(task.id) } ?? true)
        }
    }

    /// The number of task `id` within tree `tree` (`t3.2` is 2 in tree 3), or nil when `id` is not of that tree.
    ///
    /// - Parameters:
    ///   - id: A task id.
    ///   - tree: The tree.
    /// - Returns: The number.
    static func number(_ id: String, inTree tree: Int) -> Int? {
        let prefix = "t\(tree)."
        guard id.hasPrefix(prefix), let number = Int(id.dropFirst(prefix.count)), number > 0, number < 10_000 else {
            return nil
        }
        return number
    }

    /// The tree and the numbers below it of an id: `t1.2.3` is tree 1 and `[2, 3]`, `t1` tree 1 and `[]`; nil for
    /// anything else.
    ///
    /// - Parameter id: An id.
    /// - Returns: Its parts.
    static func parts(_ id: String) -> (tree: Int, path: [Int])? {
        guard id.hasPrefix("t") else { return nil }
        let pieces = id.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard
            pieces.allSatisfy({ piece in
                !piece.isEmpty && piece.count < 5 && piece.allSatisfy { $0.isASCII && $0.isNumber }
            })
        else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.allSatisfy({ $0 > 0 }) else { return nil }
        return (numbers[0], Array(numbers.dropFirst()))
    }

    /// Whether `text` begins as an id does, `t` and a number and a dot (`t1.find`, `t1.1a`), so a model meant it as
    /// one: granite4.2:8b named its tasks so on 2026-10-28, and numbered without a word, its later calls naming them
    /// failed.
    ///
    /// - Parameter text: The id given.
    /// - Returns: Whether it is meant as an id.
    static func looksNumbered(_ text: String) -> Bool {
        guard text.hasPrefix("t") else { return false }
        let digits = text.dropFirst().prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && text.dropFirst(1 + digits.count).hasPrefix(".")
    }

    /// The id of the task at `path` in tree `tree`.
    ///
    /// - Parameters:
    ///   - tree: The tree.
    ///   - path: The numbers below it.
    /// - Returns: The id, such as `t1.2`.
    static func id(tree: Int, path: some Sequence<Int>) -> String {
        (["t\(tree)"] + path.map(String.init)).joined(separator: ".")
    }

    /// `ids` with repeats and empty ones removed, in order.
    ///
    /// - Parameter ids: The ids.
    /// - Returns: Each once.
    static func distinct(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension Plan.Task {
    /// Decodes a task, its `calls` and `droppedCalls` absent from a plan saved before tasks were linked to calls
    /// (0.33 and earlier), so such a thread resumes with none.
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` for a task missing what every task has had since 0.32.0.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tree = try container.decode(Int.self, forKey: .tree)
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        goal = try container.decode(String.self, forKey: .goal)
        status = try container.decode(Plan.Status.self, forKey: .status)
        dependsOn = try container.decode([String].self, forKey: .dependsOn)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        calls = try container.decodeIfPresent([Plan.Call].self, forKey: .calls) ?? []
        droppedCalls = try container.decodeIfPresent(Int.self, forKey: .droppedCalls) ?? 0
        question = try container.decodeIfPresent(String.self, forKey: .question)
    }
}

extension Plan {
    /// Decodes a plan, its `untold` absent from one saved before others could change it (0.33 and earlier).
    ///
    /// - Parameter decoder: The decoder.
    /// - Throws: `DecodingError` for a plan missing its trees or tasks.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trees = try container.decode([Tree].self, forKey: .trees)
        tasks = try container.decode([Task].self, forKey: .tasks)
        untold = try container.decodeIfPresent([String].self, forKey: .untold) ?? []
    }
}

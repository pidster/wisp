import Foundation
import FoundationModels

/// The list `wisp models` prints and `/models` shows in chat. A model is listed when it can serve the
/// conversation: it resolves (so it is installed, reachable, entitled, and able to converse) and it
/// declares what the conversation needs (tool calling, when there are tools). The same checks decide
/// whether `/model` or `--model` can switch to it, so the list never offers what would be refused.
public enum ModelListing {
    /// One candidate and whether it can be used.
    public struct Entry: Equatable, Sendable {
        /// The selection that names it.
        public var selection: ModelSelection
        /// Size, parameter count, or whatever the backend reports; empty for Apple's models.
        public var detail: String
        /// Declared capabilities when it resolved.
        public var capabilities: [String]
        /// Why it cannot be used, or nil when it can.
        public var problem: String?
    }

    /// Every candidate: Apple's two models, then each backend's installed models, each judged; and a
    /// line of text for each backend that did not answer.
    public static func entries(
        config: Config.Resolved, home: Home, tools: [any Tool]
    ) async -> (entries: [Entry], unreachable: [String]) {
        var candidates: [(ModelSelection, String)] = [(.system, ""), (.privateCloud, "")]
        var unreachable: [String] = []
        for backend in ModelBackends.all {
            do {
                candidates += try await backend.installed(config: config, home: home).map { ($0.selection, $0.detail) }
            } catch {
                unreachable.append("\(backend.scheme): \(error)")
            }
        }
        let entries = candidates.map { selection, detail in
            do {
                let resolved = try selection.resolve(config: config, home: home)
                try resolved.check(tools: tools)
                return Entry(selection: selection, detail: detail, capabilities: resolved.capabilityNames, problem: nil)
            } catch {
                return Entry(selection: selection, detail: detail, capabilities: [], problem: "\(error)")
            }
        }
        return (entries, unreachable)
    }

    /// One line per usable model, the current one marked `*`; with `all`, excluded models follow with
    /// the reason. A backend that did not answer gets one line either way, so a short list is explained.
    /// With a `width` (standard output is a terminal) the lines are the aligned layout of `terminal`
    /// instead; without one they stay tab-separated for scripts.
    public static func lines(
        config: Config.Resolved, home: Home, current: ModelSelection, tools: [any Tool], all: Bool = false,
        width: Int? = nil
    ) async -> [String] {
        let listed = await entries(config: config, home: home, tools: tools)
        if let width {
            return terminal(listed.entries, unreachable: listed.unreachable, current: current, all: all, width: width)
        }
        var lines: [String] = []
        for entry in listed.entries where entry.problem == nil {
            let facts = ([entry.detail] + [entry.capabilities.joined(separator: ", ")]).filter { !$0.isEmpty }
            lines.append(
                "\(entry.selection == current ? "*" : " ") \(entry.selection)\t\(facts.joined(separator: "; "))")
        }
        if all {
            for entry in listed.entries where entry.problem != nil {
                lines.append("  \(entry.selection)\tnot usable: \(entry.problem ?? "")")
            }
        }
        for backend in listed.unreachable { lines.append("  (\(backend))") }
        if lines.isEmpty { lines.append(noUsableModel) }
        return lines
    }

    /// The chat's `/models`: the usable models as a `TextTable`, the current one marked `*`, then a line
    /// per backend that did not answer. `lines` stays tab-separated for scripts reading `wisp models`.
    public static func table(
        config: Config.Resolved, home: Home, current: ModelSelection, tools: [any Tool]
    ) async -> [String] {
        let listed = await entries(config: config, home: home, tools: tools)
        return table(listed.entries, unreachable: listed.unreachable, current: current)
    }

    /// Renders entries as the `/models` table.
    static func table(_ entries: [Entry], unreachable: [String], current: ModelSelection) -> [String] {
        let usable = entries.filter { $0.problem == nil }
        var lines =
            usable.isEmpty
            ? [noUsableModel]
            : TextTable.render(
                header: ["  MODEL", "DETAILS", "CAPABILITIES"],
                rows: usable.map { entry in
                    [
                        "\(entry.selection == current ? "*" : " ") \(entry.selection)", entry.detail,
                        entry.capabilities.joined(separator: ", "),
                    ]
                })
        lines += unreachable.map { "  (\($0))" }
        return lines
    }

    /// `wisp models` on a terminal: the marker and name, parameter count, size, and capabilities as
    /// aligned columns under a header, wrapped to `width`; with `all`, a model that cannot be used has an
    /// empty capabilities cell and its reason on the lines under it, indented and wrapped to the full width. Notes for backends that did not answer follow, wrapped under a hanging indent.
    static func terminal(
        _ entries: [Entry], unreachable: [String], current: ModelSelection, all: Bool, width: Int
    ) -> [String] {
        let shown = entries.filter { all || $0.problem == nil }
        let split = shown.map { entry -> (params: String, size: String) in
            guard let match = entry.detail.wholeMatch(of: /(\d[\d.]*[KMBT]) +(.+)/) else { return ("", entry.detail) }
            return (String(match.1), String(match.2))
        }
        let rows = zip(shown, split).map { entry, detail in
            [
                "\(entry.selection == current ? "*" : " ") \(entry.selection)", detail.params, detail.size,
                entry.problem == nil ? entry.capabilities.joined(separator: ", ") : "",
            ]
        }
        var lines = [noUsableModel]
        if !shown.isEmpty {
            let groups = TerminalTable.renderGroups(
                header: ["  MODEL", "PARAMS", "SIZE", "CAPABILITIES"], rows: rows, width: width)
            lines = groups[0]
            for (group, entry) in zip(groups.dropFirst(), shown) {
                lines += group
                if let problem = entry.problem {
                    lines += TerminalTable.note("not usable: \(problem)", indent: 4, width: width)
                }
            }
        }
        for note in unreachable { lines += TerminalTable.note("(\(note))", indent: 2, width: width) }
        return lines
    }

    /// The line shown when nothing can serve the conversation.
    static let noUsableModel = "no usable model; wisp models --all shows why"
}

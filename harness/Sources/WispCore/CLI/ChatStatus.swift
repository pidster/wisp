import Foundation

/// The line shown above each chat prompt: the model, whether it thinks, and how much of its window is used; the
/// directory with its version control, branch, and line changes; and how approvals are decided. Facts only; each part
/// is omitted when unknown.
public struct ChatStatus: Equatable, Sendable {
    /// The model selection, as spelled for `--model`.
    public var model: String
    /// The working directory, with the home directory as `~`.
    public var directory: String
    /// The version control the directory is under (`git`, `svn`), or nil outside a working copy.
    public var vcs: String?
    /// The branch, or nil outside a working copy or when the system cannot tell.
    public var branch: String?
    /// Whether tracked files have uncommitted changes; nil when unknown.
    public var dirty: Bool?
    /// Lines added and removed in tracked files since the last commit; nil when unknown.
    public var added: Int?
    /// See `added`.
    public var removed: Int?
    /// How approvals are decided: `approve at moderate`, `approve at dangerous`, `never asks`, or `--yes`.
    public var approval: String
    /// Fraction of the context window used, 0 to 1, or nil when neither side is known.
    public var contextUsed: Double?
    /// Whether the model thinks: `on`, `off`, a level, or `default` when nothing is asked and the runtime decides; nil
    /// for a model that cannot think or has no switch for it (ADR 0053, amended 2026-10-15).
    public var thinking: String?
    /// A newer wisp's version, when `updates.check` found one (ADR 0074); nil otherwise.
    public var update: String?

    /// Creates a status.
    public init(
        model: String, directory: String, vcs: String? = nil, branch: String? = nil, dirty: Bool? = nil,
        added: Int? = nil, removed: Int? = nil, approval: String, contextUsed: Double? = nil, thinking: String? = nil,
        update: String? = nil
    ) {
        self.update = update
        self.model = model
        self.directory = directory
        self.vcs = vcs
        self.branch = branch
        self.dirty = dirty
        self.added = added
        self.removed = removed
        self.approval = approval
        self.contextUsed = contextUsed
        self.thinking = thinking
    }

    /// The line: on the left `model (off) 15% used · ~/src/wisp git(main)+12-3`, on the right a newer wisp when
    /// `updates.check` found one (`0.31.1 available`, amber) and the approval mode,
    /// pushed to the right edge when `width` is known and there is room, else after a separator. A
    /// context past 80% is amber; lines added are green, lines removed red.
    public func rendered(style: Style, width: Int? = nil) -> String {
        var model = style.wisp(self.model)
        if let thinking { model += style.muted(" (") + style.wisp(thinking) + style.muted(")") }
        if let contextUsed {
            let percent = "\(Int((contextUsed * 100).rounded()))% used"
            model += " " + Self.contextTone(percent, used: contextUsed, style: style)
        }
        var place = style.wisp(directory)
        if let vcs { place += " " + style.muted(vcs) }
        if let branch { place += style.muted(vcs == nil ? " (" : "(") + style.glow(branch) + style.muted(")") }
        if let added, let removed, added + removed > 0 {
            place += style.added("+\(added)") + style.removed("-\(removed)")
        } else if dirty == true {
            place += style.amber("*")
        }
        let left = model + style.muted(" · ") + place
        var right = style.muted(approval)
        if let update { right = style.amber("\(update) available") + style.muted(" · ") + right }
        if let width {
            let gap = width - Style.stripped(left).count - Style.stripped(right).count
            if gap >= 3 { return left + String(repeating: " ", count: gap) + right }
        }
        return left + style.muted(" · ") + right
    }

    /// How a context use is coloured: quiet below half the window, bright from half, amber from 80%,
    /// where condensing is near (it starts at 85%).
    static func contextTone(_ text: String, used: Double, style: Style) -> String {
        if used >= 0.8 { return style.amber(text) }
        return used >= 0.5 ? style.glow(text) : style.muted(text)
    }

    /// `path` with the current user's home replaced by `~`.
    public static func abbreviated(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    )
        -> String
    {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The approval mode in words.
    public static func approvalMode(threshold: ApprovalThreshold, autoApprove: Bool) -> String {
        if autoApprove { return "--yes" }
        switch threshold {
        case .never: return "never asks"
        case .level(let level): return "approve at \(level.rawValue)"
        }
    }
}

import Foundation

/// One project row in the iPhone's merged list.
public struct SupermuxMergedProjectRowValue: Equatable, Sendable {
    /// The merged project's key.
    public let key: String
    /// What the row draws: the lead Mac's row with the merged worktree count
    /// and disclosure. Its `id` (the lead's row id) is what tap, details and
    /// New Worktree act on.
    public let display: SupermuxProjectRowSnapshot
    /// Every location's row id, so the disclosure opens on every Mac.
    public let locationRowIDs: [String]
    /// Whether the lead Mac serves worktree creation.
    public let showsWorktreeCreation: Bool
}

/// One unopened worktree under an expanded merged project.
public struct SupermuxNestedWorktreeRowValue: Equatable, Sendable {
    /// The row id of the project location (Mac) the worktree belongs to.
    public let projectRowID: String
    /// The worktree.
    public let worktree: SupermuxWorktreeRowSnapshot
    /// The owning Mac's name, only when the project spans several Macs.
    public let macName: String?
}

/// What one fork-owned row of the iPhone's merged workspace list draws.
///
/// The list is one table: these rows sit in the table's leading run beside
/// the shell's own (indented) workspace rows. Each value holds exactly its
/// row's inputs, so the table repaints a row only when its value changes.
public enum SupermuxProjectsTableRowValue: Equatable, Sendable {
    /// The slim "PROJECTS" caption: collapse chevron, count and "+".
    case header(isCollapsed: Bool, projectCount: Int?, canEdit: Bool)
    /// Projects are still loading.
    case loading
    /// Every Mac loaded and none has projects.
    case empty(canEdit: Bool)
    /// A project, merged across Macs.
    case project(SupermuxMergedProjectRowValue)
    /// An unopened worktree under an expanded project.
    case worktree(SupermuxNestedWorktreeRowValue)
    /// An expanded project's worktrees are still loading.
    case worktreeLoading
    /// The inline New Worktree row closing an expanded project.
    case newWorktree(projectRowID: String, isPreparing: Bool)
    /// An expanded project with nothing under it.
    case notice

    /// What the row's measured height depends on. Equal identities share one
    /// measurement, so paint-only changes (names, counts, PR, run state)
    /// never re-measure.
    public var heightIdentity: String {
        switch self {
        case .header(let isCollapsed, let projectCount, let canEdit):
            "header:\(isCollapsed):\(projectCount != nil):\(canEdit)"
        case .loading:
            "loading"
        case .empty(let canEdit):
            "empty:\(canEdit)"
        case .project:
            "project"
        case .worktree:
            "worktree"
        case .worktreeLoading:
            "worktreeLoading"
        case .newWorktree:
            "newWorktree"
        case .notice:
            "notice"
        }
    }
}

/// Everything the iPhone's workspace table needs from the Projects section:
/// the merged list's leading run plus the closures its rows act through.
///
/// Not `Equatable` on purpose: the table compares each row's VALUE
/// (``SupermuxProjectsTableRowValue``), never this bundle, so a closure
/// identity change never repaints anything.
public struct SupermuxProjectsTablePayload {
    /// The merged list's leading run.
    public let layout: SupermuxProjectsListLayout
    /// The section's closure bundle.
    public let actions: SupermuxProjectsSectionActions

    /// Memberwise initializer.
    public init(layout: SupermuxProjectsListLayout, actions: SupermuxProjectsSectionActions) {
        self.layout = layout
        self.actions = actions
    }
}

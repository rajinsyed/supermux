#if os(iOS)
import CmuxMobileShellModel

/// Connection chrome represented by an identity-only workspace table item.
enum WorkspaceListChromeKind: Hashable {
    case recoveryBanner
    case macStatusRow
    // SUPERMUX:begin supermux-mobile-projects-table-row (fork Projects rows in the leading run — see SUPERMUX-TOUCHPOINTS.md)
    /// One fork row of the merged Projects list (the PROJECTS caption, a
    /// project, or a row of its disclosure), by its fork row id.
    ///
    /// Deliberately a chrome kind: chrome rows are counted by
    /// `chromePrefixCount`, forbidden as drop targets, non-movable, and
    /// excluded from workspace lookups — the semantics these rows need — so
    /// the UIKit↔model index mapping used by workspace drag-reorder holds.
    /// The workspaces nested under a project are the shell's own indented
    /// workspace rows, also counted in that leading run.
    case supermux(String)
    // SUPERMUX:end supermux-mobile-projects-table-row
}

/// Stable identity for one row in the UIKit-backed workspace list.
enum WorkspaceListTableItem: Hashable, Identifiable {
    case chrome(WorkspaceListChromeKind)
    case filterEmpty
    case emptyWorkspaceList
    case groupHeader(MobileWorkspaceGroupPreview.ID)
    case groupFooter(MobileWorkspaceGroupPreview.ID)
    case workspace(MobileWorkspacePreview.ID, indented: Bool)

    var id: String {
        switch self {
        case .chrome(.recoveryBanner):
            "chrome.recoveryBanner"
        case .chrome(.macStatusRow):
            "chrome.macStatusRow"
        // SUPERMUX:begin supermux-mobile-projects-table-row (one stable id per fork row; namespaced so it never collides with upstream chrome)
        case .chrome(.supermux(let id)):
            "chrome.supermux.\(id)"
        // SUPERMUX:end supermux-mobile-projects-table-row
        case .filterEmpty:
            "filter.empty"
        case .emptyWorkspaceList:
            "workspace.empty"
        case .groupHeader(let groupID):
            "groupHeader.\(groupID.rawValue)"
        case .groupFooter(let groupID):
            "groupFooter.\(groupID.rawValue)"
        case .workspace(let workspaceID, _):
            "workspace.\(workspaceID.rawValue)"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var workspaceID: MobileWorkspacePreview.ID? {
        guard case .workspace(let id, _) = self else { return nil }
        return id
    }

    var groupID: MobileWorkspaceGroupPreview.ID? {
        switch self {
        case .groupHeader(let id), .groupFooter(let id): id
        default: nil
        }
    }

    var isIndentedWorkspace: Bool {
        guard case .workspace(_, let indented) = self else { return false }
        return indented
    }
}
#endif

#if os(iOS)
import CmuxMobileShellModel

/// Connection chrome represented by an identity-only workspace table item.
enum WorkspaceListChromeKind: Hashable {
    case recoveryBanner
    case macStatusRow
    // SUPERMUX:begin supermux-mobile-projects-table-row (fork Projects section as one leading chrome row — see SUPERMUX-TOUCHPOINTS.md)
    /// The fork's Projects section, hosted as ONE row.
    ///
    /// Deliberately a chrome kind: chrome rows are already counted by
    /// `chromePrefixCount`, forbidden as drop targets, non-movable, and
    /// excluded from workspace lookups — exactly the semantics this section
    /// needs — so the UIKit↔model index mapping used by workspace
    /// drag-reorder keeps working untouched. Its identity never varies with
    /// project expansion, so a disclosure stays a payload change rather than
    /// a structural `reloadData()`.
    case supermuxProjects
    // SUPERMUX:end supermux-mobile-projects-table-row
}

/// Stable identity for one row in the UIKit-backed workspace list.
enum WorkspaceListTableItem: Hashable, Identifiable {
    case chrome(WorkspaceListChromeKind)
    case filterEmpty
    case groupHeader(MobileWorkspaceGroupPreview.ID)
    case groupFooter(MobileWorkspaceGroupPreview.ID)
    case workspace(MobileWorkspacePreview.ID, indented: Bool)

    var id: String {
        switch self {
        case .chrome(.recoveryBanner):
            "chrome.recoveryBanner"
        case .chrome(.macStatusRow):
            "chrome.macStatusRow"
        // SUPERMUX:begin supermux-mobile-projects-table-row (stable id — never varies with project expansion, so a disclosure is a payload change, not a structural reload)
        case .chrome(.supermuxProjects):
            "chrome.supermuxProjects"
        // SUPERMUX:end supermux-mobile-projects-table-row
        case .filterEmpty:
            "filter.empty"
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

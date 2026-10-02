public import CmuxMobileShellModel
import Foundation
import SupermuxMobileKit

/// How the shell's list is currently narrowed.
public struct SupermuxProjectsListScope: Sendable {
    /// The trimmed search query.
    public let query: String
    /// The filter-menu filter (read state, machines picked in the menu).
    public let filter: MobileWorkspaceListFilter
    /// The filter actually applied to rows: the menu filter plus the Mac
    /// title picker's machine.
    public let activeFilter: MobileWorkspaceListFilter
    /// Whether the list sorts by recent activity.
    public let appliesRecencySort: Bool

    /// Memberwise initializer.
    public init(
        query: String,
        filter: MobileWorkspaceListFilter,
        activeFilter: MobileWorkspaceListFilter,
        appliesRecencySort: Bool
    ) {
        self.query = query
        self.filter = filter
        self.activeFilter = activeFilter
        self.appliesRecencySort = appliesRecencySort
    }

    /// A search or a filter-menu filter flattens the list: no project block.
    var flattensList: Bool { !query.isEmpty || filter.isActive }
}

/// The Projects half of the iPhone's ONE workspace list, mirroring the Mac
/// sidebar: a slim PROJECTS caption, then each project (merged across Macs)
/// with its workspaces nested right under it, then the shell's own groups and
/// loose workspaces.
///
/// A pure projection. ``entries`` is the leading run of the table — fork rows
/// by id, and the shell's own workspace rows (rendered indented) by workspace
/// id. ``nestedWorkspaceIDs`` is the SAME set the flat list must hide, so
/// every workspace appears exactly once: the table drops a row whose id it
/// has already seen, so a workspace listed twice would vanish from its group.
public struct SupermuxProjectsListLayout: Sendable {
    /// One row of the leading run.
    public enum Entry: Equatable, Sendable {
        /// A fork row, drawn from ``forkRows``.
        case fork(String)
        /// One of the shell's workspace rows, nested under its project.
        case workspace(MobileWorkspacePreview.ID)
    }

    /// The leading run, top to bottom.
    public let entries: [Entry]
    /// Workspaces nested under a project — hidden from the flat list.
    public let nestedWorkspaceIDs: Set<MobileWorkspacePreview.ID>
    /// What each fork row draws, by its ``Entry/fork(_:)`` id.
    public let forkRows: [String: SupermuxProjectsTableRowValue]
    /// What each nested workspace row adds, by workspace id.
    public let accessories: [MobileWorkspacePreview.ID: SupermuxNestedWorkspaceAccessory]

    /// The swipe-tray ids of the rows on screen. A tray whose row left the
    /// list is closed (``SupermuxProjectsSectionModel/closeSwipeTray(unlessAmong:)``),
    /// so a row that comes back never reappears with its actions revealed.
    public var swipeableRowIDs: Set<String> {
        Set(forkRows.values.compactMap(\.swipeRowID))
    }

    /// No project block: the list is exactly the shell's own.
    public static let empty = SupermuxProjectsListLayout(entries: [], nestedWorkspaceIDs: [], forkRows: [:], accessories: [:])

    private init(
        entries: [Entry],
        nestedWorkspaceIDs: Set<MobileWorkspacePreview.ID>,
        forkRows: [String: SupermuxProjectsTableRowValue],
        accessories: [MobileWorkspacePreview.ID: SupermuxNestedWorkspaceAccessory]
    ) {
        self.entries = entries
        self.nestedWorkspaceIDs = nestedWorkspaceIDs
        self.forkRows = forkRows
        self.accessories = accessories
    }

    /// Projects the section and the shell's workspaces into the list.
    /// - Parameters:
    ///   - section: The Projects section's snapshot.
    ///   - workspaces: The shell's workspace rows, in its merged order.
    ///   - scope: How the list is narrowed.
    ///   - canEdit: Whether Add Project is available.
    ///   - preparingNewWorktreeProjectID: The row preparing a New Worktree sheet.
    public init(
        section: SupermuxProjectsSectionSnapshot,
        workspaces: [MobileWorkspacePreview],
        scope: SupermuxProjectsListScope,
        canEdit: Bool,
        preparingNewWorktreeProjectID: String?
    ) {
        guard section.isVisible, !scope.flattensList else {
            self = .empty
            return
        }
        let parsedMachines = MobileWorkspaceListFilter.parsedMachineEntries(scope.activeFilter.machines)
        func isShown(_ mac: SupermuxProjectsMacHeader) -> Bool {
            parsedMachines.isEmpty || parsedMachines.contains {
                $0.matches(deviceID: mac.macDeviceID ?? "", rowTag: mac.instanceTag)
            }
        }
        // The Macs in the phone's stable order, not foreground first: opening
        // a workspace on another Mac makes it the shell's foreground, and the
        // list must not reorder or move its cloud-Mac icons for that.
        let groups = Self.stableMacOrder(section.groups)
        let projects = SupermuxPhoneProjectMerge.merge(groups).compactMap { project in
            project.keeping { isShown($0.mac) }
        }
        // Scoped to one Mac that has no projects: no block at all, rather
        // than a "No projects yet" that is only true of that Mac.
        if !parsedMachines.isEmpty, section.hasLoaded, projects.isEmpty {
            self = .empty
            return
        }

        // The list's home Mac, the Mac sidebar's "this Mac": the first Mac
        // with projects in the stable order, which also leads every project it
        // holds. Rows on any other Mac carry the cloud-Mac icon; scoped to one
        // Mac, that Mac is home and none do.
        let homePairingID = groups.first { $0.isDisplayed && isShown($0.header) }?.header.pairingID
        var builder = Builder(homePairingID: homePairingID)
        builder.fork("header", .header(
            isCollapsed: section.isCollapsed,
            projectCount: section.isCollapsed && section.hasLoaded ? projects.count : nil,
            canEdit: canEdit
        ))
        let owned = Self.ownedWorkspaces(workspaces, matching: scope)
        for project in projects {
            let nested = Self.nested(in: project, owned: owned, scope: scope)
                .filter { !builder.nestedWorkspaceIDs.contains($0.id) }
            builder.nestedWorkspaceIDs.formUnion(nested.map(\.id))
            guard !section.isCollapsed else { continue }
            builder.add(project, nested: nested, preparingNewWorktreeProjectID: preparingNewWorktreeProjectID)
        }
        if !section.isCollapsed {
            if !section.hasLoaded {
                builder.fork("loading", .loading)
            } else if projects.isEmpty {
                builder.fork("empty", .empty(canEdit: canEdit))
            }
        }
        self.init(
            entries: builder.entries,
            nestedWorkspaceIDs: builder.nestedWorkspaceIDs,
            forkRows: builder.forkRows,
            accessories: builder.accessories
        )
    }

    /// The Macs in the phone's stable order: by the shell's per-Mac color
    /// slot, which a Mac keeps for the whole session whichever Mac is the
    /// foreground, then (for Macs without one) in display order. The
    /// section's own order puts the foreground Mac first, and the shell makes
    /// the Mac of every workspace the user opens the foreground.
    /// - Parameter groups: Every Mac's slice, in display order.
    static func stableMacOrder(_ groups: [SupermuxProjectsMacGroupSnapshot]) -> [SupermuxProjectsMacGroupSnapshot] {
        groups.enumerated()
            .sorted { ($0.element.header.colorIndex ?? .max, $0.offset) < ($1.element.header.colorIndex ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Loose, project-owned workspaces that pass the active filter, keyed by
    /// owning project row id (`pairing` + project id), in the shell's order.
    private static func ownedWorkspaces(
        _ workspaces: [MobileWorkspacePreview],
        matching scope: SupermuxProjectsListScope
    ) -> [String: [MobileWorkspacePreview]] {
        let parsedMachines = MobileWorkspaceListFilter.parsedMachineEntries(scope.activeFilter.machines)
        var owned: [String: [MobileWorkspacePreview]] = [:]
        for workspace in workspaces {
            // A workspace in a cmux group stays in its group.
            guard workspace.groupID == nil, let projectID = workspace.supermuxProjectID,
                  scope.activeFilter.matches(workspace, parsedMachines: parsedMachines) else { continue }
            let pairingID = SupermuxMacSeam.pairingID(
                macDeviceID: workspace.macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            owned[SupermuxProjectKey(pairingID: pairingID, projectID: projectID).rawValue, default: []]
                .append(workspace)
            // A single legacy session's rows are keyed by the bare project id.
            if !pairingID.isEmpty {
                owned[projectID, default: []].append(workspace)
            }
        }
        return owned
    }

    /// A project's nested workspaces: by Mac in the stable order, then each
    /// Mac's own order, pinned first (or by recent activity when sorting so).
    private static func nested(
        in project: SupermuxMergedProject,
        owned: [String: [MobileWorkspacePreview]],
        scope: SupermuxProjectsListScope
    ) -> [MobileWorkspacePreview] {
        var seen = Set<MobileWorkspacePreview.ID>()
        let rows = project.locations.flatMap { owned[$0.row.id] ?? [] }
            .filter { seen.insert($0.id).inserted }
        if scope.appliesRecencySort {
            return MobileWorkspaceRecencyOrder().displayOrder(rows)
        }
        return rows.filter(\.isPinned) + rows.filter { !$0.isPinned }
    }

    /// Accumulates the leading run.
    private struct Builder {
        /// The list's home Mac, whose rows carry no Mac icon.
        let homePairingID: String?
        var entries: [Entry] = []
        var nestedWorkspaceIDs = Set<MobileWorkspacePreview.ID>()
        var forkRows: [String: SupermuxProjectsTableRowValue] = [:]
        var accessories: [MobileWorkspacePreview.ID: SupermuxNestedWorkspaceAccessory] = [:]

        mutating func fork(_ id: String, _ value: SupermuxProjectsTableRowValue) {
            entries.append(.fork(id))
            forkRows[id] = value
        }

        /// The Mac a row on `mac` shows the icon for: `nil` on the home Mac.
        func remoteMac(_ mac: SupermuxProjectsMacHeader?) -> SupermuxRemoteMac? {
            guard let mac, mac.pairingID != homePairingID else { return nil }
            return SupermuxRemoteMac(mac: mac)
        }

        mutating func add(
            _ project: SupermuxMergedProject,
            nested: [MobileWorkspacePreview],
            preparingNewWorktreeProjectID: String?
        ) {
            let key = project.id
            let lead = project.lead
            fork("p:\(key)", .project(SupermuxMergedProjectRowValue(
                key: key,
                display: lead.row.merged(worktreeCount: project.worktreeCount, isExpanded: project.isExpanded),
                locationRowIDs: project.allRowIDs,
                showsWorktreeCreation: lead.showsWorktreeCreation,
                copies: project.locations.map { location in
                    SupermuxProjectCopyChoice(
                        rowID: location.row.id,
                        macName: location.mac.displayName,
                        isOnline: location.mac.status == .connected
                    )
                }
            )))
            for workspace in nested {
                entries.append(.workspace(workspace.id))
                let location = project.locations.first { $0.row.openWorkspaces.contains { $0.id == workspace.id.rawValue } }
                let snapshot = location?.row.openWorkspaces.first { $0.id == workspace.id.rawValue }
                accessories[workspace.id] = SupermuxNestedWorkspaceAccessory(
                    workspaceID: workspace.id.rawValue,
                    remoteMac: remoteMac(location?.mac),
                    branch: workspace.supermuxDisplayedBranch,
                    pullRequest: snapshot?.pullRequest,
                    isRunning: snapshot?.isRunning ?? false
                )
            }
            guard project.isExpanded else { return }
            addWorktrees(of: project, hasNestedWorkspaces: !nested.isEmpty, preparingNewWorktreeProjectID: preparingNewWorktreeProjectID)
        }

        private mutating func addWorktrees(
            of project: SupermuxMergedProject,
            hasNestedWorkspaces: Bool,
            preparingNewWorktreeProjectID: String?
        ) {
            let key = project.id
            var isLoading = false
            var worktreeCount = 0
            for location in project.locations {
                switch location.row.nestedWorktrees {
                case .unavailable:
                    continue
                case .loading:
                    isLoading = true
                case .loaded(let worktrees):
                    for worktree in worktrees {
                        worktreeCount += 1
                        fork("t:\(key):\(location.row.id):\(worktree.id)", .worktree(SupermuxNestedWorktreeRowValue(
                            projectRowID: location.row.id,
                            worktree: worktree,
                            remoteMac: remoteMac(location.mac)
                        )))
                    }
                }
            }
            if isLoading {
                fork("s:\(key)", .worktreeLoading)
            }
            let lead = project.lead
            if lead.showsWorktreeCreation {
                fork("n:\(key)", .newWorktree(
                    projectRowID: lead.row.id,
                    isPreparing: preparingNewWorktreeProjectID == lead.row.id
                ))
            } else if !isLoading, worktreeCount == 0, !hasNestedWorkspaces {
                fork("e:\(key)", .notice)
            }
        }
    }
}

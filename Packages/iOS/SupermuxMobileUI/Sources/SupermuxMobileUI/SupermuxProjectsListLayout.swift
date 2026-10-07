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
    /// The segment each draggable nested row moves in, by workspace id
    /// (see ``SupermuxNestedMove``). Empty when nested rows cannot be dragged.
    public let nestedSegments: [MobileWorkspacePreview.ID: String]

    /// The swipe-tray ids of the rows on screen. A tray whose row left the
    /// list is closed (``SupermuxProjectsSectionModel/closeSwipeTray(unlessAmong:)``),
    /// so a row that comes back never reappears with its actions revealed.
    public var swipeableRowIDs: Set<String> {
        Set(forkRows.values.compactMap(\.swipeRowID))
    }

    /// No project block: the list is exactly the shell's own.
    public static let empty = SupermuxProjectsListLayout(
        entries: [], nestedWorkspaceIDs: [], forkRows: [:], accessories: [:], nestedSegments: [:])

    private init(
        entries: [Entry],
        nestedWorkspaceIDs: Set<MobileWorkspacePreview.ID>,
        forkRows: [String: SupermuxProjectsTableRowValue],
        accessories: [MobileWorkspacePreview.ID: SupermuxNestedWorkspaceAccessory],
        nestedSegments: [MobileWorkspacePreview.ID: String]
    ) {
        self.entries = entries
        self.nestedWorkspaceIDs = nestedWorkspaceIDs
        self.forkRows = forkRows
        self.accessories = accessories
        self.nestedSegments = nestedSegments
    }

    /// Projects the section and the shell's workspaces into the list.
    /// - Parameters:
    ///   - section: The Projects section's snapshot.
    ///   - workspaces: The shell's workspace rows, in its merged order.
    ///   - scope: How the list is narrowed.
    ///   - canEdit: Whether Add Project is available.
    ///   - preparingNewWorktreeProjectID: The row preparing a New Worktree sheet.
    ///   - nestedOrder: The order segments show while a drag's move is on its
    ///     way to the Mac (``SupermuxNestedReorderModel/orders``).
    public init(
        section: SupermuxProjectsSectionSnapshot,
        workspaces: [MobileWorkspacePreview],
        scope: SupermuxProjectsListScope,
        canEdit: Bool,
        preparingNewWorktreeProjectID: String?,
        nestedOrder: [String: [MobileWorkspacePreview.ID]] = [:]
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
        // The list's home Mac, the Mac sidebar's "this Mac": the first Mac
        // with projects in the stable order, which also leads every project it
        // holds. Rows on any other Mac carry the cloud-Mac icon; scoped to one
        // Mac, that Mac is home and none do.
        let home = groups.first { $0.isDisplayed && isShown($0.header) }
        let projects = Self.homeOrder(
            SupermuxPhoneProjectMerge.merge(groups).compactMap { project in
                project.keeping { isShown($0.mac) }
            },
            home: home)
        // Scoped to one Mac that has no projects: no block at all, rather
        // than a "No projects yet" that is only true of that Mac.
        if !parsedMachines.isEmpty, section.hasLoaded, projects.isEmpty {
            self = .empty
            return
        }

        var builder = Builder(homePairingID: home?.header.pairingID)
        builder.fork("header", .header(
            isCollapsed: section.isCollapsed,
            projectCount: section.isCollapsed && section.hasLoaded ? projects.count : nil,
            canEdit: canEdit
        ))
        // The route each shown Mac's session uses, one line per Mac, even
        // while the block is folded: the merged list has no per-Mac headers.
        // A Mac that is reconnecting keeps its line, which shows that instead.
        let routed = groups.map(\.header).filter { ($0.route != nil || $0.status != .connected) && isShown($0) }
        if !routed.isEmpty {
            builder.fork("routes", .macRoutes(routed))
        }
        let owned = Self.ownedWorkspaces(workspaces, matching: scope)
        for project in projects {
            var nested = Self.nested(in: project, owned: owned, scope: scope)
                .filter { !builder.nestedWorkspaceIDs.contains($0.id) }
            builder.nestedWorkspaceIDs.formUnion(nested.map(\.id))
            guard !section.isCollapsed else { continue }
            // The recency order has no place on the Mac to send a drag to.
            if !scope.appliesRecencySort {
                let segments = Self.segments(of: nested, in: project)
                builder.nestedSegments.merge(segments) { first, _ in first }
                nested = Self.showing(nestedOrder, in: nested, segments: segments)
            }
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
            accessories: builder.accessories,
            nestedSegments: builder.nestedSegments
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

    /// The projects with the home Mac's in its sidebar order first; the rest
    /// keep theirs. Merging already leads with the first Mac's projects, so
    /// this matters when the list is scoped to another Mac.
    /// - Parameters:
    ///   - projects: The merged projects, in merge order.
    ///   - home: The list's home Mac.
    static func homeOrder(
        _ projects: [SupermuxMergedProject],
        home: SupermuxProjectsMacGroupSnapshot?
    ) -> [SupermuxMergedProject] {
        guard let home else { return projects }
        let rank = Dictionary(home.rows.enumerated().map { ($1.id, $0) }) { first, _ in first }
        func homeRank(_ project: SupermuxMergedProject) -> Int {
            project.locations.lazy.compactMap { rank[$0.row.id] }.first ?? .max
        }
        return projects.enumerated()
            .sorted { (homeRank($0.element), $0.offset) < (homeRank($1.element), $1.offset) }
            .map(\.element)
    }

    /// A project's nested workspaces as each Mac's sidebar shows them: by Mac
    /// in the stable order, then each Mac window's own order with its pinned
    /// rows first (or by recent activity when sorting so).
    private static func nested(
        in project: SupermuxMergedProject,
        owned: [String: [MobileWorkspacePreview]],
        scope: SupermuxProjectsListScope
    ) -> [MobileWorkspacePreview] {
        var seen = Set<MobileWorkspacePreview.ID>()
        let perMac = project.locations.map { location in
            (owned[location.row.id] ?? []).filter { seen.insert($0.id).inserted }
        }
        if scope.appliesRecencySort {
            return MobileWorkspaceRecencyOrder().displayOrder(perMac.flatMap { $0 })
        }
        return perMac.flatMap { rows in
            var windows: [String?] = []
            for row in rows where !windows.contains(row.windowID) {
                windows.append(row.windowID)
            }
            return windows.flatMap { window in
                let inWindow = rows.filter { $0.windowID == window }
                return inWindow.filter(\.isPinned) + inWindow.filter { !$0.isPinned }
            }
        }
    }

    /// The segment each nested row can be dragged in: one project, one Mac,
    /// one of its windows, one side of the pinned line. That run is in the
    /// Mac's own tab order, so a drag inside it is one move on that Mac.
    private static func segments(
        of nested: [MobileWorkspacePreview],
        in project: SupermuxMergedProject
    ) -> [MobileWorkspacePreview.ID: String] {
        var segments: [MobileWorkspacePreview.ID: String] = [:]
        for workspace in nested {
            let pairingID = SupermuxMacSeam.pairingID(
                macDeviceID: workspace.macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            let tier = workspace.isPinned ? "pinned" : "unpinned"
            segments[workspace.id] = [project.id, pairingID, workspace.windowID ?? "", tier]
                .joined(separator: "\u{1F}")
        }
        return segments
    }

    /// `nested` with each segment a move is on its way for in that move's
    /// order; rows the move does not know keep their place after it.
    private static func showing(
        _ nestedOrder: [String: [MobileWorkspacePreview.ID]],
        in nested: [MobileWorkspacePreview],
        segments: [MobileWorkspacePreview.ID: String]
    ) -> [MobileWorkspacePreview] {
        guard !nestedOrder.isEmpty else { return nested }
        var result: [MobileWorkspacePreview] = []
        var start = 0
        while start < nested.count {
            let segment = segments[nested[start].id]
            var end = start + 1
            while end < nested.count, segments[nested[end].id] == segment {
                end += 1
            }
            let run = nested[start..<end]
            if let segment, let order = nestedOrder[segment] {
                let rank = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
                result += run.enumerated()
                    .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
                    .map(\.element)
            } else {
                result += run
            }
            start = end
        }
        return result
    }

    /// Accumulates the leading run.
    private struct Builder {
        /// The list's home Mac, whose rows carry no Mac icon.
        let homePairingID: String?
        var entries: [Entry] = []
        var nestedWorkspaceIDs = Set<MobileWorkspacePreview.ID>()
        var forkRows: [String: SupermuxProjectsTableRowValue] = [:]
        var accessories: [MobileWorkspacePreview.ID: SupermuxNestedWorkspaceAccessory] = [:]
        var nestedSegments: [MobileWorkspacePreview.ID: String] = [:]

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

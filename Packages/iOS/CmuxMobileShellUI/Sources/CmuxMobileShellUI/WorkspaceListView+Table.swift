#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
// SUPERMUX:begin supermux-mobile-projects-table-row (fork Projects section hosted in one table row — see SUPERMUX-TOUCHPOINTS.md)
import SupermuxMobileUI
// SUPERMUX:end supermux-mobile-projects-table-row
import SwiftUI

extension WorkspaceListView {
    // SUPERMUX:begin supermux-mobile-projects-table-row (nil while disconnected, without supermux.projects.v1, or while searching/filtering — the table then emits exactly upstream's rows)
    /// The fork's merged Projects rows for the table, or `nil` when the list
    /// has no project block.
    var supermuxProjectsTablePayload: SupermuxProjectsTablePayload? {
        let layout = supermuxProjectsLayout
        guard !layout.entries.isEmpty else { return nil }
        return SupermuxProjectsTablePayload(
            layout: layout,
            actions: supermuxProjects.actions,
            moveNestedWorkspace: supermuxMoveNestedWorkspace
        )
    }
    // SUPERMUX:end supermux-mobile-projects-table-row

    /// Which copy the aggregated (All Computers) empty state gives. With SSH
    /// computers and no paired Mac, the Mac-pairing copy would describe a Mac
    /// the user does not have; any paired Mac keeps Macs the context.
    var emptyStateGuidance: WorkspaceListEmptyGuidance {
        WorkspaceListEmptyGuidance(
            hasSSHComputers: !(store?.sshComputers.hosts.isEmpty ?? true),
            hasPairedMacs: !displayPairedMacsForPicker.isEmpty
        )
    }

    var showsWorkspaceTableFilterEmptyRow: Bool {
        activeFilter.isActive
            && trimmedQuery.isEmpty
            && filteredWorkspaces.isEmpty
            && !workspaces.isEmpty
            // SUPERMUX:begin supermux-mobile-projects-table-row (rows nested under a project still show for this filter)
            && supermuxProjectsLayout.nestedWorkspaceIDs.isEmpty
            // SUPERMUX:end supermux-mobile-projects-table-row
    }

    func workspaceTableItems(
        groupedItems: [MobileWorkspaceListItem],
        // SUPERMUX:begin supermux-mobile-projects-table-row
        supermuxLayout: SupermuxProjectsListLayout = .empty
        // SUPERMUX:end supermux-mobile-projects-table-row
    ) -> [WorkspaceListTableItem] {
        var items: [WorkspaceListTableItem] = []
        switch connectionChrome {
        case .recoveryBanner:
            items.append(.chrome(.recoveryBanner))
        case .macStatusRow:
            items.append(.chrome(.macStatusRow))
        case .statusLine, .none:
            // The status line renders under the computers picker in the
            // toolbar, not as a list row; content stays uncovered.
            break
        }

        // SUPERMUX:begin supermux-mobile-projects-table-row (the merged Projects rows join the LEADING run: fork rows as chrome, nested workspaces as the shell's own indented rows; chromePrefixCount counts both — see supermux-mobile-projects-nested-reorder)
        items.append(contentsOf: supermuxLayout.entries.map { entry in
            switch entry {
            case .fork(let id):
                .chrome(.supermux(id))
            case .workspace(let id):
                .workspace(id, indented: true)
            }
        })
        // SUPERMUX:end supermux-mobile-projects-table-row

        if rendersGroupedSections {
            if groupedItems.isEmpty
                && trimmedQuery.isEmpty
                && !activeFilter.isActive
                && workspaces.isEmpty {
                items.append(.emptyWorkspaceList)
            } else {
                items.append(contentsOf: groupedItems.map { item in
                    switch item {
                    case .groupHeader(let group, _):
                        .groupHeader(group.id)
                    case .groupFooter(let groupID):
                        .groupFooter(groupID)
                    case .workspace(let workspace, let indented):
                        .workspace(workspace.id, indented: indented)
                    }
                })
            }
        } else if showsWorkspaceTableFilterEmptyRow {
            items.append(.filterEmpty)
        } else if trimmedQuery.isEmpty
            && !activeFilter.isActive
            && workspaces.isEmpty {
            items.append(.emptyWorkspaceList)
        } else {
            items.append(contentsOf: displayedFlatWorkspaces.map {
                .workspace($0.id, indented: false)
            })
        }
        return items
    }

    func workspaceTableGroupUnreadByID(
        groupedItems: [MobileWorkspaceListItem]
    ) -> [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] {
        var result: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] = [:]
        for item in groupedItems {
            if case .groupHeader(let group, let unread) = item {
                result[group.id] = unread
            }
        }
        return result
    }

    func workspaceTable(
        groupedItems: [MobileWorkspaceListItem],
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> WorkspaceListTable {
        let grouped = rendersGroupedSections
        let enablesReorder = enablesWorkspaceReorder
        // Bound outside the member-wise init: the ternary between `nil` and a
        // closure literal inside this large expression overwhelms the type
        // checker ("failed to produce diagnostic").
        let openChanges: (@MainActor (MobileWorkspacePreview) -> Void)? =
            store == nil
                ? nil
                : { @MainActor workspace in
                    openWorkspaceChanges(workspace)
                }
        // SUPERMUX:begin supermux-mobile-projects-table-row (bound outside the memberwise init — that expression already overwhelms the type checker, see the note above)
        let supermuxProjectsPayload = supermuxProjectsTablePayload
        let supermuxLayout = supermuxProjectsPayload?.layout ?? .empty
        // SUPERMUX:end supermux-mobile-projects-table-row
        let emptyStateRecoveryTarget = store?.workspaceListRecoveryTarget
        let emptyStateMacDeviceID = emptyStateRecoveryTarget?.macDeviceID
        let emptyStateMacInstanceTag = emptyStateRecoveryTarget?.instanceTag
        let isRetryOwnerCurrentOnDisappear: (() -> Bool)? = store.map { store in
            {
                let currentTarget = store.workspaceListRecoveryTarget
                if store.isRecoveringWorkspaceList {
                    return store.isWorkspaceListRecoveryOwned(
                        byMacDeviceID: emptyStateMacDeviceID,
                        instanceTag: emptyStateMacInstanceTag
                    )
                        && currentTarget?.macDeviceID == emptyStateMacDeviceID
                        && currentTarget?.instanceTag == emptyStateMacInstanceTag
                }
                return currentTarget?.macDeviceID == emptyStateMacDeviceID
                    && currentTarget?.instanceTag == emptyStateMacInstanceTag
            }
        }
        let shouldCancelRefreshOnDisappear: (() -> Bool)? = store.map { store in
            {
                let currentTarget = store.workspaceListRecoveryTarget
                return currentTarget?.macDeviceID == emptyStateMacDeviceID
                    && currentTarget?.instanceTag == emptyStateMacInstanceTag
                    && store.workspaces.isEmpty
                    // Hiding the empty row is itself part of the active
                    // recovery transition. Do not let that structural
                    // disappearance cancel the retry that owns recovery.
                    && !store.isRecoveringWorkspaceList
            }
        }
        let cancelRefreshForEmptyState: (() -> Void)? = store.map { store in
            {
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    ownerScoped: true
                )
            }
        } ?? cancelRefresh
        let cancelRefreshOnDisappearForEmptyState: (() -> Void)? = store.map { store in
            {
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    ownerScoped: true
                )
            }
        }
        let beginRefreshForEmptyState: (() -> UUID?)? = store.map { store in
            {
                store.prepareWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag
                )
            }
        }
        let cancelRefreshAttemptForEmptyState: ((UUID?) -> Void)? = store.map { store in
            { generation in
                store.cancelWorkspaceListRecovery(
                    forMacDeviceID: emptyStateMacDeviceID,
                    instanceTag: emptyStateMacInstanceTag,
                    expectedGeneration: generation,
                    ownerScoped: true
                )
            }
        } ?? cancelRefresh.map { suppliedCancel in
            { _ in suppliedCancel() }
        }
        return WorkspaceListTable(
            // SUPERMUX:begin supermux-mobile-projects-table-row (upstream passes only groupedItems)
            items: workspaceTableItems(groupedItems: groupedItems, supermuxLayout: supermuxLayout),
            // SUPERMUX:end supermux-mobile-projects-table-row
            workspacesByID: workspacesByID,
            groupsByID: groupsByID,
            groupUnreadByID: workspaceTableGroupUnreadByID(
                groupedItems: groupedItems
            ),
            filter: activeFilter,
            selectedWorkspaceID: selectedWorkspaceID,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            unreadBadgeDiameter: unreadBadgeDiameter,
            connectionStatus: connectionStatus,
            workspaceOwnerID: emptyStateMacDeviceID,
            workspaceOwnerInstanceTag: emptyStateMacInstanceTag,
            showsWorkspaceEmptyState: connectionChrome.showsWorkspaceEmptyState,
            emptyStateGuidance: emptyStateGuidance,
            workspaceChangesCapable: workspaceChangesCapable,
            workspaceChangeChipsByWorkspaceID: workspaceChangeChipsByWorkspaceID,
            openWorkspaceChanges: openChanges,
            // SUPERMUX:begin supermux-mobile-projects-table-row
            supermuxProjects: supermuxProjectsPayload,
            // SUPERMUX:end supermux-mobile-projects-table-row
            connectionRequiresReauth: store?.connectionRequiresReauth ?? false,
            connectionError: store?.connectionError,
            host: host,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTitle: initialConnectionTimedOut
                ? L10n.string("mobile.loading.timeout.title", defaultValue: "Still loading")
                : nil,
            initialConnectionDescription: initialConnectionTimedOut
                ? L10n.string(
                    "mobile.loading.timeout.message",
                    defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry."
                )
                : nil,
            enablesReorder: enablesReorder,
            moveRows: enablesReorder ? { sourceOffsets, destination in
                if grouped {
                    moveGroupedRows(from: sourceOffsets, to: destination)
                } else {
                    moveFlatRows(from: sourceOffsets, to: destination)
                }
            } : nil,
            canDropIntoGroup: enablesReorder && grouped ? { workspaceID, groupID in
                canJoinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            dropIntoGroup: enablesReorder && grouped ? { workspaceID, groupID in
                joinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            groupMoveMenu: enablesReorder && grouped ? { workspaceID in
                groupMoveMenu(for: workspaceID)
            } : nil,
            moveToGroup: enablesReorder && grouped ? { workspaceID, groupID in
                joinGroupAtEnd(workspaceID: workspaceID, groupID: groupID)
            } : nil,
            selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
            closeWorkspace: closeWorkspace,
            closeConfirmation: { workspaceCloseConfirmation(for: $0) },
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: requestWorkspaceRename,
            customizeRequest: requestWorkspaceCustomization,
            createWorkspaceInGroup: canCreateWorkspaceInGroups ? createWorkspaceInGroup : nil,
            renameWorkspaceGroup: renameWorkspaceGroup,
            renameWorkspaceGroupRequest: requestWorkspaceGroupRename,
            setGroupPinned: setGroupPinned,
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            ungroupWorkspaceGroupRequest: requestWorkspaceGroupUngroup,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            deleteWorkspaceGroupRequest: requestWorkspaceGroupDelete,
            toggleGroupCollapsed: toggleGroupCollapsed,
            showAll: {
                filter = .all
                macSelection = .all
            },
            signOut: signOut,
            retryInitialConnection: initialConnectionTimedOut ? retryInitialConnection : nil,
            showAddDevice: initialConnectionTimedOut ? showAddDevice : nil,
            reconnect: reconnect,
            refresh: refresh,
            cancelRefresh: cancelRefreshForEmptyState,
            cancelRefreshOnDisappear: cancelRefreshOnDisappearForEmptyState,
            beginRefresh: beginRefreshForEmptyState,
            cancelRefreshAttempt: cancelRefreshAttemptForEmptyState,
            cancelRefreshAttemptOnDisappear: cancelRefreshAttemptForEmptyState,
            shouldCancelRefreshOnDisappear: shouldCancelRefreshOnDisappear,
            isRetryOwnerCurrentOnDisappear: isRetryOwnerCurrentOnDisappear
        )
    }
}
#endif

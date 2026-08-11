import CmuxMobileSupport
// SUPERMUX:begin supermux-mobile-usage-button (fork usage-limits gauge — see SUPERMUX-TOUCHPOINTS.md)
import SupermuxMobileUI
// SUPERMUX:end supermux-mobile-usage-button
import SwiftUI

extension WorkspaceListView {
    var workspaceListFilterMenuActions: WorkspaceListFilterMenuActions {
        WorkspaceListFilterMenuActions(
            setReadState: { filter.readState = $0 },
            clearMachines: { filter.machines.removeAll() },
            toggleMachine: { filter.toggleMachine($0) },
            setSortMode: setWorkspaceSortMode
        )
    }

    #if os(iOS)
    /// The sort + filter entry point: one toolbar button opening the Mail-style
    /// view-options card (illustrated sort tiles + read-state rows; computer
    /// selection stays in its dedicated title picker). The icon fills while a
    /// narrowing filter is active, mirroring Mail.
    @ViewBuilder
    func viewOptionsButton() -> some View {
        Button {
            showingViewOptionsPopover = true
        } label: {
            Image(systemName: filter.isActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.filter", defaultValue: "Filter"))
        .accessibilityIdentifier("MobileWorkspaceFilterMenu")
        .onAppear {
            // Headless harnesses cannot tap the toolbar; let the layout-preview
            // fixture open the card at launch for screenshot verification.
            #if DEBUG
            if ProcessInfo.processInfo.environment[
                "CMUX_UITEST_WORKSPACE_LIST_PREVIEW_VIEW_OPTIONS"
            ] == "1" {
                showingViewOptionsPopover = true
            }
            #endif
        }
        .popover(isPresented: $showingViewOptionsPopover) {
            WorkspaceListViewOptionsPopover(
                filter: filter,
                sortMode: workspaceSortMenuMode,
                orderMachines: computerOrderSheetMachines,
                saveComputerOrder: setWorkspaceComputerPriority,
                actions: workspaceListFilterMenuActions
            )
        }
    }
    #endif

    @ViewBuilder
    func workspaceListWithToolbar<Content: View>(
        _ content: Content,
        machineSnapshots: WorkspaceMachineSnapshots,
        filterMachines: [WorkspaceFilterMachine]
    ) -> some View {
        #if os(iOS)
            // SUPERMUX:begin supermux-mobile-list-toolbar-identity (the toolbar condition MUST live inside the builder, never as an if/else around `content` — see SUPERMUX-TOUCHPOINTS.md)
            // `showsNavigationToolbar` is `navigationStyle != .push ||
            // compactNavigationPath.isEmpty` (`WorkspaceShellView.swift:495`),
            // so on the phone — where the style is always `.push` — it is
            // exactly `compactNavigationPath.isEmpty`: it flips false on every
            // push and true on every pop.
            //
            // This used to be `if showsNavigationToolbar { content.toolbar {…} }
            // else { content }`. Putting the same `content` in two branches of a
            // `_ConditionalContent` gives it a DIFFERENT structural identity per
            // branch, so entering or leaving a workspace tore down and rebuilt
            // everything inside — including `WorkspaceListTable`, a
            // `UIViewControllerRepresentable`. A fresh table controller meant a
            // scroll offset reset to zero, `attach()` clearing
            // `previousConfiguration`/`appliedItems` so the next `apply` saw
            // `structureChanged` and rebuilt every cell from scratch, and every
            // hosted `.task` re-firing (the Projects avatars visibly blanked).
            // Measured: a push+pop built the representable three times and moved
            // the offset 1200 → 0.
            //
            // Keeping ONE `content` and gating only the toolbar's CONTENT holds
            // the identity stable, so the table controller survives the
            // navigation and keeps its scroll position. This is the same shape
            // `WorkspaceShellView.swift:498` already uses for `rootToolbarContent`.
            content
                .toolbar {
                    if showsNavigationToolbar {
                        if !usesExternalSharedToolbar {
                            ToolbarItem(id: "workspace-list-settings", placement: .topBarLeading) {
                                settingsMenu
                            }
                            ToolbarItem(id: "workspace-list-title", placement: .principal) {
                                macTitlePicker(machineSnapshots: machineSnapshots)
                            }
                            if showsDevicesButton {
                                ToolbarItem(id: "workspace-list-devices", placement: .topBarLeading) {
                                    devicesButton
                                }
                            }
                        }
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            if let macUpdateHint, let dismissMacUpdateHint,
                               connectionChrome.showsMacUpdateHintIndicator {
                                MacUpdateHintIndicatorButton(
                                    hint: macUpdateHint,
                                    macDisplayName: macUpdateHintMacName,
                                    dismiss: dismissMacUpdateHint
                                )
                            }
                            // SUPERMUX:begin supermux-mobile-usage-button (fork usage-limits gauge, mirroring the Mac sidebar footer button — see SUPERMUX-TOUCHPOINTS.md)
                            // The session lives on the list (see the
                            // `.supermuxUsageDriver` fence in
                            // WorkspaceListView.swift), NOT here: this whole
                            // toolbar branch is torn down on every navigation
                            // push, so a store owned by the button would lose
                            // its snapshot and restart polling on every pop.
                            SupermuxUsageToolbarButton(model: supermuxUsage)
                            // SUPERMUX:end supermux-mobile-usage-button
                            viewOptionsButton()
                            if canCreateWorkspace {
                                newWorkspaceButton.equatable()
                            }
                        }
                    }
                }
            // SUPERMUX:end supermux-mobile-list-toolbar-identity
        #else
            content
                .toolbar {
                    ToolbarItemGroup {
                        WorkspaceListFilterMenu(
                            filter: filter,
                            machines: filterMachines,
                            actions: workspaceListFilterMenuActions
                        )
                        .equatable()
                        if canCreateWorkspace {
                            newWorkspaceButton.equatable()
                        }
                    }
                }
        #endif
    }
}

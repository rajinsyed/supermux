import Bonsplit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// "New Terminal to the Right" in a device mirror lands right of its tab on
/// both Macs.
///
/// A mirror's terminals are created on the Mac that owns the workspace, and the
/// mirror then adopts that Mac's tab order. Upstream sent no position with
/// `device.workspace.terminal.create`, so the owning Mac appended the tab and
/// the mirror moved it there too. Now an explicit spot travels with the request:
///
/// - Viewer: ``createTerminalToRight(of:inPane:in:focus:)`` routes the action to
///   the anchor tab's Mac with the tab index right of the anchor (the reserved
///   pane appears there at once); ``remember(_:destination:source:in:)`` notes
///   the other Mac's terminal left of that index for the request, and
///   ``afterSurfaceID(for:remoteWorkspaceID:on:catalog:)`` sends it as
///   `after_surface_id` when that Mac advertises `supermux.terminal_placement.v1`.
/// - Host: ``hostAnchor(_:surfaceIDs:direction:)`` validates the parameter and
///   ``place(_:at:inWorkspace:)`` moves the new tab right of that terminal before
///   the layout is captured, so the reply and the published layout carry it.
///
/// A plain new tab sends no position: both Macs append it.
@MainActor
enum SupermuxMirrorTerminalPlacement {
    nonisolated static let paramKey = "after_surface_id"

    /// The other Mac's terminal each positioned request goes right of, by
    /// request id. Kept for the request's retries, which must resend identical
    /// params; bounded, oldest first.
    private static var anchors: [UUID: String] = [:]
    private static var anchorOrder: [UUID] = []
    private static let anchorLimit = 64

    // MARK: - Viewer

    /// Routes "New Terminal to the Right" of a device-mirror tab to that tab's
    /// Mac. Nil when the anchor is not a device mirror's terminal (the caller
    /// keeps upstream's local path).
    static func createTerminalToRight(
        of anchor: TabID,
        inPane pane: PaneID,
        in workspace: Workspace,
        focus: Bool
    ) -> TerminalPanelCreationOutcome? {
        guard let panelID = workspace.panelIdFromSurfaceId(anchor),
              let source = workspace.cloudTerminalSourcePlacement(forPanel: panelID),
              source.machine.isDevice else { return nil }
        return workspace.routeCloudPaneTerminalCreate(
            source: source,
            sourcePanelID: panelID,
            destination: .tab(
                workspaceID: workspace.id,
                paneID: pane.id.uuidString,
                index: workspace.insertionIndexToRight(of: anchor, inPane: pane)
            ),
            focus: focus
        )
    }

    /// Notes the other Mac's terminal left of a device create's explicit tab
    /// index. Runs before the pane is reserved, so the tab left of `index` is
    /// still the one the user anchored on.
    static func remember(
        _ request: CloudTerminalCreationRequest,
        destination: SurfaceDestination,
        source: CloudTerminalSourcePlacement,
        in workspace: Workspace
    ) {
        guard source.machine.isDevice,
              case .tab(_, let rawPane, let index?) = destination, index > 0,
              let paneUUID = UUID(uuidString: rawPane),
              let pane = workspace.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else { return }
        let tabs = workspace.bonsplitController.tabs(inPane: pane)
        guard index <= tabs.count,
              let leftPanel = workspace.panelIdFromSurfaceId(tabs[index - 1].id),
              let left = workspace.cloudTerminalSourcePlacement(forPanel: leftPanel),
              left.machine == source.machine,
              let remoteTabID = left.remoteTabID else { return }
        anchors[request.id] = remoteTabID
        anchorOrder.append(request.id)
        if anchorOrder.count > anchorLimit { anchors.removeValue(forKey: anchorOrder.removeFirst()) }
    }

    /// The `after_surface_id` for a request: its remembered terminal, when it is
    /// in the request's remote workspace and that Mac places by it.
    static func afterSurfaceID(
        for request: CloudTerminalCreationRequest,
        remoteWorkspaceID: String,
        on machine: SurfaceMachineID,
        catalog: SurfaceCatalog
    ) -> String? {
        guard let anchor = anchors[request.id],
              catalog.resources[SurfaceResourceID(machine: machine, kind: .terminal, key: anchor)]?
                .remoteWorkspace?.id == remoteWorkspaceID,
              SupermuxComposition.devices.cachedHostCapabilities(on: machine)?
                .contains(SupermuxMobileCapability.terminalPlacementV1.rawValue) == true else { return nil }
        return anchor
    }

    // MARK: - Host

    /// Where a requested new tab goes.
    enum HostAnchor: Equatable {
        /// No position was asked for: the tab appends.
        case none
        /// Right of this terminal.
        case after(UUID)
        /// A position that is not a terminal of this workspace, or one asked for
        /// a split.
        case invalid
    }

    /// Reads `after_surface_id` from a `device.workspace.terminal.create`.
    static func hostAnchor(
        _ params: [String: Any],
        surfaceIDs: [String],
        direction: SurfaceSplitDirection?
    ) -> HostAnchor {
        guard let raw = params[paramKey] else { return .none }
        guard direction == nil, let string = raw as? String, let id = UUID(uuidString: string),
              surfaceIDs.contains(id.uuidString) else { return .invalid }
        return .after(id)
    }

    /// Moves a just-created tab right of its anchor, in the anchor's pane,
    /// without changing which tab that pane shows.
    static func place(_ terminalID: UUID, at anchor: HostAnchor, inWorkspace workspaceID: UUID) {
        guard case .after(let anchorID) = anchor,
              let workspace = Workspace.liveWorkspace(id: workspaceID),
              let pane = workspace.paneId(forPanelId: anchorID),
              workspace.paneId(forPanelId: terminalID) == pane,
              let anchorTab = workspace.surfaceIdFromPanelId(anchorID) else { return }
        workspace.reorderSurface(
            panelId: terminalID,
            toIndex: workspace.insertionIndexToRight(of: anchorTab, inPane: pane),
            focus: false
        )
    }
}

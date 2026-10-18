import CMUXMobileCore
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Adapts one window's `TabManager` state into shared-order rows: which rows
/// are own and which mirror another Mac, each row's key (store, pending or
/// record), tier and apply unit.
///
/// ```swift
/// let rows = SupermuxWorkspaceOrderRows(manager: manager, store: store, index: index, devices: devices, outbox: outbox)
/// SupermuxOrderArrangement().arrange(rows.applyItems)
/// ```
@MainActor
struct SupermuxWorkspaceOrderRows {
    /// The window's rows, in tab order.
    let rows: [SupermuxWorkspaceOrderRow]

    private static let orderKey = SupermuxOrderKey()

    init(
        manager: TabManager,
        store: SupermuxWorkspaceOrderStore,
        index: SupermuxDeviceWorkspaceIndex,
        devices: SupermuxDevices,
        outbox: SupermuxMirrorOrderOutbox
    ) {
        let groups = Dictionary(manager.workspaceGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = manager.tabs.map { workspace in
            let localGroup = workspace.groupId.flatMap { groups[$0] }
            let group = localGroup.map { "g:\($0.id.uuidString)" }
            let isRenderedPinned = localGroup?.isPinned ?? workspace.isPinned
            let tier = isRenderedPinned ? 0 : 1
            guard index.isDeviceMirror(workspace) else {
                return SupermuxWorkspaceOrderRow(
                    id: workspace.id,
                    stableID: workspace.stableId,
                    ref: nil,
                    isMirror: false,
                    isPinned: workspace.isPinned,
                    tier: tier,
                    key: store.key(forStableID: workspace.stableId),
                    pendingKey: nil,
                    canonicalID: workspace.id.uuidString,
                    canSendToOwner: false,
                    group: group,
                    unit: group ?? workspace.id.uuidString,
                    isFixed: true
                )
            }
            let ref = index.ref(forLocal: workspace)
            let record = ref.flatMap { devices.record(for: $0) }
            let recordKey = record?.supermuxOrderKey.flatMap { Self.orderKey.isValid($0) ? $0 : nil }
            let pendingKey = ref.flatMap { outbox.pendingKey(for: $0) }
            let key = pendingKey ?? recordKey
            let unit: String
            if let group {
                unit = group
            } else if let ref, let remoteGroup = record?.groupID {
                unit = "r:\(ref.machineID)/\(remoteGroup)/\(tier)"
            } else {
                unit = workspace.id.uuidString
            }
            return SupermuxWorkspaceOrderRow(
                id: workspace.id,
                stableID: workspace.stableId,
                ref: ref,
                isMirror: true,
                isPinned: workspace.isPinned,
                tier: tier,
                key: key,
                pendingKey: pendingKey,
                canonicalID: ref?.workspaceID ?? workspace.id.uuidString,
                // The owner places the key in its record's tier: a mirror drawn in
                // another tier (its own pin, or its local group's, differs) is local.
                canSendToOwner: recordKey != nil && record?.isPinned == workspace.isPinned
                    && record?.isPinned == isRenderedPinned,
                group: group,
                unit: unit,
                isFixed: localGroup != nil || key == nil
            )
        }
    }

    /// The rows for the capture planner.
    var captureRows: [SupermuxOrderCaptureRow<UUID>] {
        rows.map(\.captureRow)
    }

    /// The rows for apply: own, locally grouped and unkeyed rows fixed.
    var applyItems: [SupermuxOrderItem<UUID>] {
        rows.map { $0.applyItem() }
    }

    /// The row of a workspace.
    func row(_ id: UUID) -> SupermuxWorkspaceOrderRow? {
        rows.first { $0.id == id }
    }
}

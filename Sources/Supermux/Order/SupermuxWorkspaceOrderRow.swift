import Foundation
import SupermuxKit
import SupermuxMobileCore

/// One workspace row of a window as shared order sees it: an own row (this
/// Mac owns it and writes its key) or a mirror of another Mac's workspace
/// (placed by its owner's key). Built by ``SupermuxWorkspaceOrderRows``.
struct SupermuxWorkspaceOrderRow: Equatable {
    /// The local workspace.
    let id: UUID
    /// The local workspace's restart-stable id (the key store's key).
    let stableID: UUID
    /// The remote workspace a mirror shows; `nil` for an own row, or for a
    /// mirror whose remote workspace is not known yet.
    let ref: SupermuxRemoteWorkspaceRef?
    /// Whether the row mirrors another Mac's workspace.
    let isMirror: Bool
    /// The workspace's own pin (what `set_order` checks on the owner).
    let isPinned: Bool
    /// The rendered tier: `0` pinned (a grouped row takes its group's pin), `1` unpinned.
    let tier: Int
    /// The order key: the stored key of an own row; the pending key, else the
    /// record key, of a mirror.
    let key: String?
    /// A mirror's key still waiting for its owner's answer.
    let pendingKey: String?
    /// The owner's workspace id, uppercase.
    let canonicalID: String
    /// Whether a move of this mirror may ask its owner for the new key.
    let canSendToOwner: Bool
    /// The block the row moves with in apply: a local group, a remote group, or itself.
    let unit: String
    /// Whether apply leaves the row where it is: own rows, locally grouped
    /// rows and unkeyed mirrors.
    let isFixed: Bool

    /// The row for the capture planner.
    var captureRow: SupermuxOrderCaptureRow<UUID> {
        isMirror
            ? .mirror(id: id, tier: tier, key: key, canonicalID: canonicalID, canSendToOwner: canSendToOwner)
            : .own(id: id, tier: tier, key: key, canonicalID: canonicalID)
    }

    /// The row for the arrangement; `fixed` overrides the row's own rule.
    func applyItem(fixed: Bool? = nil, unit overriddenUnit: String? = nil) -> SupermuxOrderItem<UUID> {
        SupermuxOrderItem(
            id: id,
            tier: tier,
            sortKey: captureRow.sortKey,
            unit: overriddenUnit ?? unit,
            isFixed: fixed ?? isFixed
        )
    }
}

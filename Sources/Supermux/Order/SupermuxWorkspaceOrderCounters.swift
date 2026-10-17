import Foundation

/// What the workspace-order reconciler did since launch, for the DEBUG
/// `supermux.devices.order_state` command: an E2E checks that a move writes
/// exactly the keys it should and that an idle Mac writes none.
struct SupermuxWorkspaceOrderCounters {
    /// Passes that got past the gates (record ticks count too).
    var passes = 0
    /// Own keys written (capture and `set_order`).
    var ownKeyWrites = 0
    /// Own keys written, by workspace id.
    var ownKeyWritesByWorkspace: [UUID: Int] = [:]
    /// Apply reorders issued.
    var applies = 0
    /// `set_order` requests this Mac served.
    var setOrderReceived = 0
    /// `set_order` requests this Mac answered with an error.
    var setOrderRefused = 0

    /// Counts own key writes.
    mutating func recordWrites(_ workspaceIDs: [UUID]) {
        ownKeyWrites += workspaceIDs.count
        for id in workspaceIDs { ownKeyWritesByWorkspace[id, default: 0] += 1 }
    }
}

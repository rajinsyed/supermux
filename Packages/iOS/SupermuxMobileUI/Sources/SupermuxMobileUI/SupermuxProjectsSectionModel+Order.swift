public import CmuxMobileShellModel
import Foundation
import SupermuxMobileKit

/// The shared-order half of ``SupermuxProjectsSectionModel``: a nested row
/// dropped among other Macs' rows is sent to the Mac that owns it as a new
/// order key. Only the owner writes a workspace's key; every device then
/// shows the owner's answer.
extension SupermuxProjectsSectionModel {
    /// Sends a drop in an ordered segment (``SupermuxPhoneWorkspaceOrder/isOrdered(segment:)``)
    /// to the dragged row's owner Mac as `mobile.supermux.workspace.set_order`.
    /// - Parameters:
    ///   - move: The drop.
    ///   - rows: The shell's current rows: the new key falls between the
    ///     keys of the moved row's new neighbours there.
    /// - Returns: Whether the owner took the move. `false` when the row is
    ///   gone, its Mac is not connected or does not serve shared order, or
    ///   it refused (the row's pin changed meanwhile).
    public func sendOrderedMove(_ move: SupermuxNestedMove, in rows: [MobileWorkspacePreview]) async -> Bool {
        guard let row = rows.first(where: { $0.id == move.workspaceID }) else { return false }
        let key = SupermuxPhoneWorkspaceOrder().mintKey(for: move, in: rows, seed: orderOrigin)
        return await setWorkspaceOrder(row, key: key)
    }

    /// Lands a drop in an ordered segment: sends it to the owner Mac
    /// (``sendOrderedMove(_:in:)``), then waits until the shell's key-sorted
    /// rows (``SupermuxPhoneWorkspaceOrder/nested(_:)``) show it.
    /// - Parameters:
    ///   - move: The drop.
    ///   - shell: The shell whose rows the key is minted from and the move
    ///     is waited for in, or `nil` to count the owner's answer alone.
    ///   - rows: The rows to mint the key from when there is no shell.
    ///   - timeout: How long to wait for the shell's rows.
    /// - Returns: Whether the move landed: the owner took it and the shell's
    ///   rows show it within `timeout`.
    public func landOrderedMove(
        _ move: SupermuxNestedMove,
        shell: (any SupermuxWorkspaceShell)?,
        rows: [MobileWorkspacePreview],
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        guard await sendOrderedMove(move, in: shell?.workspaces ?? rows) else { return false }
        guard let shell else { return true }
        return await SupermuxNestedReorderModel.wait(upTo: timeout) {
            SupermuxNestedReorderPolicy().listHolds(move, SupermuxPhoneWorkspaceOrder().nested(shell.workspaces))
        }
    }

    /// Asks the row's owner Mac to give it `key` and move it there.
    /// - Parameters:
    ///   - row: The workspace row.
    ///   - key: Its new order key.
    /// - Returns: Whether the owner answered with success.
    func setWorkspaceOrder(_ row: MobileWorkspacePreview, key: String) async -> Bool {
        let pairingID = SupermuxMacSeam.pairingID(macDeviceID: row.macDeviceID, instanceTag: row.macInstanceTag)
        guard let session = session(forPairingID: pairingID), let client = session.client,
              session.capabilities?.supportsOrderSync == true else { return false }
        let request = SupermuxWorkspaceSetOrderRequest(
            workspaceID: row.rpcWorkspaceID.rawValue,
            orderKey: key,
            isPinned: row.isPinned
        )
        return (try? await client.workspaceSetOrder(request)) != nil
    }
}

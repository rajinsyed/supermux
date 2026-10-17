import CmuxCloud
import Foundation
import SupermuxKit

/// App-wide instances for one shared workspace order across Macs and the
/// phone, built once, on first use, with their dependencies injected.
@MainActor
extension SupermuxComposition {
    /// The order key of every workspace this Mac owns (this app's defaults domain).
    static let workspaceOrderStore = SupermuxWorkspaceOrderStore(defaults: .standard)

    /// Moved mirrors' keys on their way to their owners.
    static let mirrorOrderOutbox = SupermuxMirrorOrderOutbox(devices: devices)

    /// Capture and apply for every window.
    static let workspaceOrder = SupermuxWorkspaceOrderReconciler(
        store: workspaceOrderStore,
        devices: devices,
        index: deviceWorkspaceIndex,
        outbox: mirrorOrderOutbox,
        origin: "mac:\(MobileHostIdentity.deviceID().lowercased())@\(MobileHostIdentity.instanceTag())"
    )

    /// The owner's side of `mobile.supermux.workspace.set_order`.
    static let workspaceOrderHost = SupermuxWorkspaceOrderHost(
        reconciler: workspaceOrder,
        index: deviceWorkspaceIndex
    )
}

import CmuxCloud
import Foundation
import SupermuxKit

/// App-wide instances for one shared workspace order across Macs and the
/// phone, built once, on first use, with their dependencies injected.
@MainActor
extension SupermuxComposition {
    /// This Mac in shared order: the seed of its first workspace keys and the
    /// origin of its project order stamps, `mac:<device>@<tag>`.
    static let orderOrigin = "mac:\(MobileHostIdentity.deviceID().lowercased())@\(MobileHostIdentity.instanceTag())"

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
        origin: orderOrigin
    )

    /// The owner's side of `mobile.supermux.workspace.set_order`.
    static let workspaceOrderHost = SupermuxWorkspaceOrderHost(
        reconciler: workspaceOrder,
        index: deviceWorkspaceIndex
    )
}

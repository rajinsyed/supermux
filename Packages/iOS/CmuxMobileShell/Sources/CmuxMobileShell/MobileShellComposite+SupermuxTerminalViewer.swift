// SUPERMUX:begin sizing-phone-viewer (the phone that views a terminal owns its grid in Auto — see SUPERMUX-TOUCHPOINTS.md)
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import CmuxTerminalSizing
internal import Foundation

/// Store reads and routes behind the phone's terminal viewport reports, so a
/// terminal is never left at this phone's size once it stops viewing it.
extension MobileShellComposite {
    /// Whether viewport reports have no Mac connection to go to. A report
    /// dropped for this reason is not retried on the bounded relay backoff:
    /// the next connection re-reports every mounted terminal
    /// (`supermuxRemoteClientGeneration`).
    public var supermuxTerminalViewportOffline: Bool { remoteClient == nil }

    // MARK: Lease owner

    /// Forgets which Mac holds the surface's viewport lease and returns it:
    /// the Mac its last report was prepared for, else the foreground Mac.
    /// - Parameter surfaceID: The terminal surface id.
    /// - Returns: The Mac whose lease a clear must release.
    func supermuxTakeViewportLeaseOwner(surfaceID: String) -> MacPairingKey {
        supermuxViewportLeaseOwnersBySurfaceID.removeValue(forKey: surfaceID) ?? foregroundMacKey
    }

    /// The surface's workspace on the Mac that holds its lease.
    /// - Parameters:
    ///   - surfaceID: The terminal surface id.
    ///   - ownerKey: The Mac that holds the lease.
    /// - Returns: The workspace row id, or `nil` when that Mac lists none.
    func supermuxViewportWorkspaceID(
        forTerminalID surfaceID: String,
        ownerKey: MacPairingKey
    ) -> MobileWorkspacePreview.ID? {
        guard ownerKey != foregroundMacKey else { return workspaceID(forTerminalID: surfaceID) }
        return workspaceID(
            forTerminalID: surfaceID,
            macDeviceID: ownerKey.canonicalMacDeviceID,
            instanceTag: ownerKey.normalizedInstanceTag
        )
    }

    /// The live connection to the Mac that holds a lease: the foreground
    /// client, or the Mac's secondary connection after the phone switched.
    /// `nil` when that Mac is not connected (it drops the lease with the
    /// connection).
    /// - Parameter ownerKey: The Mac that holds the lease.
    /// - Returns: The client to send the clear on.
    func supermuxViewportClient(ownerKey: MacPairingKey) -> MobileCoreRPCClient? {
        ownerKey == foregroundMacKey ? remoteClient : secondaryMacSubscriptions[ownerKey]?.client
    }

    // MARK: Detached

    /// Shows the Detached card when the Mac refuses a terminal request with
    /// `detached`: it still holds a Disconnect for this phone that the phone
    /// forgot (a relaunch keeps no sizing state), so the user gets Reattach
    /// back instead of a terminal stuck at the Mac's size.
    /// - Parameters:
    ///   - code: The RPC error code.
    ///   - surfaceID: The terminal surface id.
    /// - Returns: `true` when the code was `detached`.
    @discardableResult
    func supermuxApplyTerminalDetached(ifCode code: String?, surfaceID: String) -> Bool {
        guard code == "detached" else { return false }
        if terminalAllowsTraffic(surfaceID: surfaceID) {
            // The refusal carries no actor or time; the card shows the
            // detach without them.
            applyTerminalDetached(MobileTerminalDetachedEvent(
                surfaceID: surfaceID,
                reason: .disconnectedBy(nil),
                at: nil
            ))
        }
        return true
    }

    /// ``supermuxApplyTerminalDetached(ifCode:surfaceID:)`` for a thrown error.
    /// - Parameters:
    ///   - error: The request's error.
    ///   - surfaceID: The terminal surface id.
    /// - Returns: `true` when the error was a `detached` refusal.
    @discardableResult
    func supermuxApplyTerminalDetached(ifError error: any Error, surfaceID: String) -> Bool {
        guard case let .rpcError(code, _)? = error as? MobileShellConnectionError else { return false }
        return supermuxApplyTerminalDetached(ifCode: code, surfaceID: surfaceID)
    }
}
// SUPERMUX:end sizing-phone-viewer

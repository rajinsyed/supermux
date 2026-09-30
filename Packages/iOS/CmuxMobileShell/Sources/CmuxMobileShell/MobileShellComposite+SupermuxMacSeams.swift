// SUPERMUX:begin supermux-mobile-mac-seams (per-Mac Supermux seams: one per live pairing, foreground + control — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
public import CmuxMobileRPC
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
public import SupermuxMobileKit

/// Builds the fork's per-Mac seams from the shell's connection pool.
///
/// Mirrors `captureTaskModelRequestContext`: the foreground pairing serves
/// through `remoteClient`, every background pairing through its control
/// subscription's client. Nothing here mutates shell state.
extension MobileShellComposite {
    /// One Supermux seam per live Mac pairing — the foreground Mac (only
    /// while connected, like ``supermuxConnectionSeam``) plus every
    /// background control subscription — foreground first, then by name.
    public var supermuxConnectionSeams: [SupermuxMacSeam] {
        buildSupermuxMacSeams()
    }

    /// The `(client, capabilities)` seam of the Mac that owns a workspace row,
    /// so per-workspace tools talk to that Mac even before (or without) it
    /// becoming the foreground. `nil` when that Mac has no live connection.
    /// - Parameters:
    ///   - macDeviceID: The row's `macDeviceID` (`nil` for an unowned row,
    ///     which resolves to the foreground seam).
    ///   - instanceTag: The row's `macInstanceTag`.
    public func supermuxConnectionSeam(
        forMacDeviceID macDeviceID: String?,
        instanceTag: String?
    ) -> (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)? {
        supermuxMacSeam(forMacDeviceID: macDeviceID, instanceTag: instanceTag)
            .map { ($0.client, $0.hostCapabilities) }
    }

    func buildSupermuxMacSeams() -> [SupermuxMacSeam] {
        var seams: [SupermuxMacSeam] = []
        var foregroundKey: MacPairingKey?
        if connectionState == .connected, let remoteClient {
            let key = foregroundMacDeviceID == nil ? nil : foregroundMacKey
            foregroundKey = key
            seams.append(SupermuxMacSeam(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: foregroundMacDeviceID == nil ? nil : activeMacInstanceTag,
                displayName: supermuxSeamDisplayName(
                    key: key ?? .anonymousForeground,
                    fallback: focusedForegroundConnection?.displayName
                ),
                colorIndex: key.flatMap { stableMacColorSlots[$0.pairingID] },
                customColor: key.flatMap(supermuxSeamCustomColor(key:)),
                client: remoteClient,
                hostCapabilities: supportedHostCapabilities,
                status: .connected,
                isForeground: true
            ))
        }
        let controlSeams = secondaryMacSubscriptions.compactMap { ownerKey, subscription -> SupermuxMacSeam? in
            guard ownerKey != foregroundKey, subscription.client !== remoteClient else { return nil }
            return SupermuxMacSeam(
                macDeviceID: ownerKey.canonicalMacDeviceID,
                instanceTag: ownerKey.normalizedInstanceTag,
                displayName: supermuxSeamDisplayName(key: ownerKey, fallback: subscription.displayName),
                colorIndex: stableMacColorSlots[ownerKey.pairingID],
                customColor: supermuxSeamCustomColor(key: ownerKey),
                client: subscription.client,
                hostCapabilities: subscription.supportedHostCapabilities,
                status: Self.supermuxSeamStatus(workspacesByMac[ownerKey]?.status),
                isForeground: false
            )
        }
        return seams + controlSeams.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// The seam that owns a workspace row: the exact pairing, else the only
    /// seam on that device when the row's or the seam's tag is missing (a
    /// legacy untagged pairing); the foreground seam for an unowned row.
    ///
    /// Never a sibling build with a different explicit tag: Stable and
    /// Nightly are separate app instances whose workspace and pane ids mean
    /// nothing to each other, so an offline build's rows get no seam.
    func supermuxMacSeam(forMacDeviceID macDeviceID: String?, instanceTag: String?) -> SupermuxMacSeam? {
        let seams = buildSupermuxMacSeams()
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return seams.first(where: \.isForeground)
        }
        let pairingID = SupermuxMacSeam.pairingID(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if let exact = seams.first(where: { $0.pairingID == pairingID }) { return exact }
        let rowKey = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        let sameDevice = seams.filter { seam in
            guard let seamDeviceID = seam.macDeviceID, rowKey.isOnDevice(seamDeviceID) else { return false }
            let seamKey = MacPairingKey(macDeviceID: seamDeviceID, instanceTag: seam.instanceTag)
            return rowKey.normalizedInstanceTag == nil || seamKey.normalizedInstanceTag == nil
        }
        return sameDevice.count == 1 ? sameDevice[0] : nil
    }

    private func supermuxSeamDisplayName(key: MacPairingKey, fallback: String?) -> String {
        let candidates = [
            workspacesByMac[key]?.displayName,
            fallback,
            pairedMacs.first { MacPairingKey($0) == key }?.resolvedName,
        ]
        for candidate in candidates {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return key.canonicalMacDeviceID
    }

    private func supermuxSeamCustomColor(key: MacPairingKey) -> String? {
        pairedMacs.first { MacPairingKey($0) == key }?.customColor
    }

    private static func supermuxSeamStatus(_ status: MobileMacConnectionStatus?) -> SupermuxMacSeam.Status {
        switch status {
        case .connected: .connected
        case .unavailable: .unavailable
        case .reconnecting, nil: .reconnecting
        }
    }
}
// SUPERMUX:end supermux-mobile-mac-seams

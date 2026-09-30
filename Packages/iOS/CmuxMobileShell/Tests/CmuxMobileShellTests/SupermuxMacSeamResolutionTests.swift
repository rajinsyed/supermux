// SUPERMUX:begin supermux-mobile-mac-seams
import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Which Mac a workspace row's Supermux tools (Changes, Files, pane actions)
/// talk to. Stable and Nightly on one physical Mac are two app instances
/// whose workspace and pane ids mean nothing to each other.
@MainActor
@Suite struct SupermuxMacSeamResolutionTests {
    /// Stable's link is down while its rows stay listed, and Nightly on the
    /// same Mac is live: Stable's tools must hide, not send Stable's ids to
    /// the Nightly process.
    @Test func anOfflineBuildNeverBorrowsItsSiblingsSeam() async throws {
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter())
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-sibling",
            instanceTag: "nightly",
            router: RoutingHostRouter()
        )

        #expect(store.supermuxConnectionSeam(forMacDeviceID: "mac-sibling", instanceTag: "stable") == nil)
        #expect(store.supermuxConnectionSeam(forMacDeviceID: "mac-sibling", instanceTag: "nightly") != nil)
    }

    /// A legacy untagged pairing whose Mac stamps a tag on its rows is still
    /// that Mac: the device's only seam serves it.
    @Test func aLegacyUntaggedPairingServesItsTaggedRows() async throws {
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter())
        try installSecondaryClient(
            on: store,
            macDeviceID: "mac-legacy",
            instanceTag: nil,
            router: RoutingHostRouter()
        )

        #expect(store.supermuxConnectionSeam(forMacDeviceID: "mac-legacy", instanceTag: "default") != nil)
    }
}
// SUPERMUX:end supermux-mobile-mac-seams

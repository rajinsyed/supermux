import CmuxSettings
import Foundation
import SupermuxKit

/// Turns remote Macs on by default for the Supermux release identity
/// (`com.supermux.app`), called from the `supermux-release-devices-defaults`
/// touchpoint in `CmuxFeatureFlags.init` (SUPERMUX-TOUCHPOINTS.md #520), right
/// after #514 seeds the Cloud flag override.
///
/// Seeds, once and only where no value is stored: Beta › Cloud Machines,
/// Discover other Macs, and Make this Mac discoverable. A choice the user makes
/// later (on or off) is never overwritten, and a removed value is not re-seeded.
enum SupermuxDevicesDefaults {
    /// Records that the release seed ran.
    static let releaseSeedMarker = "supermux.devices.releaseDefaultsSeeded.v1"

    /// Seeds the Devices opt-ins once for the Supermux release identity.
    /// - Returns: The keys written (empty when not the release identity or already seeded).
    @discardableResult
    static func seedReleaseDefaultsIfNeeded(isSupermuxRelease: Bool, defaults: UserDefaults) -> [String] {
        guard isSupermuxRelease else { return [] }
        let devicesSection = DevicesCatalogSection()
        return SupermuxDefaultsSeed.applyOnce(
            [
                BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey: true,
                devicesSection.discoveryEnabled.userDefaultsKey: true,
                devicesSection.incomingAccessEnabled.userDefaultsKey: true,
            ],
            marker: releaseSeedMarker,
            defaults: defaults
        )
    }
}

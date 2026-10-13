import Foundation

/// Gate for the per-user (cross-team) Mac directory. It applies only where
/// My Devices is available, and its remote flag is the rollback switch:
/// turning it off returns discovery and admission to the team directory alone.
/// It never affects iOS pairing, which stays on the team authority.
enum AccountMacDirectoryFeature {
    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        // SUPERMUX:begin same-team-remote-macs
        // Keep Remote Macs on the team directory and team admission authority.
        // Short-circuit the account gate without changing phone pairing policy.
        false && DevicesFeature.isAvailable(defaults: defaults)
            && CmuxFeatureFlags.offMainEffectiveValue(for: CmuxFeatureFlags.macAccountDirectoryFlag)
        // SUPERMUX:end same-team-remote-macs
    }
}

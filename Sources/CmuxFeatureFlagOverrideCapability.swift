import CmuxSettings
import Foundation

/// Grants the Cloud-only dogfood exception from the installed app identity.
/// Display names, environment variables and persisted defaults cannot grant it.
struct CmuxFeatureFlagOverrideCapability: Equatable, Sendable {
    let allowsCloudOverride: Bool
    let enablesCloudDogfood: Bool
    let isDebugBuild: Bool
    let isTaggedDebugArtifact: Bool
    let hasCloudDogfoodMarker: Bool
    // SUPERMUX:begin supermux-release-cloud-override
    /// The fork's own release identity. Upstream's `cloud-machines-enabled-release`
    /// rollout does not include Supermux accounts, so this identity may enable
    /// Cloud locally (Mac-to-Mac My Devices sits behind the same gate).
    let isSupermuxRelease: Bool
    // SUPERMUX:end supermux-release-cloud-override

    init(bundle: Bundle = .main) {
        #if DEBUG
        let marker = bundle.object(forInfoDictionaryKey: "CMUXCloudDogfoodEnabled") as? Bool
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: true,
                  cloudDogfoodRequested: marker == true,
                  cloudDogfoodMarkerPresent: marker != nil)
        #else
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: false)
        #endif
    }

    init(
        bundleIdentifier: String?,
        isDebugBuild: Bool,
        cloudDogfoodRequested: Bool = false,
        cloudDogfoodMarkerPresent: Bool = false
    ) {
        self.isDebugBuild = isDebugBuild
        self.hasCloudDogfoodMarker = cloudDogfoodMarkerPresent
        // Only the shipping Nightly identity grants the exception in Release.
        // Debug also requires a debug bundle, so stable/staging identities fail closed.
        let debugID = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        isTaggedDebugArtifact = isDebugBuild && bundleIdentifier?.hasPrefix(debugID + ".") == true
        // SUPERMUX:begin supermux-release-cloud-override
        isSupermuxRelease = bundleIdentifier == "com.supermux.app"
        // (upstream: no `isSupermuxRelease ||` term)
        allowsCloudOverride = isSupermuxRelease
            || bundleIdentifier == SocketPathMarkerFiles.nightlyBundleIdentifier
            || (isDebugBuild && (bundleIdentifier == debugID
                || bundleIdentifier?.hasPrefix(debugID + ".") == true))
        // SUPERMUX:end supermux-release-cloud-override
        enablesCloudDogfood = cloudDogfoodRequested && isDebugBuild
            && bundleIdentifier?.hasPrefix(debugID + ".") == true
    }

    func policy(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagOverridePolicy {
        guard definition.key == CmuxFeatureFlags.cloudMachinesFlag.key else { return .remoteFirst }
        return allowsCloudOverride ? .localFirst : .disabled
    }
}

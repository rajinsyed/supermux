import CMUXMobileCore
import Foundation

/// Persists the one exact iOS app targeted by this Mac's pairing and pushes.
@MainActor
struct MobileIOSPairingTargetStore {
    static let defaultsKey = "mobile.pairing.targetIOSBundleIdentifier"

    private let defaults: UserDefaults
    private let macInstanceTag: String
    // SUPERMUX:begin supermux-release-mobile-identity
    private let macBundleIdentifier: String?
    // SUPERMUX:end supermux-release-mobile-identity

    init(
        defaults: UserDefaults = .standard,
        macInstanceTag: String = MobileHostIdentity.instanceTag(),
        // SUPERMUX:begin supermux-release-mobile-identity
        macBundleIdentifier: String? = Bundle.main.bundleIdentifier
        // SUPERMUX:end supermux-release-mobile-identity
    ) {
        self.defaults = defaults
        self.macInstanceTag = macInstanceTag
        // SUPERMUX:begin supermux-release-mobile-identity
        self.macBundleIdentifier = macBundleIdentifier
        // SUPERMUX:end supermux-release-mobile-identity
    }

    var availableNamespaces: [MobileIOSAppNamespace] {
        // SUPERMUX:begin supermux-release-mobile-identity
        if isSupermuxReleaseLane {
            return ["com.supermux.ios"].compactMap(
                MobileIOSAppNamespace.init(bundleIdentifier:)
            )
        }
        // SUPERMUX:end supermux-release-mobile-identity
        if !isOfficialMacLane {
            return [
                MobileIOSAppNamespace(
                    pairedMacInstanceTag: macInstanceTag
                ),
            ].compactMap { $0 }
        }
        return [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ].compactMap(MobileIOSAppNamespace.init(bundleIdentifier:))
    }

    var selectedNamespace: MobileIOSAppNamespace? {
        let available = availableNamespaces
        return storedNamespace(in: available) ?? available.first
    }

    /// Exact push target. An unset official Mac resolves to the App Store lane.
    var pushTargetNamespace: MobileIOSAppNamespace? {
        selectedNamespace
    }

    var selectedPairingURLScheme: CmxPairingURLScheme? {
        guard let selectedNamespace else { return nil }
        return CmxPairingURLScheme(
            iOSBundleIdentifier: selectedNamespace.bundleIdentifier
        )
    }

    @discardableResult
    func select(_ namespace: MobileIOSAppNamespace) -> Bool {
        guard availableNamespaces.contains(namespace) else { return false }
        defaults.set(namespace.bundleIdentifier, forKey: Self.defaultsKey)
        return true
    }

    // SUPERMUX:begin supermux-release-mobile-identity
    private var isSupermuxReleaseLane: Bool {
        guard isOfficialMacLane else { return false }
        return macBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "com.supermux.app"
    }
    // SUPERMUX:end supermux-release-mobile-identity

    private var isOfficialMacLane: Bool {
        switch macInstanceTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "default", "nightly":
            true
        default:
            false
        }
    }

    private func storedNamespace(
        in available: [MobileIOSAppNamespace]
    ) -> MobileIOSAppNamespace? {
        guard let stored = defaults.string(forKey: Self.defaultsKey),
              let namespace = MobileIOSAppNamespace(
                  bundleIdentifier: stored
              ),
              available.contains(namespace) else {
            return nil
        }
        return namespace
    }
}

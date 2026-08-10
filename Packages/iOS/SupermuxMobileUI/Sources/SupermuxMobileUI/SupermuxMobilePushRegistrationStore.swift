public import Foundation
public import SupermuxMobileKit

/// Persists the iPhone's APNs token and mirrors its opt-in state to the paired Mac.
@MainActor
public struct SupermuxMobilePushRegistrationStore {
    /// The fixed bundle identifier used by `scripts/supermux-ios-release.sh`.
    nonisolated public static let bundleID = "com.supermux.ios"

    private static let deviceTokenKey = "supermux.apns.deviceToken"
    private static let pushEnabledKey = "cmux.notifications.pushEnabled"
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let currentBundleID: String?

    /// Creates the registration store.
    ///
    /// - Parameters:
    ///   - defaults: Persistence shared with ``MobilePushCoordinator``.
    ///   - notificationCenter: Change notifications for the defaults store.
    ///   - currentBundleID: The signed application's bundle identifier.
    public init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        currentBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.currentBundleID = currentBundleID
    }

    /// Stores a newly issued APNs token for the paired-Mac synchronization loop.
    /// - Parameter deviceToken: The opaque token supplied by UIKit.
    public func record(deviceToken: Data) {
        defaults.set(deviceToken.map { String(format: "%02x", $0) }.joined(), forKey: Self.deviceTokenKey)
    }

    /// Mirrors the current token and later opt-in changes until cancelled.
    ///
    /// This loop is inert unless the host advertises `supermux.phone_push.v1`
    /// and the signed app is the fixed-identity Supermux installation.
    ///
    /// - Parameters:
    ///   - client: The paired Mac's phone-push registration seam.
    ///   - capabilities: The connected host's capability snapshot.
    public func run(
        client: any SupermuxPhonePushRegistering,
        capabilities: SupermuxMobileCapabilities
    ) async {
        guard capabilities.supportsPhonePush,
              currentBundleID == Self.bundleID else { return }

        var lastSent: Snapshot?
        await synchronizeIfChanged(client: client, lastSent: &lastSent)
        for await _ in notificationCenter.notifications(named: UserDefaults.didChangeNotification) {
            guard !Task.isCancelled else { return }
            await synchronizeIfChanged(client: client, lastSent: &lastSent)
        }
    }

    private func synchronizeIfChanged(
        client: any SupermuxPhonePushRegistering,
        lastSent: inout Snapshot?
    ) async {
        guard let snapshot = snapshot(), snapshot != lastSent else { return }
        do {
            _ = try await client.registerPhonePush(snapshot.request)
            lastSent = snapshot
        } catch {
            // Keep the snapshot unsent so a later defaults change or reconnect retries.
        }
    }

    private func snapshot() -> Snapshot? {
        guard let token = defaults.string(forKey: Self.deviceTokenKey),
              Self.isValidToken(token) else { return nil }
        let enabled = defaults.object(forKey: Self.pushEnabledKey) as? Bool ?? true
        return Snapshot(token: token, enabled: enabled)
    }

    private static func isValidToken(_ token: String) -> Bool {
        (64 ... 200).contains(token.count)
            && token.allSatisfy { $0.isHexDigit }
    }

    private struct Snapshot: Equatable {
        let token: String
        let enabled: Bool

        var request: SupermuxPhonePushRegistrationRequest {
            // The fixed-identity install is Ad Hoc distribution-signed with
            // aps-environment=production; sandbox delivery proved best-effort
            // (silently dropped pushes to the backgrounded app).
            SupermuxPhonePushRegistrationRequest(
                deviceToken: token.lowercased(),
                bundleID: SupermuxMobilePushRegistrationStore.bundleID,
                environment: .production,
                enabled: enabled
            )
        }
    }
}

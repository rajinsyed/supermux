public import Foundation
public import SupermuxMobileKit

/// Persists the iPhone's APNs token and mirrors its opt-in state to the paired Mac.
@MainActor
public struct SupermuxMobilePushRegistrationStore {
    /// The fixed bundle identifier used by `scripts/supermux-ios-release.sh`.
    nonisolated public static let bundleID = "com.supermux.ios"

    private static let deviceIDKey = "supermux.apns.deviceID"
    private static let deviceTokenKey = "supermux.apns.deviceToken"
    private static let registeredDeviceTokenKey = "supermux.apns.registeredDeviceToken"
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
    /// The phone runs one loop per connected Mac, so a Mac that is never the
    /// foreground (the remote MacBook running the agents) can still push. Each
    /// Mac's last reported token (sent enabled or not) is remembered under its
    /// own key: rotating the token on one Mac must not erase another Mac's
    /// record of the old token, or that Mac would never be told to drop it.
    ///
    /// - Parameters:
    ///   - client: The paired Mac's phone-push registration seam.
    ///   - capabilities: The connected host's capability snapshot.
    ///   - pairingID: The Mac pairing this loop registers with; `nil` uses the
    ///     single-Mac key from before per-Mac registration.
    public func run(
        client: any SupermuxPhonePushRegistering,
        capabilities: SupermuxMobileCapabilities,
        pairingID: String? = nil
    ) async {
        guard capabilities.supportsPhonePush,
              currentBundleID == Self.bundleID else { return }

        let registeredKey = Self.registeredKey(pairingID: pairingID)
        let changes = notificationCenter
            .notifications(named: UserDefaults.didChangeNotification)
            .makeAsyncIterator()
        var lastSent: Snapshot?
        await synchronizeUntilCurrent(client: client, registeredKey: registeredKey, lastSent: &lastSent)
        while !Task.isCancelled, await changes.next() != nil {
            await synchronizeUntilCurrent(client: client, registeredKey: registeredKey, lastSent: &lastSent)
        }
    }

    /// Where one Mac's last reported token lives. A Mac first registered
    /// before per-Mac keys inherits the single-Mac value until its first
    /// successful registration writes its own key.
    private static func registeredKey(pairingID: String?) -> String {
        guard let pairingID, !pairingID.isEmpty else { return registeredDeviceTokenKey }
        return "\(registeredDeviceTokenKey).\(pairingID)"
    }

    private func synchronizeUntilCurrent(
        client: any SupermuxPhonePushRegistering,
        registeredKey: String,
        lastSent: inout Snapshot?
    ) async {
        while !Task.isCancelled,
              let snapshot = snapshot(registeredKey: registeredKey),
              snapshot != lastSent {
            do {
                _ = try await client.registerPhonePush(snapshot.request)
                // Record the token this Mac was told about even when push is
                // off: the Mac already dropped every record for this device,
                // and a missing key would fall back to the single-Mac key and
                // report its stale token as "previous" on every pass.
                defaults.set(snapshot.token, forKey: registeredKey)
                lastSent = Snapshot(
                    deviceID: snapshot.deviceID,
                    token: snapshot.token,
                    previousToken: nil,
                    enabled: snapshot.enabled
                )
            } catch {
                // Keep the snapshot unsent so a later defaults change or reconnect retries.
                return
            }
        }
    }

    private func snapshot(registeredKey: String) -> Snapshot? {
        guard let token = defaults.string(forKey: Self.deviceTokenKey),
              Self.isValidToken(token) else { return nil }
        let enabled = defaults.object(forKey: Self.pushEnabledKey) as? Bool ?? true
        let registeredToken = defaults.string(forKey: registeredKey)
            ?? defaults.string(forKey: Self.registeredDeviceTokenKey)
        return Snapshot(
            deviceID: deviceID(),
            token: token.lowercased(),
            previousToken: registeredToken.flatMap { previous in
                let normalized = previous.lowercased()
                return normalized == token.lowercased() ? nil : normalized
            },
            enabled: enabled
        )
    }

    private func deviceID() -> String {
        if let stored = defaults.string(forKey: Self.deviceIDKey),
           UUID(uuidString: stored) != nil {
            return stored.lowercased()
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: Self.deviceIDKey)
        return generated
    }

    private static func isValidToken(_ token: String) -> Bool {
        (64 ... 200).contains(token.count)
            && token.allSatisfy { $0.isHexDigit }
    }

    private struct Snapshot: Equatable {
        let deviceID: String
        let token: String
        let previousToken: String?
        let enabled: Bool

        var request: SupermuxPhonePushRegistrationRequest {
            // The fixed-identity install is Ad Hoc distribution-signed with
            // aps-environment=production; sandbox delivery proved best-effort
            // (silently dropped pushes to the backgrounded app).
            SupermuxPhonePushRegistrationRequest(
                deviceID: deviceID,
                deviceToken: token,
                previousDeviceToken: previousToken,
                bundleID: SupermuxMobilePushRegistrationStore.bundleID,
                environment: .production,
                enabled: enabled
            )
        }
    }
}

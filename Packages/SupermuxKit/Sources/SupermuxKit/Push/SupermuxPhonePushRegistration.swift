public import Foundation

/// One iPhone's APNs registration as a Mac stores it and as Macs share it.
///
/// The on-disk (`supermux-apns-devices.json`) and wire shape are the same
/// snake_case object, so a registration shared by another Mac lands in the
/// file exactly as a direct `phone_push.register` would have written it.
public struct SupermuxPhonePushRegistration: Codable, Sendable, Equatable {
    /// Stable identity of the phone installation (lowercase UUID), when known.
    public var deviceID: String?
    /// Lowercase hexadecimal APNs device token.
    public var deviceToken: String
    /// Signed application bundle identifier (the APNs topic).
    public var bundleID: String
    /// APNs host that issued the token.
    public var environment: SupermuxPhonePushService.Environment

    /// Creates a registration.
    public init(
        deviceID: String?,
        deviceToken: String,
        bundleID: String,
        environment: SupermuxPhonePushService.Environment
    ) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.bundleID = bundleID
        self.environment = environment
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceToken = "device_token"
        case bundleID = "bundle_id"
        case environment
    }

    /// The registration with trimmed, lowercased identifiers, or `nil` when it
    /// could never be delivered by this provider: another bundle topic, a
    /// malformed token, or a device id that is not a UUID.
    public func normalized() -> SupermuxPhonePushRegistration? {
        let token = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let device = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard bundleID == SupermuxPhonePushService.supportedBundleID,
              Self.isValidDeviceToken(token),
              device.map({ UUID(uuidString: $0) != nil }) != false else { return nil }
        return SupermuxPhonePushRegistration(
            deviceID: device,
            deviceToken: token,
            bundleID: bundleID,
            environment: environment
        )
    }

    /// Whether `value` has the shape of an APNs device token (64–200 hex digits).
    public static func isValidDeviceToken(_ value: String) -> Bool {
        (64 ... 200).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}

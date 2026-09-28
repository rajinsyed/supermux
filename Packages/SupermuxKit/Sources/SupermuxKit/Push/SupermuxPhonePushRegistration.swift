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
    /// When the phone registered this token with a Mac (seconds since 1970),
    /// so a Mac that learns a phone's rotated token from another Mac can tell
    /// the newer token from its own. `nil` for entries written before this field.
    public var registeredAt: Double?

    /// Creates a registration.
    public init(
        deviceID: String?,
        deviceToken: String,
        bundleID: String,
        environment: SupermuxPhonePushService.Environment,
        registeredAt: Double? = nil
    ) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.bundleID = bundleID
        self.environment = environment
        self.registeredAt = registeredAt
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceToken = "device_token"
        case bundleID = "bundle_id"
        case environment
        case registeredAt = "registered_at"
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
            environment: environment,
            registeredAt: registeredAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        )
    }

    /// Whether `value` has the shape of an APNs device token (64–200 hex digits).
    public static func isValidDeviceToken(_ value: String) -> Bool {
        (64 ... 200).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}

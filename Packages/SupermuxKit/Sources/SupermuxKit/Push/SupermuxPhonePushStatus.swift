import Foundation

/// What a Mac's direct-APNs lane holds, as `mobile.supermux.phone_push.status`
/// reports it to another Mac. Never carries the private key or phone tokens.
public struct SupermuxPhonePushStatus: Codable, Sendable, Equatable {
    /// Whether a valid configuration and private key are installed.
    public var hasCredentials: Bool
    /// Installed team identifier, when configured.
    public var teamID: String?
    /// Installed key identifier, when configured.
    public var keyID: String?
    /// ``SupermuxPhonePushCredentials/fingerprint`` of the installed key.
    public var keyFingerprint: String?
    /// The only APNs topic this Mac pushes to.
    public var bundleID: String
    /// How many phone registrations this Mac holds.
    public var registrationCount: Int
    /// Whether this Mac shares and accepts credentials (`supermux.devices.sharePush`).
    public var shareEnabled: Bool

    /// Creates a status.
    public init(
        hasCredentials: Bool,
        teamID: String?,
        keyID: String?,
        keyFingerprint: String?,
        bundleID: String,
        registrationCount: Int,
        shareEnabled: Bool
    ) {
        self.hasCredentials = hasCredentials
        self.teamID = teamID
        self.keyID = keyID
        self.keyFingerprint = keyFingerprint
        self.bundleID = bundleID
        self.registrationCount = registrationCount
        self.shareEnabled = shareEnabled
    }

    enum CodingKeys: String, CodingKey {
        case hasCredentials = "has_credentials"
        case teamID = "team_id"
        case keyID = "key_id"
        case keyFingerprint = "key_fingerprint"
        case bundleID = "bundle_id"
        case registrationCount = "registration_count"
        case shareEnabled = "share_enabled"
    }

    /// Whether the installed key is exactly `credentials` (identifiers and bytes).
    public func holdsSameKey(as credentials: SupermuxPhonePushCredentials) -> Bool {
        hasCredentials
            && teamID == credentials.configuration.teamID
            && keyID == credentials.configuration.keyID
            && keyFingerprint == credentials.fingerprint
    }
}

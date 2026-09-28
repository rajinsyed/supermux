public import Foundation

/// The body of `mobile.supermux.phone_push.share`: what one Mac hands another.
///
/// Wire shape (every part optional, but `config` and `p8` travel together):
///
/// ```json
/// {"config": {"team_id": "…", "key_id": "…"}, "p8": "-----BEGIN PRIVATE KEY-----…",
///  "registrations": [{"device_id": "…", "device_token": "…", "bundle_id": "…", "environment": "production"}]}
/// ```
///
/// Also used for "what this Mac could share" (``SupermuxPhonePushService/shareSnapshot()``).
public struct SupermuxPhonePushShareRequest: Sendable, Equatable {
    /// A complete provider identity to install where none exists, or `nil`.
    public var credentials: SupermuxPhonePushCredentials?
    /// Phone registrations to merge.
    public var registrations: [SupermuxPhonePushRegistration]

    /// Creates a request.
    public init(
        credentials: SupermuxPhonePushCredentials? = nil,
        registrations: [SupermuxPhonePushRegistration] = []
    ) {
        self.credentials = credentials
        self.registrations = registrations
    }

    /// A request body that cannot be parsed.
    public enum WireError: Error, Sendable, Equatable {
        /// `config` without `p8` (or the reverse), or a field of the wrong type.
        case malformed(String)
    }

    /// Parses the RPC params. Registrations that fail to decode make the whole
    /// request malformed; registrations that decode but could never be
    /// delivered are left for the merger to drop.
    public init(wireParams params: [String: Any]) throws {
        let config = params["config"]
        let p8 = params["p8"]
        switch (config, p8) {
        case (nil, nil):
            credentials = nil
        case let (config as [String: Any], p8 as String):
            guard let teamID = config["team_id"] as? String,
                  let keyID = config["key_id"] as? String else {
                throw WireError.malformed("config")
            }
            credentials = SupermuxPhonePushCredentials(
                configuration: SupermuxPhonePushConfiguration(teamID: teamID, keyID: keyID),
                privateKeyPEM: p8
            )
        default:
            throw WireError.malformed("config and p8 must be sent together")
        }
        guard let rawRegistrations = params["registrations"] else {
            registrations = []
            return
        }
        guard let list = rawRegistrations as? [Any],
              JSONSerialization.isValidJSONObject(list),
              let data = try? JSONSerialization.data(withJSONObject: list),
              let decoded = try? JSONDecoder().decode([SupermuxPhonePushRegistration].self, from: data) else {
            throw WireError.malformed("registrations")
        }
        registrations = decoded
    }

    /// The RPC params for this request.
    public var wireParams: [String: Any] {
        var params: [String: Any] = [
            "registrations": registrations.map { registration -> [String: Any] in
                var object: [String: Any] = [
                    "device_token": registration.deviceToken,
                    "bundle_id": registration.bundleID,
                    "environment": registration.environment.rawValue,
                ]
                if let deviceID = registration.deviceID { object["device_id"] = deviceID }
                if let registeredAt = registration.registeredAt { object["registered_at"] = registeredAt }
                return object
            },
        ]
        if let credentials {
            params["config"] = [
                "team_id": credentials.configuration.teamID,
                "key_id": credentials.configuration.keyID,
            ]
            params["p8"] = credentials.privateKeyPEM
        }
        return params
    }
}

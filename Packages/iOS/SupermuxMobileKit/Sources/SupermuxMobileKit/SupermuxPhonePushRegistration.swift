import Foundation
import SupermuxMobileCore

/// The APNs environment of a directly installed Supermux iPhone build.
public enum SupermuxPhonePushEnvironment: String, Codable, Sendable, Equatable {
    /// Development provisioning profiles use Apple's sandbox APNs host.
    case sandbox
    /// TestFlight and App Store provisioning profiles use Apple's production APNs host.
    case production
}

/// Registers or removes one iPhone APNs token on the paired Supermux Mac.
public struct SupermuxPhonePushRegistrationRequest: Sendable, Equatable {
    /// Stable identity for this physical iPhone installation.
    public let deviceID: String
    /// The lowercase hexadecimal APNs device token.
    public let deviceToken: String
    /// The token previously acknowledged by the Mac, when APNs rotated it.
    public let previousDeviceToken: String?
    /// The signed iOS application's bundle identifier.
    public let bundleID: String
    /// The APNs host that issued ``deviceToken``.
    public let environment: SupermuxPhonePushEnvironment
    /// Whether this device should remain registered.
    public let enabled: Bool

    /// Creates a phone-push registration request.
    ///
    /// - Parameters:
    ///   - deviceID: Stable identity for this physical iPhone installation.
    ///   - deviceToken: The lowercase hexadecimal APNs device token.
    ///   - previousDeviceToken: The last token the Mac acknowledged, when different.
    ///   - bundleID: The signed iOS application's bundle identifier.
    ///   - environment: The APNs host that issued the token.
    ///   - enabled: Whether the Mac should retain this device.
    public init(
        deviceID: String,
        deviceToken: String,
        previousDeviceToken: String? = nil,
        bundleID: String,
        environment: SupermuxPhonePushEnvironment,
        enabled: Bool
    ) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.previousDeviceToken = previousDeviceToken
        self.bundleID = bundleID
        self.environment = environment
        self.enabled = enabled
    }

    /// The exact JSON-RPC method string.
    public var wireMethod: String { SupermuxMobileMethod.phonePushRegister.rawValue }

    /// The snake-case JSON-RPC parameters.
    public var wireParams: [String: Any] {
        var params: [String: Any] = [
            "device_id": deviceID,
            "device_token": deviceToken,
            "bundle_id": bundleID,
            "environment": environment.rawValue,
            "enabled": enabled,
        ]
        if let previousDeviceToken {
            params["previous_device_token"] = previousDeviceToken
        }
        return params
    }
}

/// The Mac's acknowledgement of one phone-push registration mutation.
public struct SupermuxPhonePushRegistrationResponse: Codable, Sendable, Equatable {
    /// Whether the device token remains registered after this mutation.
    public let registered: Bool

    /// Creates a registration response.
    /// - Parameter registered: Whether the token remains registered.
    public init(registered: Bool) {
        self.registered = registered
    }
}

/// The narrow Mac client seam used by phone-push registration.
public protocol SupermuxPhonePushRegistering: Sendable {
    /// Registers or removes one phone token on the paired Mac.
    /// - Parameter request: The registration mutation.
    /// - Returns: The Mac's authoritative post-mutation state.
    func registerPhonePush(
        _ request: SupermuxPhonePushRegistrationRequest
    ) async throws -> SupermuxPhonePushRegistrationResponse
}

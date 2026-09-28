import CryptoKit
public import Foundation

/// The APNs team and key identifiers (`supermux-apns.json`). Not secret.
public struct SupermuxPhonePushConfiguration: Codable, Sendable, Equatable {
    /// Apple Developer team identifier.
    public var teamID: String
    /// APNs authentication key identifier.
    public var keyID: String

    /// Creates a configuration.
    public init(teamID: String, keyID: String) {
        self.teamID = teamID
        self.keyID = keyID
    }

    enum CodingKeys: String, CodingKey {
        case teamID = "team_id"
        case keyID = "key_id"
    }

    /// Whether both identifiers have Apple's shape (6–32 ASCII letters/digits).
    public var isValid: Bool {
        Self.isValidIdentifier(teamID) && Self.isValidIdentifier(keyID)
    }

    /// Whether `value` has the shape of an Apple team or key identifier.
    public static func isValidIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (6 ... 32).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// A complete direct-APNs provider identity: the configuration plus the
/// `.p8` private key it names.
///
/// The key is a secret. It only ever travels to another Mac of the same
/// account over the authenticated device link, never to a phone, and it is
/// never printed: ``description`` redacts it so a stray interpolation in a log
/// line cannot leak it.
public struct SupermuxPhonePushCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Team and key identifiers.
    public var configuration: SupermuxPhonePushConfiguration
    /// The PEM text of the APNs authentication key (`-----BEGIN PRIVATE KEY-----`).
    public var privateKeyPEM: String

    /// Creates credentials.
    public init(configuration: SupermuxPhonePushConfiguration, privateKeyPEM: String) {
        self.configuration = configuration
        self.privateKeyPEM = privateKeyPEM
    }

    /// Whether the identifiers are well formed and the PEM is a P-256 signing key.
    public var isValid: Bool {
        configuration.isValid
            && (try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)) != nil
    }

    /// A short, non-reversible identity of the key bytes (first 16 hex digits
    /// of the SHA-256 of the PEM with surrounding whitespace trimmed). Lets two
    /// Macs tell "same key" from "different key under the same key id"
    /// without exchanging the key.
    public var fingerprint: String {
        let normalized = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `other` is the same provider identity (identifiers and key bytes).
    public func isSameKey(as other: SupermuxPhonePushCredentials) -> Bool {
        configuration == other.configuration && fingerprint == other.fingerprint
    }

    public var description: String {
        "SupermuxPhonePushCredentials(team: \(configuration.teamID), key: \(configuration.keyID), fingerprint: \(fingerprint), privateKey: <redacted>)"
    }

    public var debugDescription: String { description }
}

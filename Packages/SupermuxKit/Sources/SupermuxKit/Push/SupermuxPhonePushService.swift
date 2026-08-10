import CryptoKit
public import Foundation
import OSLog

/// Sends native iOS notifications directly from the paired Mac through APNs.
public actor SupermuxPhonePushService {
    /// The fixed iOS bundle identifier this personal push provider is allowed to target.
    public static let supportedBundleID = "com.supermux.ios"
    /// The JSON file containing the APNs team and key identifiers.
    public static let configurationFileName = "supermux-apns.json"
    /// The locally stored APNs authentication key downloaded from Apple.
    public static let privateKeyFileName = "supermux-apns-auth-key.p8"
    /// The persisted phone registrations learned over the encrypted mobile connection.
    public static let registrationsFileName = "supermux-apns-devices.json"

    /// Apple's APNs environment for one device token.
    public enum Environment: String, Codable, Sendable, Equatable {
        /// Tokens issued to development-provisioned applications.
        case sandbox
        /// Tokens issued to TestFlight or App Store applications.
        case production

        fileprivate var host: String {
            switch self {
            case .sandbox: "api.sandbox.push.apple.com"
            case .production: "api.push.apple.com"
            }
        }
    }

    private struct Configuration: Codable, Sendable, Equatable {
        let teamID: String
        let keyID: String

        enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
            case keyID = "key_id"
        }
    }

    private struct Registration: Codable, Sendable, Equatable {
        let deviceToken: String
        let bundleID: String
        let environment: Environment

        enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case bundleID = "bundle_id"
            case environment
        }
    }

    private struct RegistrationsDocument: Codable, Sendable {
        var devices: [Registration]
    }

    private struct ProviderTokenCache: Sendable {
        let configuration: Configuration
        let privateKeyFingerprint: SHA256Digest
        let issuedAt: Date
        let token: String
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let baseDirectory: URL
    private let transport: Transport
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let logger: Logger
    private var providerTokenCache: ProviderTokenCache?

    /// Creates the direct APNs service.
    ///
    /// - Parameters:
    ///   - baseDirectory: The cmux Application Support directory containing the
    ///     configuration, private key, and device-registration files.
    ///   - session: The HTTP/2-capable URL session used to contact APNs.
    ///   - fileManager: Filesystem access for local credentials and registrations.
    ///   - now: Clock used for provider JWT issuance and APNs expiration.
    public init(
        baseDirectory: URL,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseDirectory = baseDirectory
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse
            }
            return (data, http)
        }
        self.fileManager = fileManager
        self.now = now
        self.logger = Logger(subsystem: "dev.supermux", category: "direct-apns")
    }

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: @escaping Transport
    ) {
        self.baseDirectory = baseDirectory
        self.transport = transport
        self.fileManager = fileManager
        self.now = now
        self.logger = Logger(subsystem: "dev.supermux", category: "direct-apns")
    }

    /// Adds or removes one iPhone APNs token.
    ///
    /// Only the fixed Supermux bundle topic is accepted, so a paired client
    /// cannot use the locally stored provider key to target another application
    /// owned by the same Apple Developer team.
    ///
    /// - Parameters:
    ///   - deviceToken: Lowercase hexadecimal APNs token.
    ///   - bundleID: Signed application bundle identifier.
    ///   - environment: APNs host that issued the token.
    ///   - enabled: Whether the registration should remain active.
    /// - Returns: Whether the token is registered after the mutation.
    public func register(
        deviceToken: String,
        bundleID: String,
        environment: Environment,
        enabled: Bool
    ) throws -> Bool {
        let normalizedToken = deviceToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard bundleID == Self.supportedBundleID,
              (64 ... 200).contains(normalizedToken.count),
              normalizedToken.allSatisfy(\.isHexDigit) else {
            throw RegistrationError.invalidRegistration
        }

        var registrations = loadRegistrations()
        registrations.removeAll { $0.deviceToken == normalizedToken }
        if enabled {
            registrations.append(Registration(
                deviceToken: normalizedToken,
                bundleID: bundleID,
                environment: environment
            ))
        }
        try persist(registrations: registrations)
        return enabled
    }

    /// Sends one notification to every registered Supermux iPhone.
    ///
    /// Missing local credentials or zero registered devices are intentional
    /// no-ops, preserving the upstream cloud-push behavior until the personal
    /// direct provider has been configured.
    ///
    /// - Parameter message: The notification or dismiss operation to deliver.
    public func forward(_ message: SupermuxPhonePushMessage) async {
        guard let configuration = loadConfiguration(),
              let privateKeyData = try? Data(contentsOf: privateKeyURL),
              !privateKeyData.isEmpty else { return }
        var registrations = loadRegistrations()
        guard !registrations.isEmpty else { return }

        let providerToken: String
        do {
            providerToken = try makeProviderToken(
                configuration: configuration,
                privateKeyData: privateKeyData
            )
        } catch {
            logger.error("Failed to create APNs provider token")
            return
        }

        var invalidTokens = Set<String>()
        for registration in registrations {
            do {
                let result = try await send(
                    message,
                    registration: registration,
                    providerToken: providerToken
                )
                if result.shouldPrune {
                    invalidTokens.insert(registration.deviceToken)
                }
            } catch {
                logger.error("Direct APNs request failed for bundle \(registration.bundleID, privacy: .public)")
            }
        }
        guard !invalidTokens.isEmpty else { return }
        registrations.removeAll { invalidTokens.contains($0.deviceToken) }
        try? persist(registrations: registrations)
    }

    /// Whether the local team/key configuration and private key are present.
    public func isConfigured() -> Bool {
        loadConfiguration() != nil && fileManager.fileExists(atPath: privateKeyURL.path)
    }

    private var configurationURL: URL {
        baseDirectory.appendingPathComponent(Self.configurationFileName, isDirectory: false)
    }

    private var privateKeyURL: URL {
        baseDirectory.appendingPathComponent(Self.privateKeyFileName, isDirectory: false)
    }

    private var registrationsURL: URL {
        baseDirectory.appendingPathComponent(Self.registrationsFileName, isDirectory: false)
    }

    private func loadConfiguration() -> Configuration? {
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
              Self.isValidIdentifier(configuration.teamID),
              Self.isValidIdentifier(configuration.keyID) else { return nil }
        return configuration
    }

    private func loadRegistrations() -> [Registration] {
        guard let data = try? Data(contentsOf: registrationsURL),
              let document = try? JSONDecoder().decode(RegistrationsDocument.self, from: data) else {
            return []
        }
        return document.devices.filter {
            $0.bundleID == Self.supportedBundleID
                && (64 ... 200).contains($0.deviceToken.count)
                && $0.deviceToken.allSatisfy(\.isHexDigit)
        }
    }

    private func persist(registrations: [Registration]) throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let document = RegistrationsDocument(devices: registrations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: registrationsURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: registrationsURL.path
        )
    }

    private func makeProviderToken(
        configuration: Configuration,
        privateKeyData: Data
    ) throws -> String {
        let current = now()
        let fingerprint = SHA256.hash(data: privateKeyData)
        if let cached = providerTokenCache,
           cached.configuration == configuration,
           cached.privateKeyFingerprint == fingerprint,
           current.timeIntervalSince(cached.issuedAt) < 50 * 60 {
            return cached.token
        }
        guard let pem = String(data: privateKeyData, encoding: .utf8) else {
            throw ProviderError.invalidPrivateKey
        }
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let header = try Self.encodedJSON([
            "alg": "ES256",
            "kid": configuration.keyID,
        ])
        let claims = try Self.encodedJSON([
            "iss": configuration.teamID,
            "iat": Int(current.timeIntervalSince1970),
        ])
        let signingInput = "\(header).\(claims)"
        guard let signingData = signingInput.data(using: .utf8) else {
            throw ProviderError.invalidSigningInput
        }
        let signature = try key.signature(for: signingData)
        let token = "\(signingInput).\(Self.base64URL(signature.rawRepresentation))"
        providerTokenCache = ProviderTokenCache(
            configuration: configuration,
            privateKeyFingerprint: fingerprint,
            issuedAt: current,
            token: token
        )
        return token
    }

    private func send(
        _ message: SupermuxPhonePushMessage,
        registration: Registration,
        providerToken: String
    ) async throws -> DeliveryResult {
        guard let url = URL(string: "https://\(registration.environment.host)/3/device/\(registration.deviceToken)") else {
            throw ProviderError.invalidRequestURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(for: message))
        request.timeoutInterval = 10
        request.setValue("bearer \(providerToken)", forHTTPHeaderField: "authorization")
        request.setValue(registration.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(message.kind == .dismiss ? "5" : "10", forHTTPHeaderField: "apns-priority")
        request.setValue(String(Int(now().addingTimeInterval(120).timeIntervalSince1970)), forHTTPHeaderField: "apns-expiration")
        if message.kind == .notify, let notificationID = message.notificationID,
           notificationID.utf8.count <= 64 {
            request.setValue(notificationID, forHTTPHeaderField: "apns-collapse-id")
        }

        let (data, http) = try await transport(request)
        if http.statusCode == 200 {
            return DeliveryResult(status: http.statusCode, reason: nil)
        }
        let reason = (try? JSONDecoder().decode(APNsErrorBody.self, from: data))?.reason
        logger.error(
            "APNs rejected direct push status=\(http.statusCode) reason=\(reason ?? "unknown", privacy: .public)"
        )
        return DeliveryResult(status: http.statusCode, reason: reason)
    }

    private func payload(for message: SupermuxPhonePushMessage) -> [String: Any] {
        if message.kind == .dismiss {
            return [
                "aps": [
                    "content-available": 1,
                    "badge": max(0, message.badgeCount),
                ],
                "cmux": ["dismissedIds": message.dismissedIDs],
            ]
        }

        let alert: [String: String]
        if message.hideContent {
            alert = [
                "title-loc-key": "push.generic.title",
                "loc-key": "push.generic.body",
            ]
        } else {
            var visible = ["title": message.title.trimmingCharacters(in: .whitespacesAndNewlines)]
            if visible["title"]?.isEmpty != false {
                visible["title"] = "Supermux"
            }
            if !message.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                visible["subtitle"] = message.subtitle
            }
            if !message.body.isEmpty {
                visible["body"] = message.body
            }
            alert = visible
        }
        var aps: [String: Any] = [
            "alert": alert,
            "sound": "default",
            "badge": max(0, message.badgeCount),
            "category": message.acceptsTextReply ? "cmux.terminal.reply" : "cmux.terminal",
        ]
        aps.removeValue(forKey: "interruption-level")

        var cmux: [String: Any] = [
            "retargetsToLiveSurfaceOwner": message.retargetsToLiveSurfaceOwner,
        ]
        if let workspaceID = message.workspaceID { cmux["workspaceId"] = workspaceID }
        if let surfaceID = message.surfaceID { cmux["surfaceId"] = surfaceID }
        if let macDeviceID = message.macDeviceID { cmux["macDeviceId"] = macDeviceID }
        if let notificationID = message.notificationID { cmux["notificationId"] = notificationID }
        return ["aps": aps, "cmux": cmux]
    }

    private static func encodedJSON(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (6 ... 32).contains(trimmed.count)
            && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// A malformed or unauthorized phone registration.
    public enum RegistrationError: Error, Sendable, Equatable {
        /// The token, bundle identifier, or APNs environment was invalid.
        case invalidRegistration
    }

    private enum ProviderError: Error {
        case invalidPrivateKey
        case invalidSigningInput
        case invalidRequestURL
        case invalidResponse
    }

    private struct APNsErrorBody: Decodable {
        let reason: String?
    }

    private struct DeliveryResult {
        let status: Int
        let reason: String?

        var shouldPrune: Bool {
            status == 410
                || reason == "Unregistered"
                || (status == 400 && (reason == "BadDeviceToken" || reason == "DeviceTokenNotForTopic"))
        }
    }
}

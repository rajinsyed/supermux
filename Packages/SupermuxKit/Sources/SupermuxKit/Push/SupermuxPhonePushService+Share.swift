public import Foundation

/// The outcome of one accepted `phone_push.share`, as reported back to the sender.
public struct SupermuxPhonePushShareResult: Sendable, Equatable {
    /// What happened to the incoming provider identity.
    public var credentials: SupermuxPhonePushShareMerger.CredentialOutcome
    /// How many new phone registrations were stored.
    public var registrationsAdded: Int
    /// Registrations held after the merge.
    public var registrationCount: Int

    /// The RPC result object (no secrets).
    public var wireResult: [String: Any] {
        [
            "credentials": credentials.rawValue,
            "registrations_added": registrationsAdded,
            "registration_count": registrationCount,
        ]
    }
}

/// Mac-to-Mac sharing of the direct-APNs provider identity and the phone
/// registrations, so a Mac the phone never focused (an unattended MacBook
/// running agents) can still push.
///
/// Files keep exactly the shape and protection the direct lane expects:
/// `supermux-apns.json`, `supermux-apns-auth-key.p8` and
/// `supermux-apns-devices.json`, each `0600`, in a `0700` directory. The
/// private key is never logged or returned by ``status(shareEnabled:)``.
extension SupermuxPhonePushService {
    /// DEBUG-only environment variable that points the direct lane at a scratch
    /// directory, so end-to-end runs of tagged builds never read or write the
    /// real credentials every build on this Mac shares.
    public static let stateDirectoryOverrideKey = "SUPERMUX_PHONE_PUSH_STATE_DIR"

    /// The directory the direct lane uses: `defaultDirectory` (the cmux state
    /// directory), or in DEBUG builds the ``stateDirectoryOverrideKey`` path.
    public static func resolvedBaseDirectory(
        default defaultDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if DEBUG
        if let override = environment[stateDirectoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return defaultDirectory
    }

    /// What this Mac holds, for `mobile.supermux.phone_push.status`.
    public func status(shareEnabled: Bool) -> SupermuxPhonePushStatus {
        let credentials = installedCredentials()
        return SupermuxPhonePushStatus(
            hasCredentials: credentials != nil,
            teamID: credentials?.configuration.teamID,
            keyID: credentials?.configuration.keyID,
            keyFingerprint: credentials?.fingerprint,
            bundleID: Self.supportedBundleID,
            registrationCount: loadRegistrations().count,
            shareEnabled: shareEnabled
        )
    }

    /// What this Mac could share with a peer: its complete provider identity
    /// (when valid) and its phone registrations.
    public func shareSnapshot() -> SupermuxPhonePushShareRequest {
        SupermuxPhonePushShareRequest(
            credentials: installedCredentials(),
            registrations: loadRegistrations()
        )
    }

    /// Applies a share from another Mac: installs the provider identity only
    /// where none (not even a partial one) exists, and adds registrations for
    /// phones this Mac does not know yet.
    public func acceptShare(_ request: SupermuxPhonePushShareRequest) throws -> SupermuxPhonePushShareResult {
        let outcome = hasPartialCredentials()
            ? (request.credentials == nil ? .absent : .conflict)
            : SupermuxPhonePushShareMerger.credentialOutcome(
                existing: installedCredentials(),
                incoming: request.credentials
            )
        let existing = loadRegistrations()
        let merge = SupermuxPhonePushShareMerger.mergeRegistrations(
            existing: existing,
            incoming: request.registrations
        )
        if outcome == .install || merge.added > 0 {
            try ensurePrivateDirectory()
        }
        if outcome == .install, let credentials = request.credentials {
            try install(credentials)
        }
        if merge.added > 0 {
            try persist(registrations: merge.merged)
        }
        return SupermuxPhonePushShareResult(
            credentials: outcome,
            registrationsAdded: merge.added,
            registrationCount: merge.merged.count
        )
    }

    // MARK: - Files

    /// The fully installed, valid provider identity, or `nil`.
    private func installedCredentials() -> SupermuxPhonePushCredentials? {
        guard let configuration = loadConfiguration(),
              let data = try? Data(contentsOf: privateKeyURL),
              let pem = String(data: data, encoding: .utf8) else { return nil }
        let credentials = SupermuxPhonePushCredentials(configuration: configuration, privateKeyPEM: pem)
        return credentials.isValid ? credentials : nil
    }

    /// A config or key file exists but they do not form a valid identity: a
    /// hand-placed key waiting for its config, or the reverse. Never touched.
    private func hasPartialCredentials() -> Bool {
        guard installedCredentials() == nil else { return false }
        return fileManager.fileExists(atPath: configurationURL.path)
            || fileManager.fileExists(atPath: privateKeyURL.path)
    }

    /// Creates the directory `0700`, or tightens an existing looser one.
    private func ensurePrivateDirectory() throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
    }

    /// Writes the key before its config, so a crash in between leaves a
    /// partial identity that later shares refuse to overwrite rather than a
    /// config naming a key that is not there.
    private func install(_ credentials: SupermuxPhonePushCredentials) throws {
        try writePrivate(Data(credentials.privateKeyPEM.utf8), to: privateKeyURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(credentials.configuration), to: configurationURL)
    }

    /// Atomic write, then `0600`. The directory is already `0700`, so the
    /// temporary file is never reachable by another user.
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

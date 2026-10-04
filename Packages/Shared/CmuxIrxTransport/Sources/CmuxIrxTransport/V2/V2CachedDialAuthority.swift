// SUPERMUX:begin mobile-irx-cached-dial-authority (a launch dial does not wait for sign-in's network round trips — see SUPERMUX-TOUCHPOINTS.md)
public import Foundation

/// A signed-in account and team.
public struct V2AccountTeam: Equatable, Sendable {
    public let accountID: String
    public let teamID: String

    public init(accountID: String, teamID: String) {
        self.accountID = accountID
        self.teamID = teamID
    }
}

/// Lets the phone dial its Macs at launch with the account and team its v2
/// runtime warmed from cache, while sign-in is still restoring the session.
///
/// A dial is not a server request: the Mac admits the phone against its own
/// server-issued directory. This only lets the launch dial start before
/// sign-in finishes its network round trips (about 1 s on the iPhone).
public struct V2CachedDialAuthority: Equatable, Sendable {
    /// The warmed identity the dial runs for.
    public let tuple: V2Identity

    /// Present only when the runtime warmed for exactly the signed-in
    /// account and team, its directory is not revoked, and it holds a usable
    /// relay credential.
    public init?(
        prepared: V2Identity?,
        signedIn: V2AccountTeam?,
        cache: V2CachedState?,
        now: Date
    ) {
        guard let prepared, let signedIn, let cache,
              signedIn == V2AccountTeam(accountID: prepared.userID, teamID: prepared.teamID),
              cache.identity == prepared, !cache.authorityRevoked,
              cache.relayCredentials.contains(where: { credential in
                  IrxRelayCredential(
                      relayURL: credential.relayURL, token: credential.token,
                      expiresAt: Date(timeIntervalSince1970: Double(credential.expiresAt)),
                      refreshAfter: Date(timeIntervalSince1970: Double(credential.refreshAfter))
                  ).isUsable(at: now)
              }) else { return nil }
        tuple = prepared
    }

    /// Whether a dial started under this authority may continue.
    /// - Parameters:
    ///   - liveScope: The live signed-in account and team, once sign-in finished.
    ///   - liveScopeIsCurrent: Whether that live scope is still current.
    ///   - prepared: The warmed identity, while sign-in has not finished.
    ///   - signedIn: The locally persisted account and team.
    public func isCurrent(
        liveScope: V2AccountTeam?,
        liveScopeIsCurrent: Bool,
        prepared: V2Identity?,
        signedIn: V2AccountTeam?
    ) -> Bool {
        let account = V2AccountTeam(accountID: tuple.userID, teamID: tuple.teamID)
        if let liveScope {
            return liveScopeIsCurrent && liveScope == account
        }
        return prepared == tuple && signedIn == account
    }
}
// SUPERMUX:end mobile-irx-cached-dial-authority

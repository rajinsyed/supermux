// SUPERMUX:begin mobile-irx-cached-dial-authority (regression coverage — see SUPERMUX-TOUCHPOINTS.md)
import Foundation
import Testing
@testable import CmuxIrxTransport

/// Field log (2026-10-04): the iPhone's launch dial waited about 1.1 s for
/// sign-in to finish `/users/me` and the team list, although the v2 runtime
/// had warmed from the cached account and team 30 ms after launch and the Mac
/// authorizes the phone itself.
struct V2CachedDialAuthorityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the warmed account and team may dial before sign-in finishes")
    func warmedRuntimeMayDialBeforeSignIn() {
        let authority = V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(), cache: cache(), now: now)
        #expect(authority?.tuple == tuple())
    }

    @Test("no cached dial once signed out, for another account or team, without a warm runtime, or with a revoked directory")
    func cachedDialNeedsTheSameSignedInIdentity() {
        #expect(V2CachedDialAuthority(prepared: tuple(), signedIn: nil, cache: cache(), now: now) == nil)
        #expect(V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(team: "other-team"), cache: cache(), now: now) == nil)
        #expect(V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(user: "other-user"), cache: cache(), now: now) == nil)
        #expect(V2CachedDialAuthority(prepared: nil, signedIn: account(), cache: cache(), now: now) == nil)
        #expect(V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(), cache: cache(revoked: true), now: now) == nil)
    }

    @Test("a cached dial waits for sign-in when every relay credential has expired")
    func cachedDialNeedsAUsableRelayCredential() {
        #expect(V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(), cache: cache(credentialExpiresIn: -60), now: now) == nil)
    }

    @Test("a cached dial continues when sign-in finishes for the same account and team, and stops otherwise")
    func cachedDialSurvivesOnlyTheSameSignIn() throws {
        let authority = try #require(V2CachedDialAuthority(
            prepared: tuple(), signedIn: account(), cache: cache(), now: now))
        // Still restoring.
        #expect(authority.isCurrent(
            liveScope: nil, liveScopeIsCurrent: false, prepared: tuple(), signedIn: account()))
        // Sign-in finished for the same account and team.
        #expect(authority.isCurrent(
            liveScope: account(), liveScopeIsCurrent: true, prepared: nil, signedIn: account()))
        // Sign-in finished for another team.
        #expect(!authority.isCurrent(
            liveScope: account(team: "other-team"), liveScopeIsCurrent: true,
            prepared: nil, signedIn: account(team: "other-team")))
        // The live scope was replaced meanwhile.
        #expect(!authority.isCurrent(
            liveScope: account(), liveScopeIsCurrent: false, prepared: nil, signedIn: account()))
        // Signed out before sign-in finished.
        #expect(!authority.isCurrent(
            liveScope: nil, liveScopeIsCurrent: false, prepared: tuple(), signedIn: nil))
        // Sign-in failed: the warm runtime was cleared.
        #expect(!authority.isCurrent(
            liveScope: nil, liveScopeIsCurrent: false, prepared: nil, signedIn: account()))
    }

    private func tuple() -> V2Identity {
        V2Identity(appNamespace: "dev.cmux.tests", buildTag: "test", deviceID: "device",
            environment: "test", projectID: "project", teamID: "team", userID: "user")
    }

    private func account(user: String = "user", team: String = "team") -> V2AccountTeam {
        V2AccountTeam(accountID: user, teamID: team)
    }

    private func cache(revoked: Bool = false, credentialExpiresIn: TimeInterval = 1_800) -> V2CachedState {
        var state = V2CachedState(identity: tuple())
        state.authorityRevoked = revoked
        let expiresAt = Int(now.timeIntervalSince1970 + credentialExpiresIn)
        state.relayCredentials = [V2RelayCredential(
            expiresAt: expiresAt, refreshAfter: expiresAt - 300,
            relayURL: "https://apne1.relay.cmux.dev/", token: "token")]
        return state
    }
}
// SUPERMUX:end mobile-irx-cached-dial-authority

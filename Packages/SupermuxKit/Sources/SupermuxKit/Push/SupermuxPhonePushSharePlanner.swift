public import Foundation

/// What one Mac sends another when their device link connects.
public struct SupermuxPhonePushSharePlan: Sendable, Equatable {
    /// The provider identity to send, only when the peer has none.
    public var credentials: SupermuxPhonePushCredentials?
    /// This Mac's deliverable phone registrations.
    public var registrations: [SupermuxPhonePushRegistration]

    /// Creates a plan.
    public init(credentials: SupermuxPhonePushCredentials?, registrations: [SupermuxPhonePushRegistration]) {
        self.credentials = credentials
        self.registrations = registrations
    }

    /// The `mobile.supermux.phone_push.share` params.
    public var wireParams: [String: Any] {
        SupermuxPhonePushShareRequest(credentials: credentials, registrations: registrations).wireParams
    }
}

/// Decides what this Mac shares with a peer Mac, from the peer's
/// `phone_push.status`. Pure: no I/O, no secrets logged.
///
/// Rules: nothing moves unless both Macs allow sharing and the peer pushes to
/// the same bundle topic; the key goes only to a peer that has none (a peer
/// with any key, same or different, never receives ours); registrations
/// always go, because the receiver merges them without overwriting its own.
public enum SupermuxPhonePushSharePlanner {
    /// The plan, or `nil` when nothing should be sent.
    public static func plan(
        local: SupermuxPhonePushCredentials?,
        localRegistrations: [SupermuxPhonePushRegistration],
        peer: SupermuxPhonePushStatus,
        shareEnabled: Bool
    ) -> SupermuxPhonePushSharePlan? {
        guard shareEnabled,
              peer.shareEnabled,
              peer.bundleID == SupermuxPhonePushService.supportedBundleID else { return nil }
        let credentials = local.flatMap { $0.isValid && !peer.hasCredentials ? $0 : nil }
        var seenTokens = Set<String>()
        let registrations = localRegistrations
            .compactMap { $0.normalized() }
            .filter { seenTokens.insert($0.deviceToken).inserted }
        guard credentials != nil || !registrations.isEmpty else { return nil }
        return SupermuxPhonePushSharePlan(credentials: credentials, registrations: registrations)
    }
}

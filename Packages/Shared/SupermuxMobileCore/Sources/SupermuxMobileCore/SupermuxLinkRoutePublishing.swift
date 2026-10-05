import Foundation

/// When a freshly sampled route replaces the published one.
///
/// A link is sampled every couple of seconds, and QUIC's RTT moves a little on
/// every sample; republishing each would redraw every view that shows it. A
/// change of kind (relay to direct, LAN to Tailscale, one relay to another)
/// and a first RTT are published at once; an RTT that moved by at least
/// ``minimumRTTChange`` ms and ``relativeRTTChange`` of the published one, at
/// most every ``rttInterval``. An RTT-only update keeps the kind's `since`.
public enum SupermuxLinkRoutePublishing {
    /// The least time between two RTT-only updates.
    public static let rttInterval: TimeInterval = 5
    /// The smallest RTT move worth publishing, in milliseconds.
    public static let minimumRTTChange = 3
    /// The smallest RTT move worth publishing, relative to the published RTT.
    public static let relativeRTTChange = 0.15

    /// The route to publish, or nil to keep the published one.
    /// - Parameters:
    ///   - published: The route published now, if any.
    ///   - publishedAt: When it was published.
    ///   - sample: The route just sampled.
    ///   - now: The current time.
    /// - Returns: The route to publish (with the published `since` when only
    ///   the RTT changed), or nil.
    public static func next(
        published: SupermuxLinkRoute?, publishedAt: Date?, sample: SupermuxLinkRoute, now: Date
    ) -> SupermuxLinkRoute? {
        guard let published, published.kind == sample.kind else { return sample }
        var update = sample
        update.since = published.since
        guard let newRTT = sample.rttMs else { return nil }
        guard let oldRTT = published.rttMs else { return update }
        let threshold = max(Double(minimumRTTChange), Double(oldRTT) * relativeRTTChange)
        guard Double(abs(newRTT - oldRTT)) >= threshold else { return nil }
        let waited = publishedAt.map { now.timeIntervalSince($0) } ?? .infinity
        return waited >= rttInterval ? update : nil
    }
}

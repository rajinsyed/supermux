import Foundation

/// Stub until the classifier lands.
public enum SupermuxLinkRouteClassifier {
    public static func classify(isRelay: Bool, remoteAddress: String, rttMs: UInt64?, now: Date) -> SupermuxLinkRoute {
        SupermuxLinkRoute(kind: isRelay ? .relay(id: nil) : .direct(.internet), rttMs: nil, since: now)
    }

    public static func relayID(fromURL url: String) -> String? { nil }
}

import CoreGraphics
import Foundation
import SupermuxKit

/// Host evidence for ``SupermuxMacAwayPolicy``: local input recency and the
/// login session's lock state.
///
/// `shouldSuppressExternalDelivery` assumes a frontmost cmux means a watching
/// user. A phone remote-controlling this Mac violates that: selection sync
/// keeps the app frontmost and focused on the phone's workspace while nobody
/// is at the keyboard, so agent pushes for exactly the session the user cares
/// about were suppressed. This reads the real signals — screen lock and
/// seconds since the last physical keyboard/mouse event — and asks the pure
/// policy in SupermuxKit for the verdict.
enum SupermuxMacAwayState {
    private static let policy = SupermuxMacAwayPolicy()

    /// Whether the user should be treated as away from this Mac right now.
    static func userIsAway() -> Bool {
        policy.isAway(
            screenLocked: screenIsLocked(),
            secondsSinceLastInput: secondsSinceLastLocalInput()
        )
    }

    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool)
            ?? ((session["CGSSessionScreenIsLocked"] as? Int) == 1)
    }

    /// Seconds since the last physical input event, or `nil` when Quartz can't
    /// say (the policy then fails closed to upstream suppression). The minimum
    /// across event classes is the recency of ANY input.
    private static func secondsSinceLastLocalInput() -> TimeInterval? {
        let eventTypes: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .scrollWheel,
            .leftMouseDragged, .rightMouseDragged,
        ]
        let seconds = eventTypes.map {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: $0
            )
        }.min()
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

public import Foundation

/// Chooses the notification row that should own keyboard focus.
public struct SupermuxNotificationFocusPolicy: Sendable {
    /// Creates a notification focus policy.
    public init() {}

    /// Preserves visible focus, otherwise selects the newest visible row.
    ///
    /// - Parameters:
    ///   - visibleIDs: Notification identifiers in display order.
    ///   - current: The currently focused notification, if any.
    /// - Returns: The identifier that should own focus, or `nil` when no row is visible.
    public func focusedID(visibleIDs: [UUID], current: UUID?) -> UUID? {
        if let current, visibleIDs.contains(current) {
            return current
        }
        return visibleIDs.first
    }
}

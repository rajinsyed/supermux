import AppKit

/// Tells this Mac's user's own input apart from input delivered to a terminal
/// for someone else: a phone, another Mac, a socket client (`cmux send`) or an
/// agent's automation.
///
/// Every terminal input path runs the terminal's one explicit-input hook, so
/// the hook cannot tell who typed. What can be told is whether the code
/// running now handles an input event the app took from its own event queue:
/// a key, mouse or scroll event while `NSApplication.sendEvent` dispatches
/// it, or the action of a menu item the user chose (a menu bar click is
/// tracked outside `sendEvent`). The app's `sendEvent` and `sendAction` hooks
/// mark that dispatch (SUPERMUX-TOUCHPOINTS.md #920).
///
/// Remote and programmatic input never runs inside such a dispatch: it is
/// delivered from a socket handler, a task, an input lane or a queue's later
/// turn. Two cases come close and are left out:
/// - an event that code synthesizes and hands to `sendEvent` itself (the
///   socket's `simulate_shortcut`): only the event the app dequeued, which is
///   `NSApp.currentEvent`, opens a dispatch;
/// - work that runs in a nested run loop while an event is dispatched (a modal
///   alert, a context menu, a window drag): it runs in another run-loop mode
///   than the one the dispatch started in, so it is not part of it.
@MainActor
enum SupermuxLocalUserInput {
    /// An open dispatch of this Mac's user's input.
    struct Dispatch {
        /// The main run loop's mode when the dispatch started (`nil` when the
        /// run loop was not running, as for the app's top-level event loop).
        fileprivate let mode: RunLoop.Mode?
    }

    private static var current: Dispatch?

    /// Whether the code running now handles this Mac's user's own input.
    static var isHandling: Bool {
        guard let current else { return false }
        return current.mode == RunLoop.main.currentMode
    }

    /// Called before `NSApplication.sendEvent` dispatches `event`.
    ///
    /// - Returns: The enclosing dispatch, for ``end(restoring:)``.
    static func beginEvent(_ event: NSEvent, application: NSApplication) -> Dispatch? {
        let enclosing = current
        if isUserInput(event.type), application.currentEvent === event {
            current = Dispatch(mode: RunLoop.main.currentMode)
        }
        return enclosing
    }

    /// Called before `NSApplication.sendAction` sends an action: a menu
    /// item's action is the user's choice.
    ///
    /// - Returns: The enclosing dispatch, for ``end(restoring:)``.
    static func beginAction(from sender: Any?) -> Dispatch? {
        let enclosing = current
        if sender is NSMenuItem {
            current = Dispatch(mode: RunLoop.main.currentMode)
        }
        return enclosing
    }

    /// Called after the dispatch: back to the enclosing one, if any.
    static func end(restoring enclosing: Dispatch?) {
        current = enclosing
    }

    private static func isUserInput(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .scrollWheel:
            return true
        default:
            return false
        }
    }
}

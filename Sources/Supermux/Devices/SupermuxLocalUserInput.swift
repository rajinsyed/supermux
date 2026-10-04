import AppKit

/// Tells this Mac's user's own input apart from input delivered to a terminal
/// for someone else: a phone, another Mac, a socket client (`cmux send`) or an
/// agent's automation.
///
/// Every terminal input path runs the terminal's one explicit-input hook, so
/// the hook cannot tell who typed. What can be told is whether the code
/// running now handles an input event the app took from its own event queue:
/// a key, mouse or scroll event while `NSApplication.sendEvent` dispatches
/// it, the action of a menu item the user chose (a menu bar click is tracked
/// outside `sendEvent`), or a drop on a terminal (a drag from another app is
/// delivered outside `sendEvent` too). The app's `sendEvent` and `sendAction`
/// hooks and the terminal's drop handler mark that dispatch
/// (SUPERMUX-TOUCHPOINTS.md #920, #923).
///
/// Remote and programmatic input never runs inside such a dispatch: it is
/// delivered from a socket handler, a task, an input lane or a queue's later
/// turn. Two cases come close and are left out:
/// - an event that code synthesizes and hands to `sendEvent` itself: only the
///   event the app dequeued, which is `NSApp.currentEvent`, opens a dispatch
///   (a DEBUG `simulate_shortcut` chord that matches a menu key equivalent
///   still reaches the menu item's action, which does);
/// - work that runs in a nested run loop while an event is dispatched (a modal
///   alert, a context menu, a window drag): it runs in another run-loop mode
///   than the one the dispatch started in, so it is not part of it.
///
/// Local input that a terminal replays in a later turn (a key held while a
/// clipboard read finishes, a key that starts a cold terminal, a TextBox
/// submit's delayed Return) is not counted again: the event that started it
/// already was.
@MainActor
enum SupermuxLocalUserInput {
    /// An open dispatch of this Mac's user's input.
    struct Scope {
        /// The main run loop's mode when the dispatch started (`nil` when the
        /// run loop was not running, as for the app's top-level event loop).
        fileprivate let mode: RunLoop.Mode?
    }

    private static var current: Scope?

    /// Whether the code running now handles this Mac's user's own input.
    static var isHandling: Bool {
        guard let current else { return false }
        return current.mode == RunLoop.main.currentMode
    }

    /// Called before `NSApplication.sendEvent` dispatches `event`. An event
    /// the app dequeued opens a dispatch when it is user input and closes the
    /// enclosing one for its own handling otherwise; an event code hands to
    /// `sendEvent` itself changes nothing.
    ///
    /// - Returns: The enclosing dispatch, for ``end(restoring:)``.
    static func beginEvent(_ event: NSEvent, application: NSApplication) -> Scope? {
        let enclosing = current
        if application.currentEvent === event {
            current = isUserInput(event.type) ? Scope(mode: RunLoop.main.currentMode) : nil
        }
        return enclosing
    }

    /// Called before `NSApplication.sendAction` sends an action: a menu
    /// item's action is the user's choice.
    ///
    /// - Returns: The enclosing dispatch, for ``end(restoring:)``.
    static func beginAction(from sender: Any?) -> Scope? {
        guard sender is NSMenuItem else { return current }
        return beginUserAction()
    }

    /// Opens a dispatch for a user action the app learns of outside
    /// `sendEvent`: a drop on a terminal.
    ///
    /// - Returns: The enclosing dispatch, for ``end(restoring:)``.
    static func beginUserAction() -> Scope? {
        let enclosing = current
        current = Scope(mode: RunLoop.main.currentMode)
        return enclosing
    }

    /// Called after the dispatch: back to the enclosing one, if any.
    static func end(restoring enclosing: Scope?) {
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

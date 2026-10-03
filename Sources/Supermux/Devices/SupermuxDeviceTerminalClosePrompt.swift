import AppKit
import Foundation

/// The "Close “X” on <Mac>?" prompt for a mirror tab whose terminal runs a
/// program on the owning Mac: **Close** ends it there, **Cancel** keeps it
/// running and brings the tab back. The owning Mac decides whether the prompt
/// is needed (its own close-confirmation rule), so a user who turned
/// confirmation off there is never asked.
///
/// Cancel is the safe default: Return and Esc both answer it, as in
/// ``SupermuxDeviceMirrorClosePrompt``, so no key press ends a program on
/// another Mac. In DEBUG builds `supermux.devices.terminal_close.answer`
/// pre-answers it without showing anything, or (`show`) shows it and answers
/// Cancel a few seconds later.
///
/// It is asked from the close's main-actor task, so it never runs a nested
/// modal session there (``SupermuxAlertPresentation``): a sheet on the
/// workspace's window that the task awaits, or, with no window to hold it,
/// an app-modal alert run from a run-loop block outside the job.
@MainActor
enum SupermuxDeviceTerminalClosePrompt {
    /// A second prompt while one is up answers Cancel instead of stacking.
    private static var isPresenting = false
    /// `kVK_Escape`.
    private static let escapeKeyCode: UInt16 = 53

    /// Whether the user chose Close.
    static func ask(terminalTitle: String, deviceName: String, window: NSWindow?) async -> Bool {
        let title = String(
            format: String(localized: "supermux.devices.terminalClose.prompt.title", defaultValue: "Close “%1$@” on %2$@?"),
            locale: .current, terminalTitle, deviceName
        )
        let message = String(
            format: String(
                localized: "supermux.devices.terminalClose.prompt.message",
                defaultValue: "A process is still running in this terminal on %@. Closing ends it there."
            ),
            locale: .current, deviceName
        )
        #if DEBUG
        let debugAnswer = SupermuxDeviceTerminalCloseDebug.answer
        if let debugAnswer {
            SupermuxDeviceTerminalCloseDebug.asked.append(
                ["title": title, "message": message, "device": deviceName, "shown": debugAnswer == .show]
            )
            if debugAnswer != .show { return debugAnswer == .close }
        }
        #endif
        guard !isPresenting else { return false }
        isPresenting = true
        defer { isPresenting = false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let close = alert.addButton(withTitle: String(localized: "supermux.devices.terminalClose.button.close", defaultValue: "Close"))
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        close.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        alert.window.initialFirstResponder = cancel
        // Return already answers Cancel (its key equivalent); a button holds one
        // key equivalent, so Esc is routed to the same button here.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == escapeKeyCode, event.window === alert.window else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        #if DEBUG
        if debugAnswer == .show { pressLater(cancel) }
        #endif
        return await SupermuxAlertPresentation.present(alert, preferring: window) == .alertFirstButtonReturn
    }
    #if DEBUG

    /// The DEBUG `show` answer: the real prompt, answered Cancel after
    /// ``SupermuxDeviceTerminalCloseDebug/shownSeconds`` by a run-loop timer.
    private static func pressLater(_ button: NSButton) {
        let timer = Timer(timeInterval: SupermuxDeviceTerminalCloseDebug.shownSeconds, repeats: false) { _ in
            MainActor.assumeIsolated { button.performClick(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    #endif
}

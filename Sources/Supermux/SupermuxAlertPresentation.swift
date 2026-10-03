import AppKit

/// Shows an `NSAlert` from main-actor code without a nested modal session in
/// the calling job.
///
/// Upstream's ``NSAlert/runCmuxModal(presentingWindow:content:willPresent:)``
/// runs `NSApp.runModal(for:)` where it is called. From a main-actor task
/// that is a main-queue job, and CFRunLoop does not drain the main queue
/// inside one: every other main-actor task, device mirror and socket request
/// waits until the alert is answered. Here the alert is a sheet on the main
/// window that the caller awaits (or does not wait for), or, with no window
/// to hold it, an app-modal alert run from a run-loop block outside the job.
@MainActor
enum SupermuxAlertPresentation {
    /// Shows `alert` and suspends until it is answered.
    static func present(_ alert: NSAlert, preferring window: NSWindow?) async -> NSApplication.ModalResponse {
        if NSApp.activationPolicy() == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        let host = NSApp.cmuxMainWindowForModalPresentation(preferring: window)
        if alert.accessoryView == nil, !alert.informativeText.isEmpty {
            // Long text scrolls inside the alert, as runCmuxModal does.
            CmuxAlertContent(informativeText: alert.informativeText).apply(to: alert, presentingWindow: host)
        }
        if let host, host.attachedSheet == nil {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: host) { response in
                    continuation.resume(returning: response)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated {
                    continuation.resume(returning: alert.runModal())
                }
            }
        }
    }

    /// Shows a notice (an OK-only alert) without waiting for the answer.
    static func show(_ alert: NSAlert, preferring window: NSWindow?) {
        Task { @MainActor in _ = await present(alert, preferring: window) }
    }
}

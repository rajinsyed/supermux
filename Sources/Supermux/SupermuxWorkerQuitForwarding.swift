import AppKit
import Darwin

/// Hands a quit that reached a worker process to the app it serves.
///
/// The simulator and sidebar-render workers re-run the app's own executable
/// and run an `NSApplication`, so LaunchServices lists them under the app's
/// bundle id, and a quit addressed to that bundle id (`tell application id …
/// to quit`, Shortcuts' Quit App, a launcher's Quit) can go to a worker
/// instead of the app: AppleScript picks the newest process. AppKit's quit
/// handler then ended the worker, the app started another one, and the app
/// never quit. Installed in those workers (the `worker-quit-forwarding`
/// touchpoint), this replaces that handler: an ordinary quit goes on to the
/// worker's parent, the app, and the worker keeps running until the app
/// closes its pipe. The quit is answered without an error, so a script that
/// sent it carries on. A logout, restart or shutdown still quits the worker,
/// and so does a quit once the app is gone.
@MainActor
final class SupermuxWorkerQuitForwarding: NSObject {
    private static var installed: SupermuxWorkerQuitForwarding?

    /// Takes over the worker's quit Apple Event as its `NSApplication`
    /// starts. The worker creates and runs the application itself; this
    /// leaves that order alone. Call it before the worker's run loop starts.
    nonisolated static func install() {
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                let forwarding = SupermuxWorkerQuitForwarding()
                Self.installed = forwarding
                // AppKit has installed its own handlers by now, so this one replaces its quit handler.
                NSAppleEventManager.shared().setEventHandler(
                    forwarding,
                    andSelector: #selector(handleQuit(_:withReplyEvent:)),
                    forEventClass: AEEventClass(kCoreEventClass),
                    andEventID: AEEventID(kAEQuitApplication)
                )
            }
        }
    }

    /// Logout, restart and shutdown set `kAEQuitReason` on the quit event;
    /// Cmd-Q, the Dock and scripts do not.
    @objc private func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let isSystemQuit = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard !isSystemQuit,
              let app = NSRunningApplication(processIdentifier: getppid()),
              app.bundleIdentifier == Bundle.main.bundleIdentifier else {
            NSApp.terminate(nil)
            return
        }
        app.terminate()
    }
}

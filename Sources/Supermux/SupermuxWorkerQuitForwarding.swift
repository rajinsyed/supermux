import AppKit
import Darwin

/// Hands a quit that reached a worker process to the app it serves.
///
/// The simulator and sidebar-render workers re-run the app's own executable
/// and run an `NSApplication`, so LaunchServices lists them under the app's
/// bundle id, and a quit addressed to that bundle id (`tell application id …
/// to quit`, Shortcuts' Quit App, a launcher's Quit) can go to a worker
/// instead of the app: AppleScript picks the newest process. With no
/// delegate the worker quit, the app started another one, and the app never
/// quit. Installed in those workers (the `worker-quit-forwarding`
/// touchpoint), this sends an ordinary quit on to the worker's parent, the
/// app, and keeps the worker, which the app owns: it exits when the app
/// closes its pipe. A logout, restart or shutdown still quits the worker, and
/// so does a quit once the app is gone.
@MainActor
final class SupermuxWorkerQuitForwarding: NSObject, NSApplicationDelegate {
    private static var installed: SupermuxWorkerQuitForwarding?

    /// Becomes the worker's application delegate as its `NSApplication`
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
                NSApplication.shared.delegate = forwarding
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.isSystemQuit,
              let app = NSRunningApplication(processIdentifier: getppid()),
              app.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return .terminateNow
        }
        app.terminate()
        return .terminateCancel
    }

    /// Logout, restart and shutdown set `kAEQuitReason` on the quit event;
    /// Cmd-Q, the Dock and scripts do not.
    private static var isSystemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }
}

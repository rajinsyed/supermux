import Foundation

/// Keeps App Nap off while any remote session is live.
///
/// A Mac serving a phone or another Mac (or viewing another Mac's terminals)
/// is often unattended: Remote Host Mode has no window, the screen may be
/// locked. App Nap then lowers the app's priority and throttles its timers
/// and I/O, which slows every keystroke's echo and every keepalive answer.
/// While any session exists, this holds a `ProcessInfo` activity that opts
/// out of App Nap (`.userInitiatedAllowingIdleSystemSleep`: idle system sleep
/// still happens, and a lid close is never held up); with none, it lets go.
///
/// Sessions are this host's admitted connections (phones and Macs, every
/// dialect: ``MobileHostConnectionRegistry``, which posts
/// `.mobileHostStatusDidChange` on each change) and this Mac's connected links
/// to other Macs (the device events).
@MainActor
final class SupermuxRemoteSessionActivity {
    private var token: NSObjectProtocol?
    private var observer: NSObjectProtocol?
    private var events: Task<Void, Never>?
    private(set) var inbound = 0
    private(set) var outbound = 0

    var isHeld: Bool { token != nil }

    /// Follows the sessions. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .mobileHostStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        let stream = SupermuxComposition.devices.events()
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case .topic = event { continue }
                update()
            }
        }
        update()
    }

    /// Recounts the sessions and holds or lets go of the activity.
    func update() {
        inbound = MobileHostConnectionRegistry.shared.count
        outbound = SupermuxComposition.devices.links.filter(\.isConnected).count
        let wanted = inbound + outbound > 0
        if wanted, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Serving or viewing remote terminals")
        } else if !wanted, let held = token {
            ProcessInfo.processInfo.endActivity(held)
            token = nil
        }
    }
}

// SUPERMUX:begin mobile-foreground-host-idle-redial (a foreground return after the Mac's idle timeout redials without probing — see SUPERMUX-TOUCHPOINTS.md)
import CMUXMobileCore
import Foundation

/// Decides when a foreground return can skip the liveness probe.
///
/// The Mac's Iroh host closes a session 30 s after the phone's last packet
/// (QUIC idle timeout, both ends' iroh default). The phone cannot always tell:
/// its own idle timer runs on a clock that stops while the device sleeps, so
/// after the phone was locked its transport still looks open. Probing that
/// session leaves the request unanswered for the whole probe timeout (3 s),
/// and a timed-out probe on an open-looking transport is kept as healthy.
@MainActor
extension MobileShellComposite {
    /// The Mac's idle timeout for an Iroh session, from its last packet.
    static let supermuxHostSessionIdleSeconds: TimeInterval = 30

    /// How long iOS may keep a backgrounded app running, and answering the
    /// Mac, before it suspends it.
    static let supermuxSuspensionGraceSeconds: TimeInterval = 10

    /// Whether the background dwell that is ending outlived the Mac's
    /// session, so the foreground connection is known dead. Wall-clock time,
    /// which keeps counting while the device sleeps. Iroh routes only: the
    /// Mac's TCP routes keep a silent phone's connection open.
    func supermuxForegroundDwellOutlivedHostSession() -> Bool {
        guard activeRoute?.kind == .iroh, let lastBackgroundedAt else { return false }
        let dwell = (runtime?.now() ?? Date()).timeIntervalSince(lastBackgroundedAt)
        return dwell >= Self.supermuxHostSessionIdleSeconds + Self.supermuxSuspensionGraceSeconds
    }
}
// SUPERMUX:end mobile-foreground-host-idle-redial

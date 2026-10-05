// SUPERMUX:begin sizing-phone-viewer (the phone that views a terminal owns its grid in Auto — see SUPERMUX-TOUCHPOINTS.md)
internal import Foundation

/// Store reads and routes behind the phone's terminal viewport reports, so a
/// terminal is never left at this phone's size once it stops viewing it.
extension MobileShellComposite {
    /// Whether viewport reports have no Mac connection to go to. A report
    /// dropped for this reason is not retried on the bounded relay backoff:
    /// the next connection re-reports every mounted terminal
    /// (`supermuxRemoteClientGeneration`).
    public var supermuxTerminalViewportOffline: Bool { remoteClient == nil }
}
// SUPERMUX:end sizing-phone-viewer

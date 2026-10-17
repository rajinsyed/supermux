import Foundation

/// How shared workspace order runs on this Mac. Always ``normal`` in release
/// builds; a DEBUG E2E switches it with `supermux.devices.order_debug`
/// (``SupermuxOrderSocketCommands``).
enum SupermuxOrderDebugMode: String, CaseIterable {
    /// The reconciler keys own rows, places mirrors and sends mirror moves.
    case normal
    /// The reconciler does nothing, so a test can leave a row where it put it.
    case paused
    /// As ``paused``, and this Mac also withholds `supermux.order_sync.v1`,
    /// exports no keys and refuses `set_order`: an older Mac.
    case oldHost = "old_host"

    #if DEBUG
    /// The current mode. Read by the nonisolated capability list
    /// (`SupermuxMobileCapabilities`); written only on the main actor by the
    /// DEBUG socket command, and a stale read only delays a test by one tick.
    nonisolated(unsafe) static var current: Self = .normal
    #else
    /// The current mode: always ``normal`` outside DEBUG builds.
    static var current: Self { .normal }
    #endif

    /// Whether the reconciler runs.
    var reconciles: Bool { self == .normal }

    /// Whether this Mac serves shared order (capability, key export, `set_order`).
    var servesOrderSync: Bool { self != .oldHost }
}

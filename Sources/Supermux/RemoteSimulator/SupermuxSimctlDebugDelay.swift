import Foundation
import os

/// A DEBUG hook that makes this app's `simctl` calls slow, as they are on a Mac
/// whose new processes stall in dyld before `main` (every `simctl` launch took
/// 20–22 s there, 2026-10-03). ``SupermuxSimulatorControl`` waits here before
/// each call that spawns `xcrun simctl`, so the E2E suite can check that
/// remote simulators keep working on such a Mac.
///
/// Armed by `SUPERMUX_DEBUG_SIMCTL_DELAY_SECONDS=<seconds>` at launch or the
/// `supermux.devices.mirror.simulator.simctl_delay {seconds}` driver; 0 (the
/// default) turns it off. Release builds have no delay.
enum SupermuxSimctlDebugDelay {
    #if DEBUG
    static let environmentKey = "SUPERMUX_DEBUG_SIMCTL_DELAY_SECONDS"

    private static let state = OSAllocatedUnfairLock<Double>(
        initialState: Double(ProcessInfo.processInfo.environment[environmentKey] ?? "") ?? 0
    )

    /// The delay per `simctl` spawn, in seconds.
    static var seconds: Double {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = max(0, newValue) } }
    }

    /// Waits as `spawns` slow `simctl` launches would.
    static func beforeSpawns(_ spawns: Int, _ what: String) async throws {
        let delay = seconds * Double(spawns)
        guard delay > 0 else { return }
        cmuxDebugLog("supermux.simctlDelay \(what): waiting \(delay)s before \(spawns) simctl spawn(s)")
        try await Task.sleep(for: .seconds(delay))
    }
    #else
    @inline(__always)
    static func beforeSpawns(_ spawns: Int, _ what: String) async throws {}
    #endif
}

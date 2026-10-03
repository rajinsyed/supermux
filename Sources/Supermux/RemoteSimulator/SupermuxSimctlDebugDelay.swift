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
/// default) turns it off. The driver's `coresimulator: false` also makes the
/// panels list devices with `simctl` (the fallback on a Mac where CoreSimulator
/// cannot be used), and `coresimulator_delay` (or
/// `SUPERMUX_DEBUG_CORESIMULATOR_DELAY_SECONDS` at launch) holds every in-process
/// CoreSimulator read that long, as a cold or busy CoreSimulatorService would.
/// Release builds have no delay and always use CoreSimulator.
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

    private static let coreSimulatorState = OSAllocatedUnfairLock<Bool>(initialState: true)

    /// Whether the panels may list devices through CoreSimulator in-process.
    static var allowsCoreSimulator: Bool {
        get { coreSimulatorState.withLock { $0 } }
        set { coreSimulatorState.withLock { $0 = newValue } }
    }

    static let coreSimulatorEnvironmentKey = "SUPERMUX_DEBUG_CORESIMULATOR_DELAY_SECONDS"

    private static let coreSimulatorDelayState = OSAllocatedUnfairLock<Double>(
        initialState: Double(ProcessInfo.processInfo.environment[coreSimulatorEnvironmentKey] ?? "") ?? 0
    )

    /// How long each in-process CoreSimulator read takes at least, in seconds.
    static var coreSimulatorDelay: Double {
        get { coreSimulatorDelayState.withLock { $0 } }
        set { coreSimulatorDelayState.withLock { $0 = max(0, newValue) } }
    }

    static let coreSimulatorLoadHoldEnvironmentKey = "SUPERMUX_DEBUG_CORESIMULATOR_LOAD_HOLD_SECONDS"

    /// Holds the in-process CoreSimulator load open (inside its crash-guard
    /// marker), as the service context of a cold CoreSimulatorService would:
    /// set at launch only, since a process loads CoreSimulator once.
    static func duringCoreSimulatorLoad() {
        let hold = Double(ProcessInfo.processInfo.environment[coreSimulatorLoadHoldEnvironmentKey] ?? "") ?? 0
        guard hold > 0 else { return }
        cmuxDebugLog("supermux.simctlDelay coresimulator: holding the load \(hold)s")
        Thread.sleep(forTimeInterval: hold)
    }

    /// Holds the CoreSimulator queue as a slow CoreSimulatorService would.
    static func beforeCoreSimulatorRead() {
        let delay = coreSimulatorDelay
        guard delay > 0 else { return }
        cmuxDebugLog("supermux.simctlDelay coresimulator: holding a device-set read \(delay)s")
        Thread.sleep(forTimeInterval: delay)
    }

    /// Waits as `spawns` slow `simctl` launches would.
    static func beforeSpawns(_ spawns: Int, _ what: String) async throws {
        let delay = seconds * Double(spawns)
        guard delay > 0 else { return }
        cmuxDebugLog("supermux.simctlDelay \(what): waiting \(delay)s before \(spawns) simctl spawn(s)")
        try await Task.sleep(for: .seconds(delay))
    }
    #else
    static var allowsCoreSimulator: Bool { true }

    @inline(__always)
    static func beforeCoreSimulatorRead() {}

    @inline(__always)
    static func duringCoreSimulatorLoad() {}

    @inline(__always)
    static func beforeSpawns(_ spawns: Int, _ what: String) async throws {}
    #endif
}

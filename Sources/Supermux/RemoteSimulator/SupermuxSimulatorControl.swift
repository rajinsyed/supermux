import CmuxSimulator
import Foundation

/// The simulator control behind every `SimulatorPanel` on this Mac (the
/// `simulator-panel-control` touchpoint): upstream's `SimulatorControlService`,
/// where each call launches `xcrun simctl`, except where a launch is not needed.
///
/// - The device list comes from CoreSimulator in-process
///   (``SupermuxCoreSimulatorDevices``): no `simctl list`, so a Mac where every
///   process launch stalls (20–22 s per `simctl`, 2026-10-03) still lists its
///   simulators at once, the panel picks a device at once, and another Mac's
///   device menu fills within the device link's reply deadline. When
///   CoreSimulator cannot be used, `simctl list` runs as before.
/// - Booting a device CoreSimulator already reports booted returns at once
///   (`simctl boot` would only answer "current state: Booted").
///
/// In DEBUG, every call that still launches `simctl` first waits for the
/// slow-`simctl` hook (``SupermuxSimctlDebugDelay``).
struct SupermuxSimulatorControl: SimulatorControlling {
    let service: SimulatorControlService
    var devices: SupermuxCoreSimulatorDevices = .shared

    /// How long a panel's discovery waits for CoreSimulator: upstream's 30 s
    /// `simctl` command timeout. A cold CoreSimulatorService (after a reboot)
    /// can take longer than the 8 s another Mac's device menu waits
    /// (``SupermuxSimulatorDeviceListing``), and a panel that gave up at 8 s
    /// failed and never activated its device.
    static let discoveryBudget: TimeInterval = 30
    /// How long `boot` asks CoreSimulator whether the device already runs
    /// before it runs `simctl boot` anyway.
    static let bootStateBudget: TimeInterval = 5

    /// CoreSimulator, unless a DEBUG test turned it off to exercise the `simctl` fallback.
    private var coreSimulator: SupermuxCoreSimulatorDevices? {
        SupermuxSimctlDebugDelay.allowsCoreSimulator ? devices : nil
    }

    /// The control a new panel's worker client gets, with the app's location
    /// and camera cleanup scopes, as upstream's client factory builds it.
    @MainActor
    static func make() -> SupermuxSimulatorControl {
        SupermuxSimulatorControl(service: SimulatorControlService(
            locationOwnershipScope: TerminalController.shared.simulatorLocationOwnershipScope,
            cameraCleanupOwnershipScope: TerminalController.shared.simulatorCameraCleanupOwnershipScope
        ))
    }

    /// This Mac's simulators, read as a panel's discovery reads them but
    /// without touching any panel (another Mac's device menu while a panel
    /// still starts, ``SupermuxSimulatorDeviceListing``).
    @MainActor
    static func listDevices() async throws -> [SimulatorDevice] {
        try await make().discoverDevices()
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        if let coreSimulator {
            do {
                return try await coreSimulator.devices(timeout: Self.discoveryBudget)
            } catch SupermuxCoreSimulatorDevices.Failure.slow {
                // CoreSimulatorService itself is not answering: `simctl` would wait on it too.
                throw SupermuxSimulatorSlow.failure
            } catch {
                // CoreSimulator cannot be used here: ask `simctl`.
            }
        }
        // `simctl list devices` and `simctl list runtimes`.
        try await SupermuxSimctlDebugDelay.beforeSpawns(2, "list")
        return try await service.discoverDevices()
    }

    func boot(deviceID: String) async throws {
        if await coreSimulator?.state(of: deviceID, timeout: Self.bootStateBudget) == .booted { return }
        try await SupermuxSimctlDebugDelay.beforeSpawns(1, "boot")
        try await service.boot(deviceID: deviceID)
    }

    func waitUntilBooted(deviceID: String) async throws {
        try await SupermuxSimctlDebugDelay.beforeSpawns(1, "bootstatus")
        try await service.waitUntilBooted(deviceID: deviceID)
    }

    func shutdown(deviceID: String) async throws {
        try await SupermuxSimctlDebugDelay.beforeSpawns(1, "shutdown")
        try await service.shutdown(deviceID: deviceID)
    }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        try await SupermuxSimctlDebugDelay.beforeSpawns(1, "perform")
        return try await service.perform(action)
    }
}

/// This Mac's simulators did not answer in time: the panel shows this failure,
/// and another Mac's device menu says so through `slow` in
/// `mobile.simulator.devices.list` (``SupermuxSimulatorDeviceListing``).
enum SupermuxSimulatorSlow {
    static let code = "supermux_simulators_slow"

    static var failure: SimulatorFailure {
        SimulatorFailure(
            code: code,
            message: String(
                localized: "supermux.simulator.slow",
                defaultValue: "Simulators on this Mac are slow to respond."
            ),
            isRecoverable: true
        )
    }
}

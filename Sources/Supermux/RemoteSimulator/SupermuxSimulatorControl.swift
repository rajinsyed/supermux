import CmuxSimulator
import Foundation

/// The simulator control behind every `SimulatorPanel` on this Mac (the
/// `simulator-panel-control` touchpoint): upstream's `SimulatorControlService`,
/// where each call spawns `xcrun simctl`, with the DEBUG slow-`simctl` hook
/// (``SupermuxSimctlDebugDelay``) in front of every call that spawns one.
struct SupermuxSimulatorControl: SimulatorControlling {
    let service: SimulatorControlService

    /// The control a new panel's worker client gets, with the app's location
    /// and camera cleanup scopes, as upstream's client factory builds it.
    @MainActor
    static func make() -> SupermuxSimulatorControl {
        SupermuxSimulatorControl(service: SimulatorControlService(
            locationOwnershipScope: TerminalController.shared.simulatorLocationOwnershipScope,
            cameraCleanupOwnershipScope: TerminalController.shared.simulatorCameraCleanupOwnershipScope
        ))
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        // `simctl list devices` and `simctl list runtimes`.
        try await SupermuxSimctlDebugDelay.beforeSpawns(2, "list")
        return try await service.discoverDevices()
    }

    func boot(deviceID: String) async throws {
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

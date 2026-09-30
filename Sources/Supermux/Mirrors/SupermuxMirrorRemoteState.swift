import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// What mirror features need to know about each owning Mac's Supermux state:
/// its projects and terminal presets (`projects.list`) and its run state
/// (`run.state`). Demand-driven: a device is fetched only after something
/// asked about it (a mirror of it was selected or acted on), then kept fresh
/// from the facade's `supermux.projects/run.updated` pokes and reconnects.
///
/// Scoped to the mirror behaviors (⌘G, presets bar, project actions); the
/// sidebar's cross-device projects model is a separate concern.
@MainActor
@Observable
final class SupermuxMirrorRemoteState {
    /// One Mac's cached state.
    struct DeviceState: Equatable {
        var projects: [SupermuxProjectDTO] = []
        var presets: [SupermuxTerminalPresetDTO] = []
        var runs: [SupermuxRunStateDTO] = []
        var hasProjects = false
        var hasRuns = false
    }

    private(set) var states: [SurfaceMachineID: DeviceState] = [:]

    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private var followed: Set<SurfaceMachineID> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]

    init(devices: SupermuxDevices) {
        self.devices = devices
    }

    // MARK: - Reads (safe in view bodies)

    /// The device's run rows; asks for them when not yet known.
    func runs(on machine: SurfaceMachineID) -> [SupermuxRunStateDTO] {
        follow(machine)
        return states[machine]?.runs ?? []
    }

    /// The device's terminal presets; asks for them when not yet known.
    func presets(on machine: SurfaceMachineID) -> [SupermuxTerminalPresetDTO] {
        follow(machine)
        return states[machine]?.presets ?? []
    }

    /// Whether the mirror's own remote workspace runs its project's command.
    func isRunning(_ target: SupermuxMirrorTarget) -> Bool {
        guard let projectID = target.remoteProjectID else { return false }
        return runs(on: target.machine).contains { run in
            run.isRunning == true
                && run.projectId.caseInsensitiveCompare(projectID) == .orderedSame
                && run.workspaceId.map(SupermuxRemoteWorkspaceRef.canonicalWorkspaceID) == target.ref.workspaceID
        }
    }

    // MARK: - Loads

    /// Fetches the device's projects and presets now.
    func refreshProjects(on machine: SurfaceMachineID) async {
        follow(machine)
        guard let result = try? await devices.request(.projectsList, on: machine) else { return }
        let wire = SupermuxWireJSON()
        let projects = (result["projects"] as? [[String: Any]] ?? []).compactMap { try? wire.decode(SupermuxProjectDTO.self, from: $0) }
        let presets = (result["presets"] as? [[String: Any]] ?? []).compactMap { try? wire.decode(SupermuxTerminalPresetDTO.self, from: $0) }
        update(machine) { $0.projects = projects; $0.presets = presets; $0.hasProjects = true }
    }

    /// Fetches the device's run state now.
    func refreshRuns(on machine: SurfaceMachineID) async {
        follow(machine)
        guard let result = try? await devices.request(.runState, on: machine) else { return }
        let wire = SupermuxWireJSON()
        let runs = (result["runs"] as? [[String: Any]] ?? []).compactMap { try? wire.decode(SupermuxRunStateDTO.self, from: $0) }
        update(machine) { $0.runs = runs; $0.hasRuns = true }
    }

    /// Folds a `run.start` / `run.stop` result in before the host's poke lands.
    func apply(run: SupermuxRunStateDTO, on machine: SurfaceMachineID) {
        update(machine) { state in
            state.runs.removeAll { $0.projectId.caseInsensitiveCompare(run.projectId) == .orderedSame }
            state.runs.append(run)
        }
    }

    // MARK: - Following

    /// Starts keeping a device fresh (first ask loads it; later pokes refetch).
    private func follow(_ machine: SurfaceMachineID) {
        guard machine.isDevice else { return }
        startEventsIfNeeded()
        guard followed.insert(machine).inserted else { return }
        schedule(machine, projects: true, runs: true)
    }

    private func schedule(_ machine: SurfaceMachineID, projects: Bool, runs: Bool) {
        if projects { load("projects|\(machine.rawValue)") { await $0.refreshProjects(on: machine) } }
        if runs { load("runs|\(machine.rawValue)") { await $0.refreshRuns(on: machine) } }
    }

    /// One in-flight load per key; a burst of pokes coalesces into it.
    private func load(_ key: String, _ body: @escaping @MainActor (SupermuxMirrorRemoteState) async -> Void) {
        guard pending[key] == nil else { return }
        pending[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self)
            self.pending[key] = nil
        }
    }

    private func startEventsIfNeeded() {
        guard eventTask == nil else { return }
        let events = devices.events()
        eventTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                let machine = event.machine
                guard self.followed.contains(machine) else { continue }
                switch event {
                case .linkConnected:
                    self.schedule(machine, projects: true, runs: true)
                case .linkLost:
                    continue
                case .topic(_, let topic, _):
                    switch topic {
                    case .projectsUpdated: self.schedule(machine, projects: true, runs: false)
                    case .runUpdated: self.schedule(machine, projects: false, runs: true)
                    default: continue
                    }
                }
            }
        }
    }

    private func update(_ machine: SurfaceMachineID, _ change: (inout DeviceState) -> Void) {
        var state = states[machine] ?? DeviceState()
        change(&state)
        if states[machine] != state { states[machine] = state }
    }
}


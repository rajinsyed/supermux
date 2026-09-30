import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// Cross-Mac project sync (setting `supermux.devices.syncProjects`, default
/// on): when a Mac connects or either side's projects change, each Mac
/// registers the other's projects whose repository it already has at the SAME
/// root path with the SAME origin (``SupermuxProjectSyncPlanner``). Push
/// (register on the other Mac) goes through `project.probe` → `project.create`
/// → `project.update`; pull registers here through the projects model. Sync
/// never clones, never deletes, and skips roots a user removed
/// (``SupermuxProjectSyncSuppression``). The loopback device is skipped: it
/// shares this app's own project list.
@MainActor
final class SupermuxProjectSyncCoordinator {
    /// What the last pass registered, for introspection.
    struct Report: Sendable {
        var finishedAt: Date?
        /// Root paths registered on this Mac.
        var registeredHere: [String] = []
        /// Root paths registered on other Macs, keyed by machine id.
        var registeredOn: [String: [String]] = [:]
        /// Machines the pass looked at.
        var devicesChecked: [String] = []
    }

    private(set) var lastReport = Report()

    private let settings: SupermuxDevicesSettings
    private let devices: SupermuxDevices
    private let remoteProjects: SupermuxRemoteProjectsModel
    private let projectsModel: SupermuxProjectsModel
    private let gitRemotes: SupermuxProjectGitRemotes
    private let setupService: SupermuxProjectSetupService
    private let suppression: SupermuxProjectSyncSuppression
    private var task: Task<Void, Never>?
    private var isSyncing = false
    private var syncAgain = false
    private var knownRoots: [UUID: String]?
    private var lastSignature: [String] = []

    init(
        settings: SupermuxDevicesSettings,
        devices: SupermuxDevices,
        remoteProjects: SupermuxRemoteProjectsModel,
        projectsModel: SupermuxProjectsModel,
        gitRemotes: SupermuxProjectGitRemotes,
        setupService: SupermuxProjectSetupService,
        suppression: SupermuxProjectSyncSuppression
    ) {
        self.settings = settings
        self.devices = devices
        self.remoteProjects = remoteProjects
        self.projectsModel = projectsModel
        self.gitRemotes = gitRemotes
        self.setupService = setupService
        self.suppression = suppression
    }

    /// Starts following both sides' projects. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let model = self?.projectsModel else { return }
            await model.loadIfNeeded()
            while !Task.isCancelled {
                guard let self else { return }
                self.trackRemovals()
                if self.inputsChangedSinceLastPass() { await self.syncNow() }
                await self.waitForInputChange()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Passes run only when a project list, origin or link changed (or the
    /// last pass is old), so worktree and run-state churn never re-probes.
    private func inputsChangedSinceLastPass() -> Bool {
        let signature = inputSignature()
        let isStale = lastReport.finishedAt.map { Date().timeIntervalSince($0) > Self.maximumPassAge } ?? true
        guard signature != lastSignature || isStale else { return false }
        lastSignature = signature
        return true
    }

    private func inputSignature() -> [String] {
        let local = projectsModel.projects.map { "local|\($0.rootPath)|\(gitRemotes.url(for: $0.id) ?? "")" }
        let remote = remoteProjects.devices.flatMap { device in
            ["\(device.machine.rawValue)|\(device.isOnline)|\(device.isFromCache)"]
                + device.projects.map { "\(device.machine.rawValue)|\($0.rootPath)|\($0.gitRemoteURL ?? "")" }
        }
        return (local + remote).sorted()
    }

    /// A pass older than this re-runs on the next input change even when the
    /// lists look unchanged (a repo cloned by hand since).
    private static let maximumPassAge: TimeInterval = 600

    /// Runs one pass now (coalesces with a pass already running).
    @discardableResult
    func syncNow() async -> Report {
        guard settings.syncProjects else { return lastReport }
        guard !isSyncing else {
            syncAgain = true
            return lastReport
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            lastReport = await performPass()
        } while syncAgain
        return lastReport
    }

    // MARK: - Pass

    private func performPass() async -> Report {
        var report = Report()
        for device in remoteProjects.devices
        where device.isOnline && !device.isLoopback && device.supportsProjects == true && !device.isFromCache {
            report.devicesChecked.append(device.machine.rawValue)
            let local = localProjects()
            let pushed = await push(local, to: device)
            if !pushed.isEmpty { report.registeredOn[device.machine.rawValue] = pushed }
            report.registeredHere += await pull(from: device, local: local)
        }
        report.finishedAt = Date()
        return report
    }

    /// Registers this Mac's projects on `device` where it has the same repo.
    private func push(_ local: [SupermuxProjectDTO], to device: SupermuxDeviceProjects) async -> [String] {
        guard await devices.supports(.projectSetupV1, on: device.machine) else { return [] }
        var registered: [String] = []
        for candidate in SupermuxProjectSyncPlanner.candidates(source: local, destination: device.projects) {
            do {
                let probe = try await devices.request(
                    SupermuxMobileMethod.projectProbe.rawValue,
                    params: ["root_path": candidate.rootPath],
                    on: device.machine,
                    as: SupermuxProjectProbeDTO.self
                )
                guard SupermuxProjectSyncPlanner.shouldRegister(candidate, probe: probe) else { continue }
                let created = try await devices.request(
                    SupermuxMobileMethod.projectCreate.rawValue,
                    params: ["root_path": probe.rootPath],
                    on: device.machine,
                    resultKey: "project",
                    as: SupermuxProjectDTO.self
                )
                let patch = SupermuxProjectSyncPlanner.settingsPatch(
                    from: candidate,
                    destinationIsConfigManaged: created.configPath != nil
                )
                _ = try? await devices.request(
                    .projectUpdate,
                    params: ["project_id": created.id, "patch": patch],
                    on: device.machine
                )
                registered.append(probe.rootPath)
            } catch {
                continue
            }
        }
        if !registered.isEmpty { await remoteProjects.refresh(device.machine) }
        return registered
    }

    /// Registers `device`'s projects here where this Mac has the same repo.
    private func pull(from device: SupermuxDeviceProjects, local: [SupermuxProjectDTO]) async -> [String] {
        var registered: [String] = []
        for candidate in SupermuxProjectSyncPlanner.candidates(source: device.projects, destination: local) {
            let root = candidate.rootPath
            let probe = await setupService.probe(rootPath: root, isSuppressed: suppression.isSuppressed(rootPath: root))
            guard SupermuxProjectSyncPlanner.shouldRegister(candidate, probe: probe) else { continue }
            let project = await projectsModel.addProject(rootPath: probe.rootPath)
            let rootPath = project.rootPath
            let configManaged = await Task.detached(priority: .utility) {
                SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: rootPath) != nil
            }.value
            let patch = SupermuxProjectSyncPlanner.settingsPatch(from: candidate, destinationIsConfigManaged: configManaged)
            if let current = projectsModel.projects.first(where: { $0.id == project.id }),
               let updated = try? SupermuxMobileProjectPatch(wire: patch).applied(to: current, isConfigManaged: configManaged) {
                projectsModel.updateProject(updated)
            }
            knownRoots?[project.id] = project.rootPath
            registered.append(probe.rootPath)
        }
        return registered
    }

    private func localProjects() -> [SupermuxProjectDTO] {
        projectsModel.projects.map {
            SupermuxProjectDTO(project: $0, hasCustomIcon: false, gitRemoteURL: gitRemotes.url(for: $0.id))
        }
    }

    // MARK: - Removal tracking

    /// Records roots the user removed (suppressed from sync) and clears
    /// roots added again.
    private func trackRemovals() {
        let current = Dictionary(
            projectsModel.projects.map { ($0.id, $0.rootPath) },
            uniquingKeysWith: { first, _ in first }
        )
        defer { knownRoots = current }
        guard let known = knownRoots else { return }
        for (id, root) in known where current[id] == nil {
            suppression.suppress(rootPath: root)
        }
        for (id, root) in current where known[id] == nil {
            suppression.clear(rootPath: root)
        }
    }

    private func waitForInputChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = projectsModel.projects
                _ = gitRemotes.urlsByProjectID
                _ = remoteProjects.devices
            } onChange: {
                continuation.resume()
            }
        }
    }
}

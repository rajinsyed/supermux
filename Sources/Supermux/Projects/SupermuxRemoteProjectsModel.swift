import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// Every other Mac's projects, live over its device link (DESIGN decision 4:
/// each Mac is the source of truth for its own projects; nothing here is ever
/// written to `supermux-projects.json`).
///
/// For each device whose host serves `supermux.projects.v1` it keeps
/// `projects.list` (projects and terminal presets), `run.state`, and — lazily,
/// once a row needs them — `worktrees.list` per project. It is the single
/// source of each Mac's Supermux state: the sidebar and the device-mirror
/// behaviors (⌘G / Run, presets bar) all read it, so each Mac is polled once. It refreshes on the matching `supermux.*`
/// topics, on every link (re)connect, and on a slow safety-net timer. The last
/// project list of each Mac is cached on disk
/// (``SupermuxRemoteProjectsCache``), so an offline Mac's projects still
/// render (dimmed). Icons come from `project.icon` with etag caching.
///
/// ```swift
/// let remote = SupermuxComposition.remoteProjects
/// for device in remote.devices where device.isOnline { … device.projects … }
/// remote.ensureWorktrees(on: machine, projectID: id)   // when a row expands
/// ```
@MainActor
@Observable
final class SupermuxRemoteProjectsModel {
    /// Known Macs in device order (online and offline), loopback last.
    private(set) var devices: [SupermuxDeviceProjects] = []
    /// Fetched project icons keyed by ``projectKey(machine:projectID:)``.
    private(set) var icons: [String: NSImage] = [:]

    /// How often every connected Mac is refreshed even without events.
    static let safetyNetInterval: Duration = .seconds(120)

    @ObservationIgnored let facade: SupermuxDevices
    @ObservationIgnored private let cache: SupermuxRemoteProjectsCache
    @ObservationIgnored private var cachedEntries: [String: SupermuxRemoteProjectsCache.Entry] = [:]
    /// The latest offline-cache write; each save waits for it, so writes land in call order.
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    @ObservationIgnored private var iconETags: [String: String] = [:]
    /// `machine|projectID` keys whose worktree list a row asked for.
    @ObservationIgnored private var wantedWorktrees: Set<String> = []
    @ObservationIgnored private var refreshing: Set<SurfaceMachineID> = []
    @ObservationIgnored private var refreshAgain: Set<SurfaceMachineID> = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(facade: SupermuxDevices, cache: SupermuxRemoteProjectsCache) {
        self.facade = facade
        self.cache = cache
    }

    /// Loads the offline cache and starts following devices. Idempotent.
    func start() {
        guard tasks.isEmpty else { return }
        cachedEntries = cache.load()
        let events = facade.events()
        tasks.append(Task { @MainActor [weak self] in
            for await event in events {
                self?.handle(event)
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reconcileDevices()
                await self.waitForDeviceListChange()
            }
        })
        tasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.safetyNetInterval)
                self?.refreshAll()
            }
        })
    }

    // MARK: - Lookup

    /// One Mac's state.
    func device(_ machine: SurfaceMachineID) -> SupermuxDeviceProjects? {
        devices.first { $0.machine == machine }
    }

    /// The `machine|projectID` key of one Mac's project (icons, worktree requests).
    static func projectKey(machine: SurfaceMachineID, projectID: UUID) -> String {
        "\(machine.rawValue)|\(projectID.uuidString)"
    }

    /// A remote project's fetched icon.
    func icon(machine: SurfaceMachineID, projectID: UUID) -> NSImage? {
        icons[Self.projectKey(machine: machine, projectID: projectID)]
    }

    // MARK: - Refresh

    /// Refreshes every connected Mac.
    func refreshAll() {
        for device in devices where device.isOnline {
            Task { await refresh(device.machine) }
        }
    }

    /// Refetches one Mac's projects, run states, icons and the worktree lists
    /// rows asked for. Concurrent calls coalesce into one extra pass.
    func refresh(_ machine: SurfaceMachineID) async {
        guard refreshing.insert(machine).inserted else {
            refreshAgain.insert(machine)
            return
        }
        repeat {
            refreshAgain.remove(machine)
            await performRefresh(machine)
        } while refreshAgain.contains(machine)
        refreshing.remove(machine)
    }

    /// Loads a project's worktrees the first time a row needs them; later
    /// changes arrive through `supermux.worktrees.updated`.
    func ensureWorktrees(on machine: SurfaceMachineID, projectID: UUID) {
        let key = Self.projectKey(machine: machine, projectID: projectID)
        let isLoaded = device(machine)?.worktreesByProjectID[projectID] != nil
        guard wantedWorktrees.insert(key).inserted || !isLoaded else { return }
        Task { await refreshWorktrees(on: machine, projectID: projectID) }
    }

    /// Refetches one project's worktrees (`include_branches: false`).
    func refreshWorktrees(on machine: SurfaceMachineID, projectID: UUID) async {
        wantedWorktrees.insert(Self.projectKey(machine: machine, projectID: projectID))
        guard device(machine)?.isOnline == true else { return }
        do {
            let worktrees = try await facade.request(
                SupermuxMobileMethod.worktreesList.rawValue,
                params: ["project_id": projectID.uuidString, "include_branches": false],
                on: machine,
                resultKey: "worktrees",
                as: [SupermuxWorktreeDTO].self
            )
            update(machine) { $0.worktreesByProjectID[projectID] = worktrees }
        } catch {
            update(machine) { $0.lastError = error.localizedDescription }
        }
    }

    /// Refetches only one Mac's `run.state` (after a mirror's Run / Stop).
    func refreshRuns(_ machine: SurfaceMachineID) async {
        guard device(machine)?.isOnline == true, let state = try? await fetchRuns(on: machine) else { return }
        update(machine) { $0.setRuns(state) }
    }

    /// Folds a `run.start` / `run.stop` result for that Mac's workspace
    /// `remoteWorkspaceID` in before the host's poke lands.
    func apply(run: SupermuxRunStateDTO, on machine: SurfaceMachineID, remoteWorkspaceID: String) {
        update(machine) { $0.apply(run: run, remoteWorkspaceID: remoteWorkspaceID) }
    }

    private func fetchRuns(on machine: SurfaceMachineID) async throws -> SupermuxDeviceProjects.RunState {
        try await facade.request(
            SupermuxMobileMethod.runState.rawValue,
            on: machine,
            as: SupermuxDeviceProjects.RunState.self
        )
    }

    // MARK: - Events

    private func handle(_ event: SupermuxDeviceEvent) {
        switch event {
        case .linkConnected(let machine):
            update(machine) { $0.isOnline = true }
            Task { await refresh(machine) }
        case .linkLost(let machine):
            update(machine) { $0.isOnline = false }
        case .topic(let machine, .projectsUpdated, _), .topic(let machine, .runUpdated, _):
            Task { await refresh(machine) }
        case .topic(let machine, .worktreesUpdated, _):
            Task { await refreshWantedWorktrees(on: machine) }
        case .topic:
            break
        }
    }

    private func refreshWantedWorktrees(on machine: SurfaceMachineID) async {
        let prefix = "\(machine.rawValue)|"
        for key in wantedWorktrees where key.hasPrefix(prefix) {
            guard let projectID = UUID(uuidString: String(key.dropFirst(prefix.count))) else { continue }
            await refreshWorktrees(on: machine, projectID: projectID)
        }
    }

    // MARK: - Device list

    private func waitForDeviceListChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = facade.devices
            } onChange: {
                continuation.resume()
            }
        }
    }

    /// Mirrors the facade's device list: names and link state, cached
    /// projects for Macs not refreshed yet, and a refresh for Macs that just
    /// came online.
    private func reconcileDevices() {
        var next: [SupermuxDeviceProjects] = []
        var cameOnline: [SurfaceMachineID] = []
        for device in facade.devices {
            var entry = self.device(device.machine) ?? cachedEntry(for: device) ?? .empty(for: device)
            if device.isConnected && (!entry.isOnline || entry.supportsProjects == nil) {
                cameOnline.append(device.machine)
            }
            entry.name = device.displayName
            entry.isOnline = device.isConnected
            entry.isLoopback = device.isLoopback
            next.append(entry)
        }
        if next != devices { devices = next }
        for machine in cameOnline {
            Task { await refresh(machine) }
        }
    }

    private func cachedEntry(for device: SupermuxDevice) -> SupermuxDeviceProjects? {
        guard !device.isLoopback, let cached = cachedEntries[device.machine.rawValue] else { return nil }
        var entry = SupermuxDeviceProjects.empty(for: device)
        entry.projects = cached.projects
        entry.isFromCache = true
        entry.isOnline = false
        return entry
    }

    // MARK: - Fetch

    private func performRefresh(_ machine: SurfaceMachineID) async {
        guard let device = facade.device(for: machine), device.isConnected else { return }
        guard let capabilities = await facade.hostCapabilities(on: machine) else { return }
        let supportsProjects = capabilities.contains(SupermuxMobileCapability.projectsV1.rawValue)
        update(machine) { $0.supportsProjects = supportsProjects }
        guard supportsProjects else {
            update(machine) { $0.projects = [] }
            return
        }
        do {
            let listing = try await facade.request(
                SupermuxMobileMethod.projectsList.rawValue,
                on: machine,
                as: ProjectsListing.self
            )
            let projects = listing.projects
            var runs = SupermuxDeviceProjects.RunState.none
            if capabilities.contains(SupermuxMobileCapability.runV1.rawValue) {
                runs = (try? await fetchRuns(on: machine)) ?? .none
            }
            let listed = Set(projects.compactMap { UUID(uuidString: $0.id) })
            update(machine) { entry in
                entry.projects = projects
                entry.presets = listing.presets ?? []
                entry.setRuns(runs)
                entry.isFromCache = false
                entry.lastError = nil
                entry.worktreesByProjectID = entry.worktreesByProjectID.filter { listed.contains($0.key) }
            }
            if !device.isLoopback { saveCache(machine: machine, name: device.displayName, projects: projects) }
            await refreshIcons(on: machine, projects: projects)
            await refreshWantedWorktrees(on: machine)
        } catch {
            update(machine) { $0.lastError = error.localizedDescription }
        }
    }

    private func refreshIcons(on machine: SurfaceMachineID, projects: [SupermuxProjectDTO]) async {
        var live: Set<String> = []
        for project in projects {
            guard let id = UUID(uuidString: project.id), project.iconETag != nil || project.hasCustomIcon == true else { continue }
            let key = Self.projectKey(machine: machine, projectID: id)
            live.insert(key)
            if let etag = project.iconETag, iconETags[key] == etag, icons[key] != nil { continue }
            var params: [String: Any] = ["project_id": project.id]
            if icons[key] != nil, let etag = iconETags[key] { params["etag"] = etag }
            guard let result = try? await facade.request(SupermuxMobileMethod.projectIcon.rawValue, params: params, on: machine),
                  result["not_modified"] as? Bool != true else { continue }
            if let base64 = result["png_base64"] as? String,
               let data = Data(base64Encoded: base64),
               let image = NSImage(data: data) {
                icons[key] = image
                iconETags[key] = result["etag"] as? String
            }
        }
        let prefix = "\(machine.rawValue)|"
        for key in icons.keys where key.hasPrefix(prefix) && !live.contains(key) {
            icons[key] = nil
            iconETags[key] = nil
        }
    }

    private func saveCache(machine: SurfaceMachineID, name: String, projects: [SupermuxProjectDTO]) {
        let entry = SupermuxRemoteProjectsCache.Entry(name: name, projects: projects, savedAt: Date())
        guard cachedEntries[machine.rawValue]?.projects != projects || cachedEntries[machine.rawValue]?.name != name else { return }
        cachedEntries[machine.rawValue] = entry
        let cache = self.cache
        let previous = cacheWrite
        cacheWrite = Task.detached(priority: .utility) {
            await previous?.value
            try? await cache.save(entry, forMachine: machine.rawValue)
        }
    }

    /// The `projects.list` result: projects plus the Mac's terminal presets
    /// (absent on hosts that predate them).
    private struct ProjectsListing: Decodable {
        let projects: [SupermuxProjectDTO]
        let presets: [SupermuxTerminalPresetDTO]?
    }

    private func update(_ machine: SurfaceMachineID, _ mutate: (inout SupermuxDeviceProjects) -> Void) {
        guard let index = devices.firstIndex(where: { $0.machine == machine }) else { return }
        var entry = devices[index]
        mutate(&entry)
        if entry != devices[index] { devices[index] = entry }
    }
}

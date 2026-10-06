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
/// `projects.list` (projects and terminal presets), `run.state`, and
/// `worktrees.list` for every listed project (so a project row knows whether
/// it has a worktree to reveal without being expanded). The worktree lists
/// load in a sweep beside each refresh, a few at a time, so a slow sweep never
/// holds up the next project list or run state. It is the single
/// source of each Mac's Supermux state: the sidebar and the device-mirror
/// behaviors (⌘G / Run, presets bar) all read it, so each Mac is polled once. It refreshes on the matching `supermux.*`
/// topics (`run.updated` refetches only the run state), once per link
/// (re)connect, and on a slow safety-net timer. The timer's worktree sweep
/// runs only while this Mac is in use (`isInUse()`), where it is how a
/// worktree created outside Supermux shows up; otherwise it waits for the
/// app to become active. The last
/// project list of each Mac is cached on disk
/// (``SupermuxRemoteProjectsCache``), so an offline Mac's projects still
/// render (dimmed). Icons come from `project.icon` with etag caching, asked
/// only when the project's listed icon token changed.
///
/// ```swift
/// let remote = SupermuxComposition.remoteProjects
/// for device in remote.devices where device.isOnline { … device.projects … }
/// remote.ensureWorktrees(on: machine, projectID: id)   // a row expanded before any refresh
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
    /// How late the safety net may fire, so the system can batch its wakeup.
    static let safetyNetTolerance: Duration = .seconds(20)
    /// How many `worktrees.list` calls one Mac's sweep keeps in flight.
    static let worktreeSweepWidth = 4

    @ObservationIgnored let facade: SupermuxDevices
    @ObservationIgnored private let cache: SupermuxRemoteProjectsCache
    @ObservationIgnored private var cachedEntries: [String: SupermuxRemoteProjectsCache.Entry] = [:]
    /// The latest offline-cache write; each save waits for it, so writes land in call order.
    @ObservationIgnored private var cacheWrite: Task<Void, Never>?
    /// The `project.icon` etag (a hash of the image bytes) of each fetched icon.
    @ObservationIgnored private var iconETags: [String: String] = [:]
    /// The `projects.list` icon token each fetched icon was last confirmed
    /// against. It is a different value from the `project.icon` etag, so it
    /// is kept apart: an unchanged token needs no `project.icon` call.
    @ObservationIgnored private var iconListTokens: [String: String] = [:]
    /// `machine|projectID` keys whose worktree list is kept fresh: every
    /// project each Mac listed at its last refresh (and any a row or socket
    /// asked for since).
    @ObservationIgnored private var wantedWorktrees: Set<String> = []
    /// Macs refreshed since their link last connected, so the link event and
    /// the device list reporting the same connection refresh it once. A
    /// refresh that cannot reach the host (`host.status` failed) clears the
    /// mark, so the next device-list change tries that connection again.
    @ObservationIgnored private var refreshedSinceConnect: Set<SurfaceMachineID> = []
    /// Macs whose next refresh pass also sweeps their worktree lists. A set
    /// rather than a pass argument, so a sweep asked for while a pass without
    /// one runs still happens in the pass queued after it.
    @ObservationIgnored private var worktreeSweepDue: Set<SurfaceMachineID> = []
    /// The last safety-net tick skipped its worktree sweep because this Mac
    /// was not in use; the app becoming active runs it.
    @ObservationIgnored private var sweepMissedWhileIdle = false
    @ObservationIgnored private let refreshes = SupermuxPerMachinePasses()
    @ObservationIgnored private let worktreeSweeps = SupermuxPerMachinePasses()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

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
                try? await Task.sleep(for: Self.safetyNetInterval, tolerance: Self.safetyNetTolerance)
                self?.safetyNetTick()
            }
        })
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catchUpMissedSweep() }
        }
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

    /// Refreshes every connected Mac (see ``refresh(_:sweepingWorktrees:)``).
    func refreshAll(sweepingWorktrees: Bool = true) {
        for device in devices where device.isOnline {
            Task { await refresh(device.machine, sweepingWorktrees: sweepingWorktrees) }
        }
    }

    /// Refetches one Mac's projects, run states and changed icons, and
    /// (unless `sweepingWorktrees` is false) starts a sweep of every listed
    /// project's worktree list (not awaited). Concurrent calls coalesce into
    /// one extra pass, which sweeps when a call since the last sweep asked to.
    func refresh(_ machine: SurfaceMachineID, sweepingWorktrees: Bool = true) async {
        if sweepingWorktrees { worktreeSweepDue.insert(machine) }
        await refreshes.run(machine) { await performRefresh(machine) }
    }

    /// The safety net: a full refresh of every connected Mac while this Mac
    /// is in use. Otherwise the project lists, run states and changed icons
    /// are still refetched (project sync and notification icons read them),
    /// and the worktree sweep waits for the app to become active.
    private func safetyNetTick() {
        let inUse = Self.isInUse()
        sweepMissedWhileIdle = !inUse
        refreshAll(sweepingWorktrees: inUse)
    }

    /// The app became active after a tick skipped its worktree sweep: one
    /// full refresh now, so an outside worktree shows up as the user returns.
    private func catchUpMissedSweep() {
        guard sweepMissedWhileIdle, Self.isInUse() else { return }
        sweepMissedWhileIdle = false
        refreshAll()
    }

    /// Whether someone may be looking at this Mac's sidebar (``SupermuxAppInUse``).
    private static func isInUse() -> Bool {
        SupermuxAppInUse.now()
    }

    /// Loads a project's worktrees if no refresh has yet (every refresh
    /// loads them all); later changes arrive through `supermux.worktrees.updated`.
    func ensureWorktrees(on machine: SurfaceMachineID, projectID: UUID) {
        let key = Self.projectKey(machine: machine, projectID: projectID)
        let isLoaded = device(machine)?.worktreesByProjectID[projectID] != nil
        guard wantedWorktrees.insert(key).inserted || !isLoaded else { return }
        Task { await refreshWorktrees(on: machine, projectID: projectID) }
    }

    /// Refetches one project's worktrees (`include_branches: false`). A list
    /// the Mac cannot give (a folder that is not a git repo, a transient git
    /// failure, a dropped link) keeps the previous one: it is not a failure of
    /// that Mac's refresh, so its `lastError` is left alone.
    func refreshWorktrees(on machine: SurfaceMachineID, projectID: UUID) async {
        let key = Self.projectKey(machine: machine, projectID: projectID)
        wantedWorktrees.insert(key)
        guard device(machine)?.isOnline == true,
              let worktrees = try? await facade.request(
                  SupermuxMobileMethod.worktreesList.rawValue,
                  params: ["project_id": projectID.uuidString, "include_branches": false],
                  on: machine,
                  resultKey: "worktrees",
                  as: [SupermuxWorktreeDTO].self
              ),
              wantedWorktrees.contains(key) // the Mac may have stopped listing it meanwhile
        else { return }
        update(machine) { $0.worktreesByProjectID[projectID] = worktrees }
    }

    /// Refetches only one Mac's `run.state` (after a mirror's Run / Stop, and
    /// on that Mac's `supermux.run.updated`).
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
            refreshOncePerConnection(machine)
        case .linkLost(let machine):
            refreshedSinceConnect.remove(machine)
            update(machine) { $0.isOnline = false }
        case .topic(let machine, .projectsUpdated, _):
            Task { await refresh(machine) }
        case .topic(let machine, .runUpdated, _):
            // A Run / Stop changes only the run state: no project list,
            // worktree sweep or icon pass on that Mac.
            Task { await refreshRuns(machine) }
        case .topic(let machine, .worktreesUpdated, _):
            Task { await refreshWantedWorktrees(on: machine) }
        case .topic:
            break
        }
    }

    /// Refetches every wanted worktree list of one Mac. Calls during a sweep
    /// coalesce into one more sweep after it, so a burst of topics or
    /// refreshes never runs several sweeps of the same Mac at once.
    private func refreshWantedWorktrees(on machine: SurfaceMachineID) async {
        await worktreeSweeps.run(machine) {
            let prefix = "\(machine.rawValue)|"
            let projectIDs = wantedWorktrees.compactMap { key in
                key.hasPrefix(prefix) ? UUID(uuidString: String(key.dropFirst(prefix.count))) : nil
            }
            await fetchWorktrees(of: projectIDs, on: machine)
        }
    }

    /// Fetches these projects' worktree lists, at most
    /// ``worktreeSweepWidth`` at once (each is a `git worktree list` there).
    private func fetchWorktrees(of projectIDs: [UUID], on machine: SurfaceMachineID) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, projectID) in projectIDs.enumerated() {
                if index >= Self.worktreeSweepWidth { _ = await group.next() }
                group.addTask { [weak self] in await self?.refreshWorktrees(on: machine, projectID: projectID) }
            }
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
    /// projects for Macs not refreshed yet, and one refresh per connection
    /// for a Mac whose link connected and ran its post-connect fetch (usually
    /// `.linkConnected` got there first; this covers a link that connected
    /// before the model started following events). A refresh started before
    /// that fetch would lose its capability request to the reset it does.
    private func reconcileDevices() {
        var next: [SupermuxDeviceProjects] = []
        for device in facade.devices {
            var entry = self.device(device.machine) ?? cachedEntry(for: device) ?? .empty(for: device)
            entry.name = device.displayName
            entry.isOnline = device.isConnected
            entry.isLoopback = device.isLoopback
            next.append(entry)
        }
        if next != devices { devices = next }
        refreshedSinceConnect.formIntersection(facade.devices.filter(\.isConnected).map(\.machine))
        for device in facade.devices where device.hasFetchedRecords {
            refreshOncePerConnection(device.machine)
        }
    }

    /// Refreshes a Mac unless it was already refreshed since its link connected.
    private func refreshOncePerConnection(_ machine: SurfaceMachineID) {
        guard refreshedSinceConnect.insert(machine).inserted else { return }
        Task { await refresh(machine) }
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
        // Taken as the pass starts: a sweep asked for during this pass's
        // requests is left to the pass queued after it, which lists newer projects.
        let sweep = worktreeSweepDue.remove(machine) != nil
        guard let device = facade.device(for: machine), device.isConnected,
              let capabilities = await facade.hostCapabilities(on: machine) else {
            // Not refreshed: the next device-list change may retry this
            // connection's refresh, and the next pass still sweeps.
            refreshedSinceConnect.remove(machine)
            if sweep { worktreeSweepDue.insert(machine) }
            return
        }
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
            let servesWorktrees = capabilities.contains(SupermuxMobileCapability.worktreesV1.rawValue)
            wantWorktrees(of: servesWorktrees ? listed : [], on: machine)
            update(machine) { entry in
                entry.projects = projects
                entry.presets = listing.presets ?? []
                entry.setRuns(runs)
                entry.isFromCache = false
                entry.lastError = nil
                entry.worktreesByProjectID = entry.worktreesByProjectID.filter { listed.contains($0.key) }
            }
            if !device.isLoopback { saveCache(machine: machine, name: device.displayName, projects: projects) }
            if sweep {
                Task { await refreshWantedWorktrees(on: machine) }
            }
            await refreshIcons(on: machine, projects: projects)
        } catch {
            if sweep { worktreeSweepDue.insert(machine) }
            update(machine) { $0.lastError = error.localizedDescription }
        }
    }

    /// Keeps exactly the listed projects' worktree lists wanted for one Mac,
    /// so each project row's pill counts that Mac's worktrees unexpanded.
    private func wantWorktrees(of listed: Set<UUID>, on machine: SurfaceMachineID) {
        let prefix = "\(machine.rawValue)|"
        wantedWorktrees = wantedWorktrees.filter { !$0.hasPrefix(prefix) }
            .union(listed.map { Self.projectKey(machine: machine, projectID: $0) })
    }

    /// Fetches the icons whose `projects.list` token changed since they were
    /// last fetched or confirmed (`not_modified`), and drops the icons of
    /// projects no longer listed. An unchanged token makes no call.
    private func refreshIcons(on machine: SurfaceMachineID, projects: [SupermuxProjectDTO]) async {
        var live: Set<String> = []
        for project in projects {
            guard let id = UUID(uuidString: project.id), project.iconETag != nil || project.hasCustomIcon == true else { continue }
            let key = Self.projectKey(machine: machine, projectID: id)
            live.insert(key)
            if let token = project.iconETag, iconListTokens[key] == token, icons[key] != nil { continue }
            var params: [String: Any] = ["project_id": project.id]
            if icons[key] != nil, let etag = iconETags[key] { params["etag"] = etag }
            guard let result = try? await facade.request(SupermuxMobileMethod.projectIcon.rawValue, params: params, on: machine) else { continue }
            if result["not_modified"] as? Bool == true {
                iconListTokens[key] = project.iconETag
            } else if let base64 = result["png_base64"] as? String,
                      let data = Data(base64Encoded: base64),
                      let image = NSImage(data: data) {
                icons[key] = image
                iconETags[key] = result["etag"] as? String
                iconListTokens[key] = project.iconETag
            }
        }
        let prefix = "\(machine.rawValue)|"
        for key in icons.keys where key.hasPrefix(prefix) && !live.contains(key) {
            icons[key] = nil
            iconETags[key] = nil
            iconListTokens[key] = nil
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

/// One pass at a time per Mac: a call while that Mac's pass runs returns at
/// once and queues one more pass after it (however many calls came in).
@MainActor
private final class SupermuxPerMachinePasses {
    private var running: Set<SurfaceMachineID> = []
    private var again: Set<SurfaceMachineID> = []

    func run(_ machine: SurfaceMachineID, _ pass: () async -> Void) async {
        guard running.insert(machine).inserted else {
            again.insert(machine)
            return
        }
        repeat {
            again.remove(machine)
            await pass()
        } while again.contains(machine)
        running.remove(machine)
    }
}

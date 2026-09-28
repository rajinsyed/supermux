import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit

/// The one shared path that turns a remote workspace into a local mirror
/// workspace in a chosen window, creates a workspace on a device, and waits
/// for a workspace a remote RPC just created. Every entry point (auto-mirror,
/// sidebar rows, New Worktree on a device, the socket) goes through here, so
/// there is one mirror per remote workspace and every mirror is bound.
///
/// Opening reuses the canonical `vm.workspace_open` sequence
/// (`remoteWorkspaceGroup` → `CloudWorkspaceLayoutTranslator.fetch` →
/// `projectGroupAsNewLocalWorkspace` → `bindCloudWorkspace`) with a
/// window-scoped host, never the preferred-window `.app` host.
///
/// ```swift
/// let opened = try await opener.openMirror(of: ref, in: tabManager, focus: true)
/// let created = try await opener.createWorkspace(on: machine, title: nil,
///     workingDirectory: "/Users/me/dev/repo", in: tabManager, focus: true)
/// ```
@MainActor
final class SupermuxDeviceWorkspaceOpener {
    /// A mirror the opener returned.
    struct Opened {
        let ref: SupermuxRemoteWorkspaceRef
        let workspace: Workspace
        /// An existing mirror was returned instead of opening a new one.
        let reused: Bool
    }

    private let catalog: SurfaceCatalog
    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private var inFlight: [SupermuxRemoteWorkspaceRef: (id: UUID, task: Task<Workspace, any Error>)] = [:]

    init(catalog: SurfaceCatalog, devices: SupermuxDevices, index: SupermuxDeviceWorkspaceIndex) {
        self.catalog = catalog
        self.devices = devices
        self.index = index
    }

    // MARK: - Open an existing remote workspace

    /// Opens `ref` as a local mirror workspace in `tabManager`'s window, or
    /// returns the mirror that already shows it (in any window). Concurrent
    /// calls for one ref share one open.
    ///
    /// - Parameters:
    ///   - focus: Select the mirror afterwards (never steals focus otherwise).
    ///   - createStarterTerminalIfEmpty: A remote workspace with no terminal
    ///     gets one first (the ⌘N contract) instead of failing with
    ///     ``SupermuxDeviceError/nothingToMirror(_:)``.
    func openMirror(
        of ref: SupermuxRemoteWorkspaceRef,
        in tabManager: TabManager,
        focus: Bool,
        createStarterTerminalIfEmpty: Bool = false
    ) async throws -> Opened {
        if let existing = index.localWorkspace(showing: ref) {
            if focus { select(existing) }
            return Opened(ref: ref, workspace: existing, reused: true)
        }
        if let flight = inFlight[ref] {
            let workspace = try await flight.task.value
            if focus { select(workspace) }
            return Opened(ref: ref, workspace: workspace, reused: true)
        }
        let id = UUID()
        let task = Task { @MainActor [self] in
            try await self.performOpen(ref, in: tabManager, createStarterTerminalIfEmpty: createStarterTerminalIfEmpty)
        }
        inFlight[ref] = (id, task)
        defer { if inFlight[ref]?.id == id { inFlight[ref] = nil } }
        let workspace = try await task.value
        if focus { select(workspace) }
        return Opened(ref: ref, workspace: workspace, reused: false)
    }

    private func performOpen(
        _ ref: SupermuxRemoteWorkspaceRef,
        in tabManager: TabManager,
        createStarterTerminalIfEmpty: Bool
    ) async throws -> Workspace {
        let machine = ref.machine
        let provider = try connectedProvider(machine)
        guard !tabManager.isFinalizedForWindowClose else { throw SupermuxDeviceError.windowUnavailable }
        // The host's own spelling of the id: catalog views match it exactly.
        let remoteID = devices.record(for: ref)?.id ?? ref.workspaceID
        let group = try await mirrorGroup(
            ref: ref, remoteID: remoteID, provider: provider,
            createStarterTerminalIfEmpty: createStarterTerminalIfEmpty
        )
        let title = CloudTreeNodeActions.localWorkspaceTitle(
            hostName: CloudTreeNodeActions.resolvedMachineName(machine, snapshot: catalog.snapshot),
            group: group
        )
        let layout = await CloudWorkspaceLayoutTranslator.fetch(machine: machine, workspaceID: remoteID, catalog: catalog)
        var host = SurfaceCatalog.NewWorkspaceHost(tabManager: tabManager)
        let create = host.create
        // Bind the moment the local workspace exists, so the host export
        // filter never publishes it as a local workspace while panes attach.
        host.create = { [weak self, weak tabManager] title, focus in
            let created = try create(title, focus)
            if let workspace = tabManager?.tabs.first(where: { $0.id == created.workspaceID }) {
                self?.index.bind(workspace, to: ref)
            }
            return created
        }
        do {
            let opened = try await catalog.projectGroupAsNewLocalWorkspace(
                group, title: title, focus: false, host: host, layout: layout
            )
            catalog.bindCloudWorkspace(
                localWorkspaceID: opened.workspaceID,
                machine: machine,
                remoteWorkspaceID: remoteID,
                generatedTitle: title
            )
            guard let workspace = tabManager.tabs.first(where: { $0.id == opened.workspaceID }) else {
                throw SupermuxDeviceError.windowUnavailable
            }
            index.bind(workspace, to: ref)
            return workspace
        } catch {
            // Drop the early binding; upstream closes the empty workspace.
            index.unbind(ref: ref)
            throw error
        }
    }

    /// The remote workspace's members as one placement-aware group.
    private func mirrorGroup(
        ref: SupermuxRemoteWorkspaceRef,
        remoteID: String,
        provider: DeviceSurfaceProvider,
        createStarterTerminalIfEmpty: Bool
    ) async throws -> SurfaceResourceGroup {
        if let group = try? catalog.remoteWorkspaceGroup(machine: ref.machine, workspaceID: remoteID),
           group.placements.contains(where: { $0.resource.kind == .terminal }) {
            return group
        }
        guard createStarterTerminalIfEmpty else { throw SupermuxDeviceError.nothingToMirror(ref.description) }
        let terminal = try await provider.createTerminal(command: nil, cwd: nil, name: nil, remoteWorkspaceID: remoteID)
        let placement = SurfaceResourcePlacement(
            resource: terminal.id,
            remoteView: terminal.remoteViews?.first { $0.workspace.id == remoteID },
            remoteWorkspaceID: remoteID
        )
        let name = devices.record(for: ref)?.title ?? ""
        return SurfaceResourceGroup(title: name, placements: [placement], remoteWorkspaceID: remoteID)
    }

    // MARK: - Create a global workspace on a device

    /// Creates a workspace on the device (optionally at `workingDirectory` on
    /// that Mac) and opens it as a bound mirror in `tabManager`'s window.
    ///
    /// The remote workspace is created first (`workspace.create` with
    /// `working_directory`), then opened through upstream's shared
    /// `createWorkspaceAndOpenLocally` with a window-scoped host, so the local
    /// row never shows the provisional "Cloud VM" title.
    func createWorkspace(
        on machine: SurfaceMachineID,
        title: String?,
        workingDirectory: String?,
        in tabManager: TabManager,
        focus: Bool
    ) async throws -> Opened {
        let provider = try connectedProvider(machine)
        var params: [String: Any] = ["focus": false]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { params["title"] = title }
        if let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            params["working_directory"] = directory
        }
        let response = try await devices.request("workspace.create", params: params, on: machine)
        guard let remoteID = (response["created_workspace_id"] as? String) ?? (response["workspace_id"] as? String) else {
            throw SupermuxDeviceError.malformedResponse("workspace.create")
        }
        await provider.link.fetchNow()
        provider.publish()
        let ref = SupermuxRemoteWorkspaceRef(machine: machine, workspaceID: remoteID)
        let record = devices.record(for: ref)
        let remoteWorkspace = record.map(DeviceWorkspaceProjection.remoteWorkspace)
            ?? SurfaceRemoteWorkspace(id: remoteID, name: title ?? "", index: devices.records(on: machine).count, focused: false)
        let starter = catalog.snapshot.resources(on: machine).first {
            $0.kind == .terminal && $0.remoteWorkspaces.contains { $0.id == remoteWorkspace.id }
        }
        let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
            machine: machine,
            provider: provider,
            catalog: catalog,
            name: title,
            focus: focus,
            existingWorkspace: remoteWorkspace,
            existingTerminal: starter,
            host: CloudWorkspaceCreationHost(manager: tabManager)
        )
        guard let opened = result.opened,
              let workspace = tabManager.tabs.first(where: { $0.id == opened.workspaceID }) else {
            throw SupermuxDeviceError.windowUnavailable
        }
        index.bind(workspace, to: ref)
        if focus { select(workspace) }
        return Opened(ref: ref, workspace: workspace, reused: false)
    }

    // MARK: - Wait for a remote workspace

    /// Waits until `ref` appears in the device's synced records (with a
    /// terminal, unless `requireTerminal` is false) — e.g. after
    /// `mobile.supermux.worktree.create` or `agent.start` returned its
    /// `workspace_id` — nudging a re-sync while it waits.
    func awaitRemoteWorkspace(
        _ ref: SupermuxRemoteWorkspaceRef,
        timeout: Duration = .seconds(30),
        requireTerminal: Bool = true
    ) async throws -> WorkspaceSyncRecord {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var nextNudge = clock.now
        while true {
            if let record = devices.record(for: ref), !requireTerminal || !record.terminals.isEmpty {
                return record
            }
            guard clock.now < deadline else { throw SupermuxDeviceError.remoteWorkspaceTimedOut(ref.description) }
            try Task.checkCancellation()
            if clock.now >= nextNudge, let provider = devices.provider(for: ref.machine), provider.link.isConnected {
                nextNudge = clock.now + .seconds(2)
                await provider.link.fetchNow()
                continue
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// ``awaitRemoteWorkspace(_:timeout:requireTerminal:)`` then
    /// ``openMirror(of:in:focus:createStarterTerminalIfEmpty:)``: the step
    /// after a remote create returned `workspace_id`.
    func openWhenAvailable(
        _ ref: SupermuxRemoteWorkspaceRef,
        in tabManager: TabManager,
        focus: Bool,
        timeout: Duration = .seconds(30)
    ) async throws -> Opened {
        _ = try await awaitRemoteWorkspace(ref, timeout: timeout)
        return try await openMirror(of: ref, in: tabManager, focus: focus, createStarterTerminalIfEmpty: true)
    }

    // MARK: - Helpers

    private func connectedProvider(_ machine: SurfaceMachineID) throws -> DeviceSurfaceProvider {
        guard let provider = devices.provider(for: machine) else {
            throw SupermuxDeviceError.unknownDevice(machine.rawValue)
        }
        guard provider.link.isConnected else {
            throw SupermuxDeviceError.notConnected(devices.device(for: machine)?.displayName ?? provider.record.displayName)
        }
        return provider
    }

    private func select(_ workspace: Workspace) {
        workspace.owningTabManager?.selectWorkspace(workspace)
    }
}

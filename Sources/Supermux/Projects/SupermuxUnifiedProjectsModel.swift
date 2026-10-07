import CMUXMobileCore
import CmuxSurfaceCatalogModel
import Foundation
import Observation
import SupermuxKit
import SupermuxMobileCore

/// The sidebar's cross-Mac project list and what it needs to know about each
/// local device mirror (DESIGN decisions 4 and 5).
///
/// ``list`` merges this Mac's projects (with their origins) and every other
/// Mac's projects (``SupermuxRemoteProjectsModel``) through
/// ``SupermuxUnifiedProjects``. ``mirrorOwners`` maps a local mirror
/// workspace to the unified project that owns its remote record's
/// `supermux_project_id` on that record's Mac — never by local path.
///
/// A pass runs when an input changes: any Mac's projects, the device
/// revision, or the panes of an unbound workspace showing a device terminal
/// (they decide whether it is a mirror, and a local pane changes no device).
///
/// Each pass has two parts. The merge reruns only when its inputs changed
/// (local projects, their origins, each Mac's projects), not on every
/// ``SupermuxDevices/revision`` bump. The mirror part looks every mirror's
/// record up once per pass, so the sidebar body reads plain values instead of
/// following the device revision or the surface catalog. Every output is
/// reassigned only when it differs, so the sidebar re-renders only on real
/// changes.
@MainActor
@Observable
final class SupermuxUnifiedProjectsModel {
    /// A nested mirror row's fields that only its remote record carries.
    struct MirrorRemoteFields: Equatable {
        let branch: String?
    }

    /// Every project on every Mac, in sidebar order.
    private(set) var list: SupermuxUnifiedProjectList = .empty
    /// Local mirror workspace id → owning unified project id.
    private(set) var mirrorOwners: [UUID: UUID] = [:]
    /// Whether some project exists only on other Macs.
    private(set) var hasRemoteOnlyProjects = false
    /// Every local mirror workspace, bound or not, across all main windows.
    private(set) var mirrorWorkspaceIDs: Set<UUID> = []
    /// Every remote workspace that has a local mirror.
    private(set) var mirroredRefs: Set<SupermuxRemoteWorkspaceRef> = []
    /// Local mirror workspace id → its remote record's branch.
    private(set) var mirrorRemoteFields: [UUID: MirrorRemoteFields] = [:]

    @ObservationIgnored private let projectsModel: SupermuxProjectsModel
    @ObservationIgnored private let gitRemotes: SupermuxProjectGitRemotes
    @ObservationIgnored private let remoteProjects: SupermuxRemoteProjectsModel
    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private let index: SupermuxDeviceWorkspaceIndex
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The merge inputs ``list`` was last built from.
    @ObservationIgnored private var mergedInput: MergeInput?

    init(
        projectsModel: SupermuxProjectsModel,
        gitRemotes: SupermuxProjectGitRemotes,
        remoteProjects: SupermuxRemoteProjectsModel,
        devices: SupermuxDevices,
        index: SupermuxDeviceWorkspaceIndex
    ) {
        self.projectsModel = projectsModel
        self.gitRemotes = gitRemotes
        self.remoteProjects = remoteProjects
        self.devices = devices
        self.index = index
    }

    /// Starts recomputing on input changes. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.recompute()
                await self.waitForInputChange()
                // Coalesce bursts (a catalog delta often lands with a bind).
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Recomputes every output now.
    func recompute() {
        recomputeList()
        recomputeMirrors()
    }

    /// The unified project owning a local mirror, computed directly (for
    /// introspection; the sidebar reads ``mirrorOwners``).
    func owner(ofMirror workspace: Workspace) -> UUID? {
        guard let ref = index.ref(forLocal: workspace), let record = devices.record(for: ref) else { return nil }
        return owner(of: record, on: ref, in: list)
    }

    // MARK: - Projects

    /// What the merge reads; equal inputs give an equal list.
    private struct MergeInput: Equatable {
        struct Device: Equatable {
            let device: SupermuxProjectDevice
            let projects: [SupermuxProjectDTO]
        }

        let projects: [SupermuxProject]
        let gitRemoteURLs: [UUID: String]
        let devices: [Device]
    }

    private func recomputeList() {
        let input = MergeInput(
            projects: projectsModel.projects,
            gitRemoteURLs: gitRemotes.urlsByProjectID,
            devices: remoteProjects.devices
                .filter { $0.supportsProjects != false }
                .map { MergeInput.Device(device: $0.device, projects: $0.projects) }
        )
        guard input != mergedInput else { return }
        mergedInput = input
        let locals = input.projects.map {
            SupermuxUnifiedProjects.LocalProject(project: $0, gitRemoteIdentity: gitRemotes.identity(for: $0.id))
        }
        let remotes = input.devices.map { SupermuxUnifiedProjects.DeviceProjects(device: $0.device, projects: $0.projects) }
        let next = SupermuxUnifiedProjects.merge(local: locals, devices: remotes)
        guard next != list else { return }
        list = next
        let remoteOnly = next.projects.contains(where: \.isRemoteOnly)
        if remoteOnly != hasRemoteOnlyProjects { hasRemoteOnlyProjects = remoteOnly }
    }

    // MARK: - Mirrors

    /// Derives every mirror output from one walk of the mirrors, reading each
    /// Mac's records once (not once per mirror).
    private func recomputeMirrors() {
        var recordsByMachine: [SurfaceMachineID: [String: WorkspaceSyncRecord]] = [:]
        var ids = Set<UUID>()
        var refs = Set<SupermuxRemoteWorkspaceRef>()
        var owners: [UUID: UUID] = [:]
        var remoteFields: [UUID: MirrorRemoteFields] = [:]
        for mirror in index.mirrors() {
            let id = mirror.workspace.id
            ids.insert(id)
            refs.insert(mirror.ref)
            let machine = mirror.ref.machine
            if recordsByMachine[machine] == nil {
                recordsByMachine[machine] = recordsByWorkspaceID(on: machine)
            }
            guard let record = recordsByMachine[machine]?[mirror.ref.workspaceID] else { continue }
            remoteFields[id] = MirrorRemoteFields(branch: record.supermuxBranch)
            if let owner = owner(of: record, on: mirror.ref, in: list) { owners[id] = owner }
        }
        if ids != mirrorWorkspaceIDs { mirrorWorkspaceIDs = ids }
        if refs != mirroredRefs { mirroredRefs = refs }
        if owners != mirrorOwners { mirrorOwners = owners }
        if remoteFields != mirrorRemoteFields { mirrorRemoteFields = remoteFields }
    }

    /// One Mac's records by canonical workspace id; the first of a duplicated
    /// id wins, as ``SupermuxDevices/record(for:)`` matches.
    private func recordsByWorkspaceID(on machine: SurfaceMachineID) -> [String: WorkspaceSyncRecord] {
        Dictionary(
            devices.records(on: machine).map { (SupermuxRemoteWorkspaceRef.canonicalWorkspaceID($0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The record's project id is that Mac's id, so it is looked up on that
    /// Mac only (a loopback id equal to a local id must not match locally).
    private func owner(
        of record: WorkspaceSyncRecord,
        on ref: SupermuxRemoteWorkspaceRef,
        in list: SupermuxUnifiedProjectList
    ) -> UUID? {
        guard let raw = record.supermuxProjectID, let remoteProjectID = UUID(uuidString: raw) else { return nil }
        return list.projectID(onMachine: ref.machineID, remoteProjectID: remoteProjectID)
    }

    private func waitForInputChange() async {
        // Found outside the tracking, which would otherwise follow every
        // catalog write. Which workspaces show a device terminal changes only
        // with a device projection or a binding, and both bump the revision.
        let unboundDeviceWorkspaces = index.unboundDeviceProjectingWorkspaces()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = projectsModel.projects
                _ = gitRemotes.urlsByProjectID
                _ = remoteProjects.devices
                _ = devices.revision
                // Their panes decide whether they are mirrors, and a local
                // pane joining or leaving changes no device.
                for workspace in unboundDeviceWorkspaces { _ = workspace.panels }
            } onChange: {
                continuation.resume()
            }
        }
    }
}

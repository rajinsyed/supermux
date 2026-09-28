import Foundation
import Observation
import SupermuxKit

/// The sidebar's cross-Mac project list and which unified project owns each
/// local device mirror (DESIGN decisions 4 and 5).
///
/// ``list`` merges this Mac's projects (with their origins) and every other
/// Mac's projects (``SupermuxRemoteProjectsModel``) through
/// ``SupermuxUnifiedProjects``. ``mirrorOwners`` maps a local mirror
/// workspace to the unified project that owns its remote record's
/// `supermux_project_id` on that record's Mac — never by local path.
/// Both are recomputed when any input changes and reassigned only when they
/// differ, so the sidebar re-renders only on real changes.
@MainActor
@Observable
final class SupermuxUnifiedProjectsModel {
    /// Every project on every Mac, in sidebar order.
    private(set) var list: SupermuxUnifiedProjectList = .empty
    /// Local mirror workspace id → owning unified project id.
    private(set) var mirrorOwners: [UUID: UUID] = [:]
    /// Whether some project exists only on other Macs.
    private(set) var hasRemoteOnlyProjects = false

    @ObservationIgnored private let projectsModel: SupermuxProjectsModel
    @ObservationIgnored private let gitRemotes: SupermuxProjectGitRemotes
    @ObservationIgnored private let remoteProjects: SupermuxRemoteProjectsModel
    @ObservationIgnored private let devices: SupermuxDevices
    @ObservationIgnored private let index: SupermuxDeviceWorkspaceIndex
    @ObservationIgnored private var task: Task<Void, Never>?

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

    /// Recomputes both outputs now.
    func recompute() {
        let locals = projectsModel.projects.map {
            SupermuxUnifiedProjects.LocalProject(project: $0, gitRemoteIdentity: gitRemotes.identity(for: $0.id))
        }
        let remotes = remoteProjects.devices
            .filter { $0.supportsProjects != false }
            .map { SupermuxUnifiedProjects.DeviceProjects(device: $0.device, projects: $0.projects) }
        let next = SupermuxUnifiedProjects.merge(local: locals, devices: remotes)
        if next != list {
            list = next
            let remoteOnly = next.projects.contains(where: \.isRemoteOnly)
            if remoteOnly != hasRemoteOnlyProjects { hasRemoteOnlyProjects = remoteOnly }
        }
        let owners = computeMirrorOwners(in: next)
        if owners != mirrorOwners { mirrorOwners = owners }
    }

    /// The unified project owning a local mirror, computed directly (for
    /// introspection; the sidebar reads ``mirrorOwners``).
    func owner(ofMirror workspace: Workspace) -> UUID? {
        guard let ref = index.ref(forLocal: workspace) else { return nil }
        return owner(of: ref, in: list)
    }

    private func computeMirrorOwners(in list: SupermuxUnifiedProjectList) -> [UUID: UUID] {
        guard !list.isEmpty else { return [:] }
        var owners: [UUID: UUID] = [:]
        for mirror in index.mirrors() {
            if let owner = owner(of: mirror.ref, in: list) { owners[mirror.workspace.id] = owner }
        }
        return owners
    }

    /// The record's project id is that Mac's id, so it is looked up on that
    /// Mac only (a loopback id equal to a local id must not match locally).
    private func owner(of ref: SupermuxRemoteWorkspaceRef, in list: SupermuxUnifiedProjectList) -> UUID? {
        guard let raw = devices.record(for: ref)?.supermuxProjectID,
              let remoteProjectID = UUID(uuidString: raw) else { return nil }
        return list.projectID(onMachine: ref.machineID, remoteProjectID: remoteProjectID)
    }

    private func waitForInputChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = projectsModel.projects
                _ = gitRemotes.urlsByProjectID
                _ = remoteProjects.devices
                _ = devices.revision
            } onChange: {
                continuation.resume()
            }
        }
    }
}

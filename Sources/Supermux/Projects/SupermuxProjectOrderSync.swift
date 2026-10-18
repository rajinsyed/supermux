import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// Shared project order on this Mac: every project row shows in the same
/// order on every Mac and the phone.
///
/// Each copy of a project (this Mac's, each other Mac's) carries an order
/// stamp (``SupermuxOrderStamp``); the newest stamp among a project's copies
/// is its place (``SupermuxUnifiedProject/order``). Two jobs:
///
/// - ``move(_:over:)`` is ``SupermuxProjectsModel/orderMover``, so every
///   project reorder (drag commit, Move Up / Move Down, DEBUG `project_move`)
///   moves the project in the shared order. ``SupermuxProjectOrderMove``
///   plans the stamps; they go to this Mac's copies and, with
///   `projects.set_order`, to each connected Mac that holds a copy.
/// - ``adoptIfNeeded(_:)`` runs after every merge of the unified list and
///   copies a project's winning stamp into this Mac's copy when the copy's
///   own stamp loses, so the order survives when the Mac that made the move
///   goes offline, and a newly synced copy takes the project's place.
///   Adoption only ever moves a copy to a strictly newer stamp, so it ends.
///
/// ```swift
/// SupermuxComposition.projectOrderSync.install()   // before the unified list starts
/// SupermuxComposition.projectsModel.moveProject(q, over: p)
/// ```
@MainActor
final class SupermuxProjectOrderSync {
    private let projectsModel: SupermuxProjectsModel
    private let unifiedProjects: SupermuxUnifiedProjectsModel
    private let devices: SupermuxDevices
    /// This Mac in stamps: `mac:<device>@<tag>`.
    private let origin: String
    private let now: () -> Date

    init(
        projectsModel: SupermuxProjectsModel,
        unifiedProjects: SupermuxUnifiedProjectsModel,
        devices: SupermuxDevices,
        origin: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.projectsModel = projectsModel
        self.unifiedProjects = unifiedProjects
        self.devices = devices
        self.origin = origin
        self.now = now
    }

    /// Makes every project move a shared-order move and adopts newer stamps
    /// after each merge. Idempotent.
    func install() {
        projectsModel.orderMover = { [weak self] dragged, target in self?.move(dragged, over: target) }
        unifiedProjects.onMerge = { [weak self] list in self?.adoptIfNeeded(list) }
    }

    // MARK: - Move

    /// Moves a project next to another in the shared order, after it when
    /// moving down and before it when moving up (the sidebar's rule).
    /// - Parameters:
    ///   - draggedID: The unified id of the project being moved.
    ///   - targetID: The unified id of the project it is dropped over.
    func move(_ draggedID: UUID, over targetID: UUID) {
        // The merge may lag the projects array by a coalescing tick.
        unifiedProjects.recompute()
        let order = unifiedProjects.list.sharedOrder
        let stamps = SupermuxProjectOrderMove(origin: origin, now: now())
            .stamps(moving: draggedID, over: targetID, in: order)
        guard !stamps.isEmpty else { return }
        write(stamps, in: order)
    }

    /// Writes the stamps to every copy this Mac can reach: its own copies
    /// at once, each connected Mac's copies with one `projects.set_order`
    /// (fire and forget; a Mac that misses it adopts the stamp from this
    /// Mac's `projects.list` when the project has a copy here).
    private func write(_ stamps: [UUID: SupermuxOrderStamp], in order: [SupermuxUnifiedProject]) {
        var local: [UUID: SupermuxOrderStamp] = [:]
        var remote: [String: [(projectID: UUID, stamp: SupermuxOrderStamp)]] = [:]
        for project in order {
            guard let stamp = stamps[project.id] else { continue }
            for location in project.locations {
                if location.isThisMac {
                    local[location.projectID] = stamp
                } else if let machine = location.machineID, location.isOnline {
                    remote[machine, default: []].append((location.projectID, stamp))
                }
            }
        }
        if !local.isEmpty { projectsModel.setOrderStamps(local) }
        for (machine, entries) in remote {
            send(entries, to: SurfaceMachineID(rawValue: machine))
        }
    }

    private func send(_ entries: [(projectID: UUID, stamp: SupermuxOrderStamp)], to machine: SurfaceMachineID) {
        let wire = SupermuxWireJSON()
        let stamps: [[String: Any]] = entries.compactMap { entry in
            guard let order = try? wire.dictionary(from: entry.stamp) else { return nil }
            return ["project_id": entry.projectID.uuidString, "order": order]
        }
        let params: [String: Any] = ["stamps": stamps]
        Task { @MainActor [devices] in
            guard await devices.supports(.orderSyncV1, on: machine) else { return }
            _ = try? await devices.request(.projectsSetOrder, params: params, on: machine)
        }
    }

    // MARK: - Adoption

    /// Copies each project's winning stamp into this Mac's copy when the
    /// copy's own stamp loses to it, in one ``SupermuxProjectsModel/setOrderStamps(_:)``.
    /// - Parameter list: The freshly merged unified list.
    func adoptIfNeeded(_ list: SupermuxUnifiedProjectList) {
        let localStamps = Dictionary(
            projectsModel.projects.map { ($0.id, $0.order) },
            uniquingKeysWith: { first, _ in first }
        )
        var adopted: [UUID: SupermuxOrderStamp] = [:]
        for project in list.projects {
            guard let effective = project.order,
                  let localID = project.localProjectID,
                  let localStamp = localStamps[localID],
                  effective.wins(over: localStamp) else { continue }
            adopted[localID] = effective
        }
        if !adopted.isEmpty { projectsModel.setOrderStamps(adopted) }
    }
}

public import Foundation

/// The merged project list plus the lookups nesting needs: which unified
/// project owns a remote workspace record's `supermux_project_id` on a given
/// device, and which one owns a local project.
///
/// Remote project ids are looked up per device, so a remote id that happens
/// to equal a local project id (the loopback device, a copied projects file)
/// never aliases the local project.
public struct SupermuxUnifiedProjectList: Hashable, Sendable {
    /// Unified projects in display order.
    public let projects: [SupermuxUnifiedProject]
    private let indexByID: [UUID: Int]
    private let unifiedIDByLocation: [String: UUID]

    /// No projects anywhere.
    public static let empty = SupermuxUnifiedProjectList(projects: [])

    /// Indexes `projects`; a duplicated id keeps its first occurrence.
    public init(projects: [SupermuxUnifiedProject]) {
        self.projects = projects
        var indexByID: [UUID: Int] = [:]
        var unifiedIDByLocation: [String: UUID] = [:]
        for (index, project) in projects.enumerated() where indexByID[project.id] == nil {
            indexByID[project.id] = index
            for location in project.locations where unifiedIDByLocation[location.id] == nil {
                unifiedIDByLocation[location.id] = project.id
            }
        }
        self.indexByID = indexByID
        self.unifiedIDByLocation = unifiedIDByLocation
    }

    /// Whether no Mac has any project.
    public var isEmpty: Bool { projects.isEmpty }

    /// The projects no copy of which is on this Mac, in display order.
    public var remoteOnly: [SupermuxUnifiedProject] { projects.filter(\.isRemoteOnly) }

    /// The unified project with this id.
    public func project(id: UUID) -> SupermuxUnifiedProject? {
        indexByID[id].map { projects[$0] }
    }

    /// The unified project owning `remoteProjectID` on the device `machineID`.
    public func projectID(onMachine machineID: String, remoteProjectID: UUID) -> UUID? {
        unifiedIDByLocation["\(machineID):\(remoteProjectID.uuidString)"]
    }

    /// The unified project owning this Mac's project `id`.
    public func projectID(forLocalProject id: UUID) -> UUID? {
        unifiedIDByLocation["local:\(id.uuidString)"]
    }

    /// The unified project owning this Mac's project `id`.
    public func project(forLocalProject id: UUID) -> SupermuxUnifiedProject? {
        projectID(forLocalProject: id).flatMap(project(id:))
    }
}

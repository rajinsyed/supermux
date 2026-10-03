import CryptoKit
public import Foundation
public import SupermuxMobileCore

/// Merges this Mac's projects with every device's projects into the unified
/// list the sidebar renders (DESIGN decision 4). Pure; no I/O.
///
/// Per device, a remote project joins a local project when:
/// 1. their normalized origins (`gitRemoteIdentity`) are equal AND that origin
///    is unique among the local projects and among that device's projects; or
/// 2. otherwise, their names and standardized root paths are identical and
///    their origins do not conflict (two different known origins never merge).
///
/// A local project takes at most one project per device. Everything left on a
/// device becomes a remote-only project. Order: local projects in their own
/// order, then remote-only projects grouped by device (input order), by name.
///
/// ```swift
/// let list = SupermuxUnifiedProjects.merge(local: locals, devices: remotes)
/// list.projectID(onMachine: ref.machineID, remoteProjectID: recordProjectID)
/// ```
public enum SupermuxUnifiedProjects {
    /// One of this Mac's projects with its normalized origin.
    public struct LocalProject: Sendable {
        public let project: SupermuxProject
        /// `SupermuxProjectGitRemotes.identity(for:)` for the project.
        public let gitRemoteIdentity: String?

        /// Creates a local input.
        public init(project: SupermuxProject, gitRemoteIdentity: String?) {
            self.project = project
            self.gitRemoteIdentity = gitRemoteIdentity
        }
    }

    /// One device's `projects.list` result.
    public struct DeviceProjects: Sendable {
        public let device: SupermuxProjectDevice
        public let projects: [SupermuxProjectDTO]

        /// Creates a device input.
        public init(device: SupermuxProjectDevice, projects: [SupermuxProjectDTO]) {
            self.device = device
            self.projects = projects
        }
    }

    /// Merges the inputs (see the type docs for the rules).
    public static func merge(local: [LocalProject], devices: [DeviceProjects]) -> SupermuxUnifiedProjectList {
        var remoteLocations = Array(repeating: [SupermuxProjectLocation](), count: local.count)
        var remoteOnly: [SupermuxUnifiedProject] = []
        let localIdentityCounts = occurrences(local.compactMap(\.gitRemoteIdentity))
        for entry in devices {
            let remotes = addressable(entry.projects)
            let matches = match(remotes, to: local, localIdentityCounts: localIdentityCounts)
            var unmatched: [SupermuxUnifiedProject] = []
            for (index, remote) in remotes.enumerated() {
                let location = SupermuxProjectLocation(
                    place: .device(entry.device),
                    projectID: remote.id,
                    rootPath: remote.dto.rootPath
                )
                if let localIndex = matches[index] {
                    remoteLocations[localIndex].append(location)
                } else {
                    unmatched.append(SupermuxUnifiedProject(
                        id: remoteOnlyID(machineID: entry.device.machineID, projectID: remote.id),
                        name: remote.dto.name,
                        colorHex: remote.dto.colorHex,
                        iconSymbol: remote.dto.iconSymbol,
                        gitRemoteIdentity: remote.dto.gitRemoteIdentity,
                        locations: [location]
                    ))
                }
            }
            remoteOnly += unmatched.sorted(by: displayOrder)
        }
        let merged = local.enumerated().map { index, entry in
            SupermuxUnifiedProject(
                id: entry.project.id,
                name: entry.project.name,
                colorHex: entry.project.colorHex,
                iconSymbol: entry.project.iconSymbol,
                gitRemoteIdentity: entry.gitRemoteIdentity,
                locations: [SupermuxProjectLocation(
                    place: .thisMac,
                    projectID: entry.project.id,
                    rootPath: entry.project.rootPath
                )] + remoteLocations[index]
            )
        }
        return SupermuxUnifiedProjectList(projects: merged + remoteOnly)
    }

    /// The stable unified id of a remote-only project: a name-based UUID of
    /// the device and its project id, so it never equals the remote Mac's own
    /// project id (which could collide with a local project's id).
    public static func remoteOnlyID(machineID: String, projectID: UUID) -> UUID {
        let seed = "supermux.remote-project\u{0}\(machineID)\u{0}\(projectID.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Whether two root paths name the same folder spelling (standardized).
    public static func sameRoot(_ lhs: String, _ rhs: String) -> Bool {
        standardized(lhs) == standardized(rhs)
    }

    // MARK: - Matching

    private struct Remote {
        let id: UUID
        let dto: SupermuxProjectDTO
    }

    /// Remote projects with a UUID id, first occurrence of each id only.
    private static func addressable(_ projects: [SupermuxProjectDTO]) -> [Remote] {
        var seen: Set<UUID> = []
        return projects.compactMap { dto in
            guard let id = UUID(uuidString: dto.id), seen.insert(id).inserted else { return nil }
            return Remote(id: id, dto: dto)
        }
    }

    /// Remote index → local index for one device.
    private static func match(
        _ remotes: [Remote],
        to local: [LocalProject],
        localIdentityCounts: [String: Int]
    ) -> [Int: Int] {
        let remoteIdentityCounts = occurrences(remotes.compactMap(\.dto.gitRemoteIdentity))
        var claimed: Set<Int> = []
        var result: [Int: Int] = [:]
        for (index, remote) in remotes.enumerated() {
            guard let identity = remote.dto.gitRemoteIdentity,
                  remoteIdentityCounts[identity] == 1,
                  localIdentityCounts[identity] == 1,
                  let localIndex = local.firstIndex(where: { $0.gitRemoteIdentity == identity }),
                  !claimed.contains(localIndex) else { continue }
            result[index] = localIndex
            claimed.insert(localIndex)
        }
        for (index, remote) in remotes.enumerated() where result[index] == nil {
            guard let localIndex = local.indices.first(where: { candidate in
                !claimed.contains(candidate)
                    && local[candidate].project.name == remote.dto.name
                    && sameRoot(local[candidate].project.rootPath, remote.dto.rootPath)
                    && !conflicting(local[candidate].gitRemoteIdentity, remote.dto.gitRemoteIdentity)
            }) else { continue }
            result[index] = localIndex
            claimed.insert(localIndex)
        }
        return result
    }

    private static func conflicting(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }

    private static func occurrences(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func displayOrder(_ lhs: SupermuxUnifiedProject, _ rhs: SupermuxUnifiedProject) -> Bool {
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

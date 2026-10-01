import Foundation

/// One project as the phone lists it: the same repository on every Mac that
/// has it, merged into one row the way the Mac sidebar merges a project with
/// its copies on other Macs (`SupermuxUnifiedProjects`).
public struct SupermuxMergedProject: Equatable, Sendable, Identifiable {
    /// One Mac's copy of the project.
    public struct Location: Equatable, Sendable {
        /// That Mac's project row (its own id, workspaces and worktrees).
        public let row: SupermuxProjectRowSnapshot
        /// The Mac it lives on.
        public let mac: SupermuxProjectsMacHeader
        /// Whether that Mac serves worktree creation.
        public let showsWorktreeCreation: Bool
    }

    /// Stable key: `origin:<identity>` for a repository with a unique origin,
    /// else the lead location's row id.
    public let id: String
    /// One location per Mac, in Mac display order. Never empty.
    public let locations: [Location]

    /// The location the row's name, look and primary actions come from.
    public var lead: Location { locations[0] }

    /// Whether the project lives on more than one Mac (rows then name theirs).
    public var spansMacs: Bool { locations.count > 1 }

    /// Whether the merged disclosure is open: any location's is.
    public var isExpanded: Bool { locations.contains { $0.row.isExpanded } }

    /// Unopened worktrees across every Mac, or `nil` before any count exists.
    public var worktreeCount: Int? {
        let counts = locations.compactMap(\.row.worktreeCount)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// The same project limited to some Macs, or `nil` when none remain.
    func keeping(_ isIncluded: (Location) -> Bool) -> SupermuxMergedProject? {
        let kept = locations.filter(isIncluded)
        guard !kept.isEmpty else { return nil }
        return SupermuxMergedProject(id: id, locations: kept)
    }
}

/// Merges every Mac's projects into one list with the Mac sidebar's rule:
/// the same normalized git origin when it is unique on both Macs, else the
/// same name and standardized root with no conflicting origin. A merged
/// project takes at most one project per Mac.
enum SupermuxPhoneProjectMerge {
    /// The facts the matching rule reads from one Mac's project.
    struct Facts {
        let name: String
        let rootPath: String
        let origin: String?
        /// Whether no other project on the same Mac shares ``origin``.
        let originIsUnique: Bool
    }

    /// Whether two projects on different Macs are the same repository.
    static func sameProject(_ lhs: Facts, _ rhs: Facts) -> Bool {
        if let origin = lhs.origin, origin == rhs.origin, lhs.originIsUnique, rhs.originIsUnique {
            return true
        }
        let conflicting = lhs.origin != nil && rhs.origin != nil && lhs.origin != rhs.origin
        return lhs.name == rhs.name
            && standardized(lhs.rootPath) == standardized(rhs.rootPath)
            && !conflicting
    }

    /// The origins that appear exactly once among one Mac's projects.
    static func uniqueOrigins(_ origins: [String?]) -> Set<String> {
        var counts: [String: Int] = [:]
        for origin in origins.compactMap({ $0 }) {
            counts[origin, default: 0] += 1
        }
        return Set(counts.filter { $0.value == 1 }.keys)
    }

    /// Every displayed Mac's projects as one list: the first Mac's projects
    /// in its order, then each further Mac's unmatched projects by name.
    /// - Parameter groups: Every Mac's slice, in display order.
    static func merge(_ groups: [SupermuxProjectsMacGroupSnapshot]) -> [SupermuxMergedProject] {
        var merged: [(locations: [SupermuxMergedProject.Location], facts: Facts)] = []
        for (groupIndex, group) in groups.enumerated() where group.isDisplayed {
            let unique = uniqueOrigins(group.rows.map(\.gitRemoteIdentity))
            var fresh: [(locations: [SupermuxMergedProject.Location], facts: Facts)] = []
            for row in group.rows {
                let location = SupermuxMergedProject.Location(
                    row: row,
                    mac: group.header,
                    showsWorktreeCreation: group.showsWorktreeCreation
                )
                let facts = Facts(
                    name: row.name,
                    rootPath: row.rootPath,
                    origin: row.gitRemoteIdentity,
                    originIsUnique: row.gitRemoteIdentity.map(unique.contains) ?? false
                )
                if let index = merged.firstIndex(where: { entry in
                    !entry.locations.contains { $0.mac.pairingID == group.header.pairingID }
                        && sameProject(entry.facts, facts)
                }) {
                    merged[index].locations.append(location)
                } else {
                    fresh.append(([location], facts))
                }
            }
            if groupIndex > 0 {
                fresh.sort { $0.facts.name.localizedStandardCompare($1.facts.name) == .orderedAscending }
            }
            merged.append(contentsOf: fresh)
        }
        var usedKeys = Set<String>()
        return merged.map { entry in
            let lead = entry.locations[0].row
            var key = lead.id
            if let origin = entry.facts.origin, entry.facts.originIsUnique,
               !usedKeys.contains("origin:\(origin)") {
                key = "origin:\(origin)"
            }
            usedKeys.insert(key)
            return SupermuxMergedProject(id: key, locations: entry.locations)
        }
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

public import SupermuxMobileCore
import SupermuxMobileKit

/// One Mac the New Worktree sheet can create on: the Mac plus ITS copy of
/// the chosen project (projects are per-Mac, matched by repository).
public struct SupermuxNewWorktreeMacOption: Equatable, Sendable, Identifiable {
    /// The Mac's pairing id (the picker's selection value).
    public var id: String { pairingID }
    /// The Mac's pairing id.
    public let pairingID: String
    /// That Mac's project for the same repository.
    public let projectID: String
    /// The Mac's user-facing name.
    public let macName: String
    /// The shell's color slot for the Mac, if assigned.
    public let colorIndex: Int?
    /// The user's color override for the Mac, if any.
    public let customColor: String?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - pairingID: The Mac's pairing id.
    ///   - projectID: That Mac's matching project id.
    ///   - macName: The Mac's user-facing name.
    ///   - colorIndex: The Mac's color slot, if assigned.
    ///   - customColor: The Mac's color override, if any.
    public init(pairingID: String, projectID: String, macName: String, colorIndex: Int? = nil, customColor: String? = nil) {
        self.pairingID = pairingID
        self.projectID = projectID
        self.macName = macName
        self.colorIndex = colorIndex
        self.customColor = customColor
    }
}

/// Which Macs can host a new worktree of a project: the project's own Mac
/// first, then every other connected, worktree-capable Mac that has the SAME
/// repository — the same normalized git origin, or, when either side has no
/// origin, the same name and root path (the Mac-side merge rule).
enum SupermuxNewWorktreeMacOptions {
    /// One connected Mac's facts, as the section knows them.
    struct Source {
        let mac: SupermuxMacInfo
        let supportsWorktrees: Bool
        let projects: [SupermuxProjectDTO]
    }

    /// The options for one project, own Mac first then in display order.
    /// - Parameters:
    ///   - projectID: The chosen project's Mac-local id.
    ///   - pairingID: The chosen project's Mac.
    ///   - sources: Every connected Mac, in display order.
    /// - Returns: Empty when the project is unknown; one entry when no other
    ///   Mac has the repository (the sheet then shows no picker).
    static func options(
        forProjectID projectID: String,
        onPairingID pairingID: String,
        sources: [Source]
    ) -> [SupermuxNewWorktreeMacOption] {
        guard let own = sources.first(where: { $0.mac.pairingID == pairingID }),
              let project = own.projects.first(where: { $0.id == projectID }) else { return [] }
        var options = [option(own.mac, projectID: projectID)]
        for source in sources
        where source.mac.pairingID != pairingID && source.mac.status == .connected && source.supportsWorktrees {
            if let match = source.projects.first(where: { isSameRepository(project, $0) }) {
                options.append(option(source.mac, projectID: match.id))
            }
        }
        return options
    }

    /// Whether two Macs' projects are the same repository.
    static func isSameRepository(_ lhs: SupermuxProjectDTO, _ rhs: SupermuxProjectDTO) -> Bool {
        if let left = lhs.gitRemoteIdentity, let right = rhs.gitRemoteIdentity {
            return left == right
        }
        return lhs.name == rhs.name && lhs.rootPath == rhs.rootPath
    }

    private static func option(_ mac: SupermuxMacInfo, projectID: String) -> SupermuxNewWorktreeMacOption {
        SupermuxNewWorktreeMacOption(
            pairingID: mac.pairingID,
            projectID: projectID,
            macName: mac.displayName,
            colorIndex: mac.colorIndex,
            customColor: mac.customColor
        )
    }
}

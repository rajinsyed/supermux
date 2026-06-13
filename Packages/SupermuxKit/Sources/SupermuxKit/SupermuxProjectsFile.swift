import Foundation

/// The on-disk JSON document persisted by ``SupermuxProjectStore``.
///
/// Lives outside cmux's session snapshot on purpose: projects are sticky and
/// must survive session resets, crashes, and "close all workspaces".
public struct SupermuxProjectsFile: Codable, Sendable, Equatable {
    /// Schema version for forward migrations.
    public var version: Int
    /// All registered projects in sidebar order.
    public var projects: [SupermuxProject]
    /// Whether the sidebar Projects section is collapsed.
    public var isSectionCollapsed: Bool

    /// The current schema version written by this build.
    public static let currentVersion = 1

    /// An empty document.
    public static let empty = SupermuxProjectsFile(version: currentVersion, projects: [], isSectionCollapsed: false)

    /// Creates a document.
    /// - Parameters:
    ///   - version: Schema version; pass ``currentVersion`` for new documents.
    ///   - projects: Registered projects in sidebar order.
    ///   - isSectionCollapsed: Sidebar section collapse state.
    public init(version: Int, projects: [SupermuxProject], isSectionCollapsed: Bool = false) {
        self.version = version
        self.projects = projects
        self.isSectionCollapsed = isSectionCollapsed
    }

    private enum CodingKeys: String, CodingKey {
        case version, projects, isSectionCollapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        projects = try container.decodeIfPresent([SupermuxProject].self, forKey: .projects) ?? []
        isSectionCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isSectionCollapsed) ?? false
    }
}

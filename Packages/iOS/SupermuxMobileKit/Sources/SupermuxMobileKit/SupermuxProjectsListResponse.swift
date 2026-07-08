public import SupermuxMobileCore

/// Typed decoder for the `mobile.supermux.projects.list` RPC result:
/// `{projects: [SupermuxProjectDTO], section_collapsed}`.
///
/// Both fields decode leniently (missing `projects` becomes `[]`) so old or
/// partial hosts never break the phone.
public struct SupermuxProjectsListResponse: Codable, Sendable, Equatable {
    /// The registered projects, in the Mac sidebar's order.
    public var projects: [SupermuxProjectDTO]
    /// Whether the Mac sidebar's Projects section is collapsed, if reported.
    public var sectionCollapsed: Bool?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - projects: The registered projects.
    ///   - sectionCollapsed: The Mac sidebar section's collapse state.
    public init(projects: [SupermuxProjectDTO], sectionCollapsed: Bool? = nil) {
        self.projects = projects
        self.sectionCollapsed = sectionCollapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try container.decodeIfPresent([SupermuxProjectDTO].self, forKey: .projects)) ?? []
        sectionCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sectionCollapsed)
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case sectionCollapsed = "section_collapsed"
    }
}

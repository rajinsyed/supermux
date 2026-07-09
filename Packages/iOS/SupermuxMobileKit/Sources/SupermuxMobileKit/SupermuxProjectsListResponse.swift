public import SupermuxMobileCore

/// Typed decoder for the `mobile.supermux.projects.list` RPC result:
/// `{projects: [SupermuxProjectDTO], presets: [SupermuxTerminalPresetDTO],
/// section_collapsed}`.
///
/// All fields decode leniently (missing `projects` becomes `[]`) so old or
/// partial hosts never break the phone. `presets` stays optional on purpose:
/// a missing field means the host predates the m2-f5 read shape (its bar
/// cannot be enumerated), which is different from an empty bar — the phone
/// hides the presets UI in the former case.
public struct SupermuxProjectsListResponse: Codable, Sendable, Equatable {
    /// The registered projects, in the Mac sidebar's order.
    public var projects: [SupermuxProjectDTO]
    /// The global terminal presets, in the Mac bar's order (the desktop shows
    /// the same set above every workspace's terminal), or `nil` when the host
    /// omits the field (pre-m2-f5 hosts).
    public var presets: [SupermuxTerminalPresetDTO]?
    /// Whether the Mac sidebar's Projects section is collapsed, if reported.
    public var sectionCollapsed: Bool?

    /// Creates a response value (used by tests and fakes).
    /// - Parameters:
    ///   - projects: The registered projects.
    ///   - presets: The global terminal presets, in bar order; `nil` models a
    ///     host that omits the field.
    ///   - sectionCollapsed: The Mac sidebar section's collapse state.
    public init(
        projects: [SupermuxProjectDTO],
        presets: [SupermuxTerminalPresetDTO]? = nil,
        sectionCollapsed: Bool? = nil
    ) {
        self.projects = projects
        self.presets = presets
        self.sectionCollapsed = sectionCollapsed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try container.decodeIfPresent([SupermuxProjectDTO].self, forKey: .projects)) ?? []
        presets = try container.decodeIfPresent([SupermuxTerminalPresetDTO].self, forKey: .presets)
        sectionCollapsed = try container.decodeIfPresent(Bool.self, forKey: .sectionCollapsed)
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case presets
        case sectionCollapsed = "section_collapsed"
    }
}

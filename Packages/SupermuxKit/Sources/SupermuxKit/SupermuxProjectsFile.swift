public import Foundation

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
    /// Global terminal-presets-bar entries in bar order.
    ///
    /// Optional on purpose: `nil` means the document predates presets (or is
    /// brand new), so the model seeds ``SupermuxTerminalPreset/defaults``; an
    /// empty array means the user deliberately cleared them and is honored as-is.
    /// Encoded with `encodeIfPresent`, so a `nil` value omits the key entirely.
    public var presets: [SupermuxTerminalPreset]?
    /// Durable "this directory was opened from this project" links, keyed by
    /// normalized directory path (see ``SupermuxDirectoryAssociationPersisting``).
    ///
    /// Lets a project's main workspace — which sits at the project root, not in
    /// a worktrees dir — nest under its project again after a restart, when the
    /// session-scoped, workspace-UUID-keyed links are gone. Optional and encoded
    /// with `encodeIfPresent` so a document with no links omits the key.
    public var directoryAssociations: [String: UUID]?

    /// The current schema version written by this build.
    public static let currentVersion = 3

    /// An empty document.
    public static let empty = SupermuxProjectsFile(version: currentVersion, projects: [], isSectionCollapsed: false)

    /// Creates a document.
    /// - Parameters:
    ///   - version: Schema version; pass ``currentVersion`` for new documents.
    ///   - projects: Registered projects in sidebar order.
    ///   - isSectionCollapsed: Sidebar section collapse state.
    ///   - presets: Global presets-bar entries, or `nil` if uninitialized.
    ///   - directoryAssociations: Durable directory→project links, or `nil`.
    public init(
        version: Int,
        projects: [SupermuxProject],
        isSectionCollapsed: Bool = false,
        presets: [SupermuxTerminalPreset]? = nil,
        directoryAssociations: [String: UUID]? = nil
    ) {
        self.version = version
        self.projects = projects
        self.isSectionCollapsed = isSectionCollapsed
        self.presets = presets
        self.directoryAssociations = directoryAssociations
    }

    private enum CodingKeys: String, CodingKey {
        case version, projects, isSectionCollapsed, presets, directoryAssociations
    }

    /// Decodes the document, defaulting `version`, `projects`, and
    /// `isSectionCollapsed` so a partial or older file still loads. `presets`
    /// stays `nil` when absent so the model can tell "never set" from "cleared";
    /// `directoryAssociations` stays `nil` when absent (legacy documents).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        projects = try container.decodeIfPresent([SupermuxProject].self, forKey: .projects) ?? []
        isSectionCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isSectionCollapsed) ?? false
        presets = try container.decodeIfPresent([SupermuxTerminalPreset].self, forKey: .presets)
        directoryAssociations = try container.decodeIfPresent([String: UUID].self, forKey: .directoryAssociations)
    }

    /// Encodes the document, omitting `presets` entirely when `nil` so an
    /// uninitialized document never writes an empty list that would suppress
    /// default seeding on the next load, and omitting `directoryAssociations`
    /// when `nil` so a document with no links stays clean.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(projects, forKey: .projects)
        try container.encode(isSectionCollapsed, forKey: .isSectionCollapsed)
        try container.encodeIfPresent(presets, forKey: .presets)
        try container.encodeIfPresent(directoryAssociations, forKey: .directoryAssociations)
    }
}

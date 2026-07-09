public import Foundation
public import SupermuxMobileCore
public import SupermuxMobileKit

/// Immutable value snapshot of the whole Projects section, computed by
/// ``SupermuxProjectsSectionModel`` and passed across the shell's `List`
/// boundary. The section view renders exclusively from this value.
public struct SupermuxProjectsSectionSnapshot: Equatable, Sendable {
    /// Whether the section renders at all. `false` unless a live session
    /// exists AND the host advertises `supermux.projects.v1` (UI-02).
    public let isVisible: Bool
    /// Whether the rows are folded away (header stays visible).
    public let isCollapsed: Bool
    /// Whether at least one fetch succeeded (drives loading vs empty vs rows).
    public let hasLoaded: Bool
    /// The project rows, in the Mac sidebar's order.
    public let rows: [SupermuxProjectRowSnapshot]

    /// The snapshot of a hidden section (no session, or capability absent).
    public static let hidden = SupermuxProjectsSectionSnapshot(
        isVisible: false,
        isCollapsed: false,
        hasLoaded: false,
        rows: []
    )

    /// Memberwise initializer.
    /// - Parameters:
    ///   - isVisible: Whether the section renders at all.
    ///   - isCollapsed: Whether the rows are folded away.
    ///   - hasLoaded: Whether at least one fetch succeeded.
    ///   - rows: The project rows, in the Mac sidebar's order.
    public init(
        isVisible: Bool,
        isCollapsed: Bool,
        hasLoaded: Bool,
        rows: [SupermuxProjectRowSnapshot]
    ) {
        self.isVisible = isVisible
        self.isCollapsed = isCollapsed
        self.hasLoaded = hasLoaded
        self.rows = rows
    }
}

/// Closure action bundle for the Projects section — the only way row-level
/// views reach back to the model (no store reference crosses the `List`
/// boundary).
public struct SupermuxProjectsSectionActions {
    /// Toggles the section's local collapse state.
    public let toggleCollapsed: @MainActor () -> Void
    /// Fetches a project's custom icon PNG through the model's etag cache;
    /// `nil` when the project is unknown or has no custom icon.
    public let iconPNGData: @Sendable (_ projectID: String) async -> Data?
    /// Opens a nested workspace by its UI row id — the same navigation the
    /// flat list's workspace rows use.
    public let selectWorkspace: @MainActor (_ workspaceID: String) -> Void
    /// Builds a worktrees store for one project against the LIVE session's
    /// client, or `nil` while disconnected or when the host lacks
    /// `supermux.worktrees.v1` (the detail screen's Worktrees section hides).
    public let makeWorktreesStore: @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore?
    /// The project/preset editor seam, or `nil` when editing is unavailable
    /// (the "+"/Edit affordances hide).
    public let editing: SupermuxProjectEditingActions?

    /// Memberwise initializer.
    /// - Parameters:
    ///   - toggleCollapsed: Toggles the section's local collapse state.
    ///   - iconPNGData: Fetches a project's custom icon PNG by project id.
    ///   - selectWorkspace: Opens a nested workspace by its UI row id.
    ///   - makeWorktreesStore: Builds a worktrees store for one project.
    ///   - editing: The editor seam, or `nil` to hide editing affordances.
    public init(
        toggleCollapsed: @escaping @MainActor () -> Void,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?,
        selectWorkspace: @escaping @MainActor (_ workspaceID: String) -> Void = { _ in },
        makeWorktreesStore: @escaping @MainActor (_ projectID: String) -> SupermuxMobileWorktreesStore? = { _ in nil },
        editing: SupermuxProjectEditingActions? = nil
    ) {
        self.toggleCollapsed = toggleCollapsed
        self.iconPNGData = iconPNGData
        self.selectWorkspace = selectWorkspace
        self.makeWorktreesStore = makeWorktreesStore
        self.editing = editing
    }
}

/// The editor sheets' seam onto the live session: project CRUD, preset CRUD,
/// and the fresh-DTO lookup that seeds the edit form. Every call routes
/// through the session's ``SupermuxMobileProjectsStore`` (send → await →
/// refetch); with no live session the closures throw
/// `SupermuxMacUnavailableError`, which the sheets surface as a localized
/// error — never a silent failure (UI-03).
public struct SupermuxProjectEditingActions {
    /// `project.create` with the folder's absolute Mac path; returns the
    /// created (or pre-existing) record.
    public let createProject: @MainActor (_ rootPath: String) async throws -> SupermuxProjectDTO
    /// `project.update` with a present-key patch; returns the updated record.
    public let updateProject: @MainActor (
        _ projectID: String,
        _ patch: SupermuxProjectPatch
    ) async throws -> SupermuxProjectDTO
    /// `project.delete` (the confirm dialog lives on the caller).
    public let deleteProject: @MainActor (_ projectID: String) async throws -> Void
    /// The freshest fetched DTO for one project, for seeding the edit form;
    /// `nil` when the project is unknown to the session.
    public let editorProject: @MainActor (_ projectID: String) -> SupermuxProjectDTO?
    /// `preset.create` from a launchable draft; returns the created record.
    public let createPreset: @MainActor (
        _ request: SupermuxPresetCreateRequest
    ) async throws -> SupermuxTerminalPresetDTO
    /// `preset.update` with a present-key patch; returns the updated record.
    public let updatePreset: @MainActor (
        _ presetID: String,
        _ patch: SupermuxPresetPatch
    ) async throws -> SupermuxTerminalPresetDTO
    /// `preset.delete` (the confirm dialog lives on the caller).
    public let deletePreset: @MainActor (_ presetID: String) async throws -> Void

    /// Memberwise initializer.
    /// - Parameters:
    ///   - createProject: `project.create` by absolute Mac folder path.
    ///   - updateProject: `project.update` with a present-key patch.
    ///   - deleteProject: `project.delete` by project id.
    ///   - editorProject: Fresh DTO lookup for seeding the edit form.
    ///   - createPreset: `preset.create` from a typed request.
    ///   - updatePreset: `preset.update` with a present-key patch.
    ///   - deletePreset: `preset.delete` by preset id.
    public init(
        createProject: @escaping @MainActor (_ rootPath: String) async throws -> SupermuxProjectDTO,
        updateProject: @escaping @MainActor (
            _ projectID: String,
            _ patch: SupermuxProjectPatch
        ) async throws -> SupermuxProjectDTO,
        deleteProject: @escaping @MainActor (_ projectID: String) async throws -> Void,
        editorProject: @escaping @MainActor (_ projectID: String) -> SupermuxProjectDTO?,
        createPreset: @escaping @MainActor (
            _ request: SupermuxPresetCreateRequest
        ) async throws -> SupermuxTerminalPresetDTO,
        updatePreset: @escaping @MainActor (
            _ presetID: String,
            _ patch: SupermuxPresetPatch
        ) async throws -> SupermuxTerminalPresetDTO,
        deletePreset: @escaping @MainActor (_ presetID: String) async throws -> Void
    ) {
        self.createProject = createProject
        self.updateProject = updateProject
        self.deleteProject = deleteProject
        self.editorProject = editorProject
        self.createPreset = createPreset
        self.updatePreset = updatePreset
        self.deletePreset = deletePreset
    }
}

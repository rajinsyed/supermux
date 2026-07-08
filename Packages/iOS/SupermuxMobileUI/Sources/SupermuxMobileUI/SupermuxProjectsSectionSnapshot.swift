public import Foundation

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

    /// Memberwise initializer.
    /// - Parameters:
    ///   - toggleCollapsed: Toggles the section's local collapse state.
    ///   - iconPNGData: Fetches a project's custom icon PNG by project id.
    public init(
        toggleCollapsed: @escaping @MainActor () -> Void,
        iconPNGData: @escaping @Sendable (_ projectID: String) async -> Data?
    ) {
        self.toggleCollapsed = toggleCollapsed
        self.iconPNGData = iconPNGData
    }
}

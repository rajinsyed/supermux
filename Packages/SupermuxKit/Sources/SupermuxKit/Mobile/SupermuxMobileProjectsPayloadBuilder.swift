public import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.projects.list` result payload
/// (`{projects: [SupermuxProjectDTO], section_collapsed}`).
///
/// Lives in SupermuxKit (not the app target) so the wire shape is
/// package-unit-testable against a seeded ``SupermuxProjectsModel``; the app
/// handler stays a thin pass-through reading `SupermuxComposition`.
///
/// ```swift
/// let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
///     projects: model.projects,
///     isSectionCollapsed: model.isSectionCollapsed
/// )
/// ```
public struct SupermuxMobileProjectsPayloadBuilder: Sendable {
    private let iconResolver: SupermuxProjectIconResolver

    /// Creates a builder.
    /// - Parameter iconResolver: Resolves whether each project has a fetchable
    ///   icon image (custom file or auto-detected repository logo), which
    ///   drives the DTO's `has_custom_icon` flag.
    public init(iconResolver: SupermuxProjectIconResolver = SupermuxProjectIconResolver()) {
        self.iconResolver = iconResolver
    }

    /// Encodes the projects-list result payload.
    ///
    /// - Parameters:
    ///   - projects: Registered projects in sidebar order.
    ///   - isSectionCollapsed: Whether the Mac sidebar's Projects section is
    ///     collapsed.
    /// - Returns: The RPC result object (`projects` + `section_collapsed`).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func projectsList(
        projects: [SupermuxProject],
        isSectionCollapsed: Bool
    ) throws -> [String: Any] {
        let encoded = try projects.map(encodedProject(_:))
        return [
            "projects": encoded,
            "section_collapsed": isSectionCollapsed,
        ]
    }

    /// Encodes the single-project result payload the `project.create` and
    /// `project.update` write handlers return (`{project: SupermuxProjectDTO}`).
    /// - Parameter project: The created/updated record.
    /// - Returns: The RPC result object.
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func projectPayload(project: SupermuxProject) throws -> [String: Any] {
        ["project": try encodedProject(project)]
    }

    /// One project's wire dictionary, with the fetchable-icon flag and the
    /// config-managed read-only marker resolved (both are file probes — run
    /// this off the main actor).
    private func encodedProject(_ project: SupermuxProject) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxProjectDTO(
            project: project,
            hasCustomIcon: iconResolver.resolveAvatar(
                rootPath: project.rootPath,
                customIconPath: project.customIconPath
            ) != nil,
            configPath: SupermuxMobileProjectConfigMarker.managedRelativePath(
                projectRoot: project.rootPath
            )
        ))
    }
}

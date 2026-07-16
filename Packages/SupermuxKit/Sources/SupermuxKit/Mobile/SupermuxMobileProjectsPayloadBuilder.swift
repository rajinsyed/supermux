public import Foundation
internal import SupermuxMobileCore

/// Builds the `mobile.supermux.projects.list` result payload
/// (`{projects: [SupermuxProjectDTO], presets: [SupermuxTerminalPresetDTO],
/// section_collapsed}`).
///
/// Lives in SupermuxKit (not the app target) so the wire shape is
/// package-unit-testable against a seeded ``SupermuxProjectsModel``; the app
/// handler stays a thin pass-through reading `SupermuxComposition`.
///
/// ```swift
/// let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
///     projects: model.projects,
///     presets: model.presets,
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
    ///   - presets: Global terminal presets in bar order (the desktop shows
    ///     the same set above every workspace's terminal; the phone gets the
    ///     whole list — additive `presets` key, ignored by old phones).
    ///   - isSectionCollapsed: Whether the Mac sidebar's Projects section is
    ///     collapsed.
    /// - Returns: The RPC result object (`projects` + `presets` +
    ///   `section_collapsed`).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func projectsList(
        projects: [SupermuxProject],
        presets: [SupermuxTerminalPreset],
        isSectionCollapsed: Bool
    ) throws -> [String: Any] {
        let encoded = try projects.map(encodedProject(_:))
        let wire = SupermuxWireJSON()
        let encodedPresets = try presets.map { preset in
            try wire.dictionary(from: SupermuxTerminalPresetDTO(preset: preset))
        }
        return [
            "projects": encoded,
            "presets": encodedPresets,
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

    /// One project's wire dictionary, with the fetchable-icon flag, the icon
    /// change token, and the config-managed read-only marker resolved (all are
    /// file probes — run this off the main actor).
    private func encodedProject(_ project: SupermuxProject) throws -> [String: Any] {
        let iconURL = iconResolver.resolveAvatar(
            rootPath: project.rootPath,
            customIconPath: project.customIconPath
        )
        return try SupermuxWireJSON().dictionary(from: SupermuxProjectDTO(
            project: project,
            hasCustomIcon: iconURL != nil,
            iconETag: iconURL.flatMap(Self.iconChangeToken),
            configPath: SupermuxMobileProjectConfigMarker.managedRelativePath(
                projectRoot: project.rootPath
            )
        ))
    }

    /// A cheap change token for an icon: the resolved path plus its size and
    /// modification time. Changes whenever the image is edited, replaced, or
    /// switched to a different file (the path covers a switch to a same-size,
    /// same-mtime file), WITHOUT reading or hashing the bytes — the projects
    /// list encodes every project. It is only a re-fetch TRIGGER for the phone;
    /// the actual content etag round-trips through `project.icon`, so a fetch
    /// after any token move fetches the correct bytes. `nil` when the file
    /// cannot be stat-ed.
    private static func iconChangeToken(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)-\(size)-\(modified)"
    }
}

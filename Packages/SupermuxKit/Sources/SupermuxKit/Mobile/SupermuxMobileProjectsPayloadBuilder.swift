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

    /// One project's file facts: whether it has a fetchable icon, the icon's
    /// change token and the config-managed marker. Probing them is file I/O in
    /// the project's folder, which can block for as long as nobody answers a
    /// macOS privacy prompt for it; the host probes through
    /// ``SupermuxProjectFileFacts``, which bounds that.
    public struct FileFacts: Equatable, Sendable {
        public var hasCustomIcon: Bool
        public var iconETag: String?
        public var configPath: String?

        public init(hasCustomIcon: Bool, iconETag: String?, configPath: String?) {
            self.hasCustomIcon = hasCustomIcon
            self.iconETag = iconETag
            self.configPath = configPath
        }

        /// A project whose files were never probed in time: no icon, not
        /// config-managed.
        public static let unknown = FileFacts(hasCustomIcon: false, iconETag: nil, configPath: nil)
    }

    /// The key a project's file facts are probed and cached under.
    public static func fileFactsKey(for project: SupermuxProject) -> String {
        project.rootPath + "\n" + (project.customIconPath ?? "")
    }

    /// Probes one project's file facts. Blocking file I/O: run it off the main
    /// actor and off the cooperative pool (``SupermuxProjectFileFacts``).
    public func fileFacts(for project: SupermuxProject) -> FileFacts {
        let iconURL = iconResolver.resolveAvatar(
            rootPath: project.rootPath,
            customIconPath: project.customIconPath
        )
        return FileFacts(
            hasCustomIcon: iconURL != nil,
            iconETag: iconURL.flatMap(Self.iconChangeToken),
            configPath: SupermuxMobileProjectConfigMarker.managedRelativePath(projectRoot: project.rootPath)
        )
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
    ///   - gitRemoteURLs: Each project's `origin` URL keyed by its
    ///     `rootPath` (additive `git_remote_url`; a project without an entry
    ///     omits the key, the legacy shape).
    ///   - fileFacts: Each project's file facts keyed by
    ///     ``fileFactsKey(for:)``, already probed (a project without an entry
    ///     shows ``FileFacts/unknown``); `nil` probes each project here.
    /// - Returns: The RPC result object (`projects` + `presets` +
    ///   `section_collapsed`).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func projectsList(
        projects: [SupermuxProject],
        presets: [SupermuxTerminalPreset],
        isSectionCollapsed: Bool,
        gitRemoteURLs: [String: String] = [:],
        fileFacts: [String: FileFacts]? = nil
    ) throws -> [String: Any] {
        let encoded = try projects.map { project in
            try encodedProject(
                project,
                gitRemoteURL: gitRemoteURLs[project.rootPath],
                facts: fileFacts.map { $0[Self.fileFactsKey(for: project)] ?? .unknown } ?? self.fileFacts(for: project)
            )
        }
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
    /// - Parameters:
    ///   - project: The created/updated record.
    ///   - gitRemoteURL: The project's `origin` URL, if resolved.
    ///   - fileFacts: The project's file facts, already probed; `nil` probes here.
    /// - Returns: The RPC result object.
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func projectPayload(
        project: SupermuxProject,
        gitRemoteURL: String? = nil,
        fileFacts: FileFacts? = nil
    ) throws -> [String: Any] {
        ["project": try encodedProject(project, gitRemoteURL: gitRemoteURL, facts: fileFacts ?? self.fileFacts(for: project))]
    }

    /// One project's wire dictionary with its file facts.
    private func encodedProject(_ project: SupermuxProject, gitRemoteURL: String?, facts: FileFacts) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxProjectDTO(
            project: project,
            hasCustomIcon: facts.hasCustomIcon,
            iconETag: facts.iconETag,
            configPath: facts.configPath,
            gitRemoteURL: gitRemoteURL
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

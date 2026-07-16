public import Foundation
public import SupermuxMobileCore

extension SupermuxProjectDTO {
    /// Maps a Mac-side project record onto its wire DTO.
    ///
    /// The custom-icon *path* deliberately never travels (data policy): the
    /// phone only learns whether an icon is fetchable and pulls the bytes via
    /// `mobile.supermux.project.icon`.
    ///
    /// - Parameters:
    ///   - project: The Mac-side project record.
    ///   - hasCustomIcon: Whether an icon image is fetchable for the project
    ///     (the caller resolves it, e.g. via
    ///     ``SupermuxProjectIconResolver/resolveAvatar(rootPath:customIconPath:)``,
    ///     so this mapping stays pure).
    ///   - configPath: Relative path of the repo-shipped `config.json`
    ///     managing the run/setup/teardown/actions fields (the read-only
    ///     marker; the caller resolves it via
    ///     ``SupermuxMobileProjectConfigMarker/managedRelativePath(projectRoot:)``),
    ///     or `nil` when those fields are user-owned.
    public init(
        project: SupermuxProject,
        hasCustomIcon: Bool,
        iconETag: String? = nil,
        configPath: String? = nil
    ) {
        self.init(
            id: project.id.uuidString,
            name: project.name,
            rootPath: project.rootPath,
            colorHex: project.colorHex,
            iconSymbol: project.iconSymbol,
            hasCustomIcon: hasCustomIcon,
            iconETag: iconETag,
            defaultBranch: project.defaultBranch,
            worktreesDirName: project.worktreesDirName,
            runCommands: project.runCommands,
            setupCommands: project.setupCommands,
            teardownCommands: project.teardownCommands,
            actions: project.actions.map(SupermuxProjectActionDTO.init(action:)),
            createdAt: project.createdAt.timeIntervalSince1970,
            lastOpenedAt: project.lastOpenedAt?.timeIntervalSince1970,
            configPath: configPath
        )
    }
}

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
    public init(project: SupermuxProject, hasCustomIcon: Bool) {
        self.init(
            id: project.id.uuidString,
            name: project.name,
            rootPath: project.rootPath,
            colorHex: project.colorHex,
            iconSymbol: project.iconSymbol,
            hasCustomIcon: hasCustomIcon,
            defaultBranch: project.defaultBranch,
            worktreesDirName: project.worktreesDirName,
            runCommands: project.runCommands,
            setupCommands: project.setupCommands,
            teardownCommands: project.teardownCommands,
            actions: project.actions.map(SupermuxProjectActionDTO.init(action:)),
            createdAt: project.createdAt.timeIntervalSince1970,
            lastOpenedAt: project.lastOpenedAt?.timeIntervalSince1970
        )
    }
}

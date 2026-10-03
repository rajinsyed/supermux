public import Foundation

extension SupermuxPaths {
    /// The offline cache of other Macs' project lists
    /// (``SupermuxRemoteProjectsCache``): `supermux-remote-projects.json` next
    /// to the projects document, so a DEBUG run with `SUPERMUX_PROJECTS_FILE`
    /// keeps its cache in the same scratch folder instead of the user's
    /// Application Support.
    public static var remoteProjectsCacheFileURL: URL {
        defaultProjectsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("supermux-remote-projects.json")
    }

    /// Project roots a user removed, which project sync never registers again
    /// (``SupermuxProjectSyncSuppression``):
    /// `supermux-project-sync-suppressed.json` next to the projects document,
    /// so every build that shares that document shares the removals too.
    public static var projectSyncSuppressionFileURL: URL {
        defaultProjectsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("supermux-project-sync-suppressed.json")
    }
}

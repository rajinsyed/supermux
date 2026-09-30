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
}

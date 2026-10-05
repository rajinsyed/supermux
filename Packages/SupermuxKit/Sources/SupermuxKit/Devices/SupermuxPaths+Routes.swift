public import Foundation

extension SupermuxPaths {
    /// The cache of other devices' direct addresses
    /// (`SupermuxRouteCandidateStore`): `supermux-route-candidates.json` next
    /// to the projects document, so a DEBUG run with `SUPERMUX_PROJECTS_FILE`
    /// keeps it in the same scratch folder. Local only; never synced.
    public static var routeCandidatesFileURL: URL {
        defaultProjectsFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("supermux-route-candidates.json")
    }
}

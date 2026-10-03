public import Foundation
public import SupermuxMobileCore

/// The rules of cross-Mac project sync (setting `supermux.devices.syncProjects`):
/// a Mac registers another Mac's project only when its OWN folder at the same
/// root path is a git repo with the same origin. Sync never clones, never
/// deletes, and never re-adds a root the destination's user removed. Pure.
///
/// ```swift
/// for candidate in SupermuxProjectSyncPlanner.candidates(source: theirs, destination: mine) {
///     let probe = try await probe(candidate.rootPath)       // on the destination
///     guard SupermuxProjectSyncPlanner.shouldRegister(candidate, probe: probe) else { continue }
///     // project.create {root_path}, then project.update {patch: settingsPatch(...)}
/// }
/// ```
public enum SupermuxProjectSyncPlanner {
    /// The source projects the destination lacks: they carry an origin, and
    /// no destination project has that origin or that root path.
    public static func candidates(
        source: [SupermuxProjectDTO],
        destination: [SupermuxProjectDTO]
    ) -> [SupermuxProjectDTO] {
        let destinationIdentities = Set(destination.compactMap(\.gitRemoteIdentity))
        let destinationRoots = Set(destination.map { standardized($0.rootPath) })
        var seenRoots: Set<String> = []
        return source.filter { project in
            guard let identity = project.gitRemoteIdentity,
                  !destinationIdentities.contains(identity) else { return false }
            let root = standardized(project.rootPath)
            guard !destinationRoots.contains(root) else { return false }
            return seenRoots.insert(root).inserted
        }
    }

    /// Whether the destination's folder (``SupermuxProjectProbeDTO``) is the
    /// same repository as `candidate` and may be registered.
    public static func shouldRegister(_ candidate: SupermuxProjectDTO, probe: SupermuxProjectProbeDTO) -> Bool {
        guard let identity = candidate.gitRemoteIdentity,
              probe.exists, probe.isDirectory, probe.isGitRepo,
              probe.isSuppressed != true else { return false }
        return probe.gitRemoteIdentity == identity
    }

    /// The `project.update` patch that copies the source's settings onto a
    /// freshly registered copy: name, color, icon symbol, default branch, and
    /// (unless the destination repo ships a config that owns them) run, setup,
    /// teardown and actions. Unset optionals are omitted, never nulled.
    public static func settingsPatch(
        from source: SupermuxProjectDTO,
        destinationIsConfigManaged: Bool
    ) -> [String: Any] {
        var patch: [String: Any] = ["name": source.name]
        if let color = source.colorHex { patch["color_hex"] = color }
        if let symbol = source.iconSymbol { patch["icon_symbol"] = symbol }
        if let branch = source.defaultBranch { patch["default_branch"] = branch }
        guard !destinationIsConfigManaged else { return patch }
        if let run = source.runCommands { patch["run_commands"] = run }
        if let setup = source.setupCommands { patch["setup_commands"] = setup }
        if let teardown = source.teardownCommands { patch["teardown_commands"] = teardown }
        if let actions = source.actions {
            let bridge = SupermuxWireJSON()
            patch["actions"] = actions.compactMap { try? bridge.dictionary(from: $0) }
        }
        return patch
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}

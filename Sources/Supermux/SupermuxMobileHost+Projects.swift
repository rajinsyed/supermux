import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.projects.*` / `mobile.supermux.project.*` handlers: the
/// Mac side of the iOS Projects section, reads and writes. All state flows
/// through ``SupermuxComposition`` (the same projects model every Mac sidebar
/// shares — create runs the model's own `config.json` import, exactly like
/// the desktop add path); the wire payloads and patch semantics are
/// package-tested SupermuxKit types. `supermux.projects.updated` is emitted
/// by ``SupermuxMobileProjectsObserver`` watching the model, so every write
/// path (mobile or desktop) pokes the phone exactly once.
extension TerminalController {
    /// The icon reads `project.icon` runs, one per icon and etag at a time.
    nonisolated static let supermuxProjectIconReads = SupermuxBoundedLookups<SupermuxProjectIconPayload>()
    /// How long `project.icon` waits for its read.
    nonisolated static let supermuxProjectIconTimeout: TimeInterval = 10
    /// How long `projects.list` waits for the first load, for the git
    /// origins and for the file facts, and a project result for its origin:
    /// the file facts' own bound.
    nonisolated static let supermuxProjectsLookupBound: TimeInterval = SupermuxProjectFileFacts.timeout

    /// `mobile.supermux.projects.list`: the registered projects, the global
    /// terminal presets (the same set the desktop bar shows above every
    /// workspace), and the sidebar section's collapse state, as
    /// `{projects: [SupermuxProjectDTO], presets: [SupermuxTerminalPresetDTO],
    /// section_collapsed}`.
    ///
    /// Every wait is bounded (``supermuxProjectsLookupBound`` each), because
    /// the work behind them is file and git access in each project's folder,
    /// which blocks in the kernel while a macOS privacy prompt for that folder
    /// is unanswered (nobody answers it on a headless Mac): one held list
    /// missed the caller's 20 s reply deadline on every connect. The first
    /// load also imports each project's `config.json` and lists its
    /// worktrees, but the projects are known once the projects file is read,
    /// and the observer pokes the caller again when the imports change them.
    func v2SupermuxProjectsList(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.projectsModel
        let bound = Self.supermuxProjectsLookupBound
        _ = await SupermuxBoundedAwait(timeout: bound).value { await model.loadIfNeeded() }
        guard model.hasLoaded else {
            return .err(code: "unavailable", message: "The projects are still loading", data: nil)
        }
        let projects = model.projects
        let presets = model.presets
        let isSectionCollapsed = model.isSectionCollapsed
        let roots = projects.map(\.rootPath)
        let resolver = SupermuxComposition.gitRemoteResolver
        let facts = SupermuxProjectFileFacts.shared
        // Additive `git_remote_url` (cross-Mac repo identity): `git config`
        // on the resolver actor; an origin not found in time keeps the last
        // one known. has_custom_icon, the icon token and the config marker:
        // bounded lookups off the cooperative pool, each project keeping its
        // last facts. Both run at once.
        async let remoteURLsInTime = resolver.remoteURLs(forRoots: roots, within: bound)
        async let factsInTime = facts.facts(for: projects)
        let gitRemoteURLs = await remoteURLsInTime
        let fileFacts = await factsInTime
        do {
            let payload = try SupermuxMobileProjectsPayloadBuilder().projectsList(
                projects: projects,
                presets: presets,
                isSectionCollapsed: isSectionCollapsed,
                gitRemoteURLs: gitRemoteURLs,
                fileFacts: fileFacts
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode projects list", data: nil)
        }
    }

    /// `mobile.supermux.project.create`: registers the folder at `root_path`
    /// as a project through the exact desktop add path —
    /// ``SupermuxProjectsModel/addProject(rootPath:)`` — which imports a
    /// repo-shipped `.supermux/config.json` / `.superset/config.json` (setup,
    /// teardown, run, actions) before returning. Registering an
    /// already-registered folder returns the existing record (same as
    /// desktop). Result: `{project: SupermuxProjectDTO}` with the imported
    /// fields and the `config_path` read-only marker.
    @MainActor
    func v2SupermuxProjectCreate(params: [String: Any]) async -> V2CallResult {
        guard let raw = params["root_path"] as? String else {
            return .err(code: "invalid_params", message: "root_path is required", data: nil)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !trimmed.isEmpty, expanded.hasPrefix("/") else {
            return .err(code: "invalid_params", message: "root_path must be an absolute folder path", data: nil)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .err(code: "invalid_params", message: "root_path is not an existing folder", data: [
                "root_path": expanded,
            ])
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        let project = await model.addProject(rootPath: expanded)
        return await supermuxProjectResult(project)
    }

    /// `mobile.supermux.project.update`: applies `patch` to the project
    /// (RPC-PROJ-02 patch semantics: only present keys applied; arrays like
    /// `run_commands`/`actions` replaced whole; explicit `null` clears a
    /// nullable field; immutable/unknown keys rejected). Fields owned by a
    /// repo-shipped `config.json` are rejected with `invalid_params`, exactly
    /// like the desktop editor renders them read-only. Result:
    /// `{project: SupermuxProjectDTO}`.
    @MainActor
    func v2SupermuxProjectUpdate(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let patchObject = params["patch"] as? [String: Any] else {
            return .err(code: "invalid_params", message: "patch must be an object", data: nil)
        }
        // The read-only marker probes the project's folder: a bounded probe off
        // the cooperative pool (a pending privacy prompt can block it), and no
        // patch while it is unknown.
        let facts = await SupermuxProjectFileFacts.shared.facts(for: [project])
        guard let projectFacts = facts[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: project)] else {
            return .err(code: "timed_out", message: "The project's folder could not be read on this Mac in time", data: nil)
        }
        let isConfigManaged = projectFacts.configPath != nil
        // Re-read the record AFTER the awaited probe: a desktop or other-client
        // edit to a DIFFERENT field during that suspension must survive. The
        // patch replaces only its own keys; writing back the pre-await snapshot
        // would silently revert the concurrent change (lost update). Everything
        // from here to `updateProject` is synchronous, so no window reopens.
        let model = SupermuxComposition.projectsModel
        guard let current = model.projects.first(where: { $0.id == project.id }) else {
            return .err(code: "not_found", message: "Unknown project", data: nil)
        }
        let updated: SupermuxProject
        do {
            let patch = try SupermuxMobileProjectPatch(wire: patchObject)
            updated = try patch.applied(to: current, isConfigManaged: isConfigManaged)
        } catch let error as SupermuxMobilePatchError {
            return .err(code: "invalid_params", message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Malformed patch", data: nil)
        }
        model.updateProject(updated)
        return await supermuxProjectResult(updated)
    }

    /// `mobile.supermux.project.delete`: unregisters the project through the
    /// same model path as the desktop (worktrees and the repository stay on
    /// disk; durable directory associations pointing at the project are
    /// dropped). The confirmation dialog lives on the phone. Result:
    /// `{removed: true, project_id}`.
    @MainActor
    func v2SupermuxProjectDelete(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        SupermuxComposition.projectsModel.removeProject(id: project.id)
        return .ok([
            "removed": true,
            "project_id": project.id.uuidString,
        ])
    }

    /// `mobile.supermux.projects.set_section_collapsed`: persists the sidebar
    /// Projects section's collapse state (the write path for the
    /// `section_collapsed` field `projects.list` returns; the model's own
    /// `didSet` persist is the single shared mutation path with the desktop
    /// header). Result: `{section_collapsed}`.
    @MainActor
    func v2SupermuxProjectsSetSectionCollapsed(params: [String: Any]) async -> V2CallResult {
        guard let collapsed = params["collapsed"] as? Bool else {
            return .err(code: "invalid_params", message: "collapsed must be a boolean", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        model.isSectionCollapsed = collapsed
        return .ok(["section_collapsed": collapsed])
    }

    /// The `{project: SupermuxProjectDTO}` result for one record (its origin
    /// lookup and its icon and config probes are bounded, as in `projects.list`).
    func supermuxProjectResult(_ project: SupermuxProject) async -> V2CallResult {
        let gitRemoteURL = await SupermuxComposition.gitRemoteResolver.remoteURLs(
            forRoots: [project.rootPath],
            within: Self.supermuxProjectsLookupBound
        )[project.rootPath]
        let fileFacts = await SupermuxProjectFileFacts.shared.facts(for: [project])
        do {
            let payload = try SupermuxMobileProjectsPayloadBuilder().projectPayload(
                project: project,
                gitRemoteURL: gitRemoteURL,
                fileFacts: fileFacts[SupermuxMobileProjectsPayloadBuilder.fileFactsKey(for: project)] ?? .unknown
            )
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode project", data: nil)
        }
    }

    /// `mobile.supermux.project.open`: opens (or focuses) a workspace at the
    /// project root through the same ``SupermuxTabManagerOpener`` path the
    /// desktop uses — which records the workspace→project association via
    /// ``SupermuxWorkspaceAssociationStore`` so the workspace nests under the
    /// project in the Mac sidebar. `select: false` (another Mac asking) opens
    /// it without selecting it. Result: `{workspace_id, project_id}`.
    @MainActor
    func v2SupermuxProjectOpen(params: [String: Any]) async -> V2CallResult {
        let project: SupermuxProject
        switch await supermuxResolveProject(params: params) {
        case let .failure(error): return error
        case let .success(resolved): project = resolved
        }
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        SupermuxComposition.projectsModel.noteOpened(id: project.id)
        guard let workspaceID = SupermuxTabManagerOpener(tabManager: tabManager)
            .openWorkspaceReturningWorkspaceId(SupermuxOpenWorkspaceRequest(
                title: project.name,
                directory: project.rootPath,
                colorHex: project.colorHex,
                projectId: project.id,
                preservesUserFocus: true,
                selectsWorkspace: supermuxSelectsWorkspace(params: params)
            )) else {
            return .err(code: "unavailable", message: "Workspace context is unavailable", data: nil)
        }
        return .ok([
            "workspace_id": workspaceID.uuidString,
            "project_id": project.id.uuidString,
        ])
    }

    /// `mobile.supermux.project.icon`: the project's icon as etag'd base64
    /// PNG. With a matching `etag` param the result is
    /// `{not_modified: true, etag}` and carries no image data.
    func v2SupermuxProjectIcon(params: [String: Any]) async -> V2CallResult {
        guard let idString = params["project_id"] as? String,
              let projectID = UUID(uuidString: idString) else {
            return .err(code: "invalid_params", message: "project_id must be a project UUID", data: nil)
        }
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        guard let project = model.projects.first(where: { $0.id == projectID }) else {
            return .err(code: "not_found", message: "Unknown project", data: [
                "project_id": idString
            ])
        }
        let requestedETag = params["etag"] as? String
        let rootPath = project.rootPath
        let customIconPath = project.customIconPath
        // Reading, hashing and re-encoding the icon run on a bounded lookup off
        // the main actor and the cooperative pool: a read stuck behind an
        // unanswered privacy prompt answers `timed_out` instead of holding the
        // reply past the caller's deadline, and is never started twice.
        let key = [rootPath, customIconPath ?? "", requestedETag ?? ""].joined(separator: "\n")
        guard let outcome = await Self.supermuxProjectIconReads.value(key, timeout: Self.supermuxProjectIconTimeout, lookup: {
            SupermuxProjectIconPayloadBuilder().payload(
                rootPath: rootPath,
                customIconPath: customIconPath,
                ifNoneMatch: requestedETag
            )
        }) else {
            return .err(code: "timed_out", message: "The project's icon could not be read on this Mac in time", data: [
                "project_id": idString
            ])
        }
        switch outcome {
        case .notFound:
            return .err(code: "not_found", message: "Project has no icon image", data: [
                "project_id": idString
            ])
        case let .notModified(etag):
            return .ok([
                "not_modified": true,
                "etag": etag,
            ])
        case let .icon(pngBase64, etag):
            return .ok([
                "not_modified": false,
                "etag": etag,
                "png_base64": pngBase64,
            ])
        }
    }
}

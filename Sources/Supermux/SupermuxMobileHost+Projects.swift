import Foundation
import SupermuxKit
import SupermuxMobileCore

/// `mobile.supermux.projects.*` read handlers: the Mac side of the iOS
/// Projects section. All state is read through ``SupermuxComposition`` (the
/// same projects model every Mac sidebar shares); the wire payloads are built
/// by package-tested SupermuxKit types.
extension TerminalController {
    /// `mobile.supermux.projects.list`: the registered projects plus the
    /// sidebar section's collapse state, as
    /// `{projects: [SupermuxProjectDTO], section_collapsed}`.
    func v2SupermuxProjectsList(params: [String: Any]) async -> V2CallResult {
        let model = SupermuxComposition.projectsModel
        await model.loadIfNeeded()
        let projects = model.projects
        let isSectionCollapsed = model.isSectionCollapsed
        do {
            // has_custom_icon stats candidate icon paths per project; keep
            // that file I/O off the main actor.
            let payload = try await Task.detached(priority: .userInitiated) {
                try SupermuxMobileProjectsPayloadBuilder().projectsList(
                    projects: projects,
                    isSectionCollapsed: isSectionCollapsed
                )
            }.value
            return .ok(payload)
        } catch {
            return .err(code: "unavailable", message: "Failed to encode projects list", data: nil)
        }
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
        // File probing, hashing, and PNG re-encoding run off the main actor.
        let outcome = await Task.detached(priority: .userInitiated) {
            SupermuxProjectIconPayloadBuilder().payload(
                rootPath: rootPath,
                customIconPath: customIconPath,
                ifNoneMatch: requestedETag
            )
        }.value
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

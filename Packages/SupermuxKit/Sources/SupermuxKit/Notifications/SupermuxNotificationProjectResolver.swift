public import Foundation
public import SupermuxMobileCore

/// Resolves the project identity carried by a notification, from the workspace
/// the notification fired in.
///
/// Every notification surface needs the same answer — the Mac panel, the Mac
/// system banner, the iOS feed wire item, and the APNs push — so the resolution
/// lives here once instead of being re-derived per surface, where the four
/// copies would inevitably drift.
///
/// Deliberately NOT the window-scoped `SupermuxProjectResolutionCache`: that
/// cache is keyed by `TabManager` and validated inside SwiftUI bodies, and the
/// notification delivery path has no window. This resolver is a pure function
/// over the app-wide project list plus the association store, both of which the
/// composition root already owns as singletons.
///
/// Cost is one dictionary lookup plus, in the worst case, one lexical path
/// normalization — the same work the sidebar already does per workspace per
/// render. There is no file I/O and no `await`, which is what makes it safe on
/// the main-actor delivery path.
@MainActor
public struct SupermuxNotificationProjectResolver: Sendable {
    /// Reports whether a project currently has a rendered icon image available,
    /// so the snapshot can advertise one without touching the filesystem.
    ///
    /// Injected rather than probed: resolving an icon means stat-ing up to 30
    /// candidate paths (``SupermuxProjectIconResolver``), which must never run
    /// on a notification-delivery path. The app passes the already-warm
    /// ``SupermuxProjectIconStore``; tests pass a stub.
    public typealias IconTokenProvider = @MainActor (UUID) -> String?

    private let iconToken: IconTokenProvider

    /// Creates a resolver.
    /// - Parameter iconToken: Returns an opaque change token when the project
    ///   has a rendered icon image, or `nil` when it has none. Defaults to
    ///   "no icon", which degrades every avatar to its symbol/letter form.
    public init(iconToken: @escaping IconTokenProvider = { _ in nil }) {
        self.iconToken = iconToken
    }

    /// Resolves the project identity for a workspace, or `nil` when the
    /// workspace belongs to no registered project.
    ///
    /// - Parameters:
    ///   - workspaceID: The notification's `tabId`.
    ///   - directory: The workspace's current directory, raw and un-resolved
    ///     (symlink resolution blocks the main actor on remote-mirror paths —
    ///     see ``SupermuxProjectMatcher``).
    ///   - projects: All registered projects.
    ///   - associations: The app-wide association store.
    /// - Returns: An immutable identity snapshot, or `nil`.
    public func project(
        forWorkspace workspaceID: UUID,
        directory: String?,
        projects: [SupermuxProject],
        associations: SupermuxWorkspaceAssociationStore
    ) -> SupermuxNotificationProject? {
        guard !projects.isEmpty else { return nil }
        guard let projectID = associations.projectId(
            forWorkspace: workspaceID,
            directory: directory,
            in: projects
        ) else { return nil }
        guard let project = projects.first(where: { $0.id == projectID }) else { return nil }
        return snapshot(of: project)
    }

    /// Builds the identity snapshot for an already-resolved project.
    /// - Parameter project: The owning project.
    public func snapshot(of project: SupermuxProject) -> SupermuxNotificationProject {
        SupermuxNotificationProject(
            id: project.id.uuidString,
            name: project.name,
            colorHex: project.colorHex,
            iconSymbol: project.iconSymbol,
            iconETag: iconToken(project.id)
        )
    }
}

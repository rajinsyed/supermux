import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import SupermuxKit
import SupermuxMobileCore

/// App-target seam that answers "which project does this notification belong
/// to?" for the notification store, the phone push adapter, and the mobile feed
/// wire item.
///
/// A thin adapter by design: it gathers the live inputs (the workspace's
/// directory, the app-wide projects/associations from ``SupermuxComposition``,
/// and the warm icon store) and delegates the actual resolution to the
/// package-unit-tested ``SupermuxNotificationProjectResolver``, so the logic
/// never forks from its tests.
///
/// **Why not the sidebar's cache.** `SupermuxProjectResolutionCache` is keyed
/// by `TabManager` and handed out per window; notification delivery has no
/// window, and reaching into a window's cache from a non-render path would tie
/// delivery to whichever window happened to exist. The uncached resolution is
/// one dictionary lookup plus at most one lexical path normalization — cheap
/// enough for a path that runs once per notification, not once per frame.
@MainActor
enum SupermuxNotificationProjectBridge {
    /// The resolver, wired to the app's shared icon store so a project with a
    /// rendered avatar advertises one without any filesystem probing on the
    /// delivery path.
    private static let resolver = SupermuxNotificationProjectResolver(
        iconToken: { projectID in
            // The store's own content identity (root/custom paths + each
            // resolved file's path, mtime, size). Read from the warm cache, so
            // no filesystem probing happens on the delivery path.
            //
            // NOT an in-process object hash: the phone compares this token
            // against one it received in a different process, so only a value
            // derived from the file itself can ever mean the same thing on
            // both sides. A pointer hash would be a token that never matches.
            SupermuxComposition.projectIconStore.contentToken(for: projectID)
        }
    )

    /// Resolves the project identity for a workspace, or `nil` when the
    /// workspace belongs to no registered project.
    ///
    /// Returns `nil` — never blocks — when the projects file has not loaded
    /// yet. A notification that fires before the sidebar's first mount simply
    /// carries no project, exactly like a project-less workspace.
    /// - Parameter workspaceID: The notification's workspace (`tabId`).
    static func project(forWorkspace workspaceID: UUID) -> SupermuxNotificationProject? {
        let projects = SupermuxComposition.projectsModel.projects
        guard !projects.isEmpty else { return nil }
        return resolver.project(
            forWorkspace: workspaceID,
            // The raw directory string, exactly what the sidebar's
            // SupermuxProjectResolutionCache resolves by — never symlink
            // resolved (remote-mirror paths block on the automounter).
            directory: AppDelegate.shared?.workspaceFor(tabId: workspaceID)?.currentDirectory,
            projects: projects,
            associations: SupermuxComposition.workspaceAssociations
        )
    }

    /// Resolves one immutable icon snapshot for every project in a notification list.
    ///
    /// Call above a `LazyVStack` boundary and pass the returned values down to
    /// rows; no observable icon store crosses into the lazy subtree.
    /// - Parameter notifications: Notification snapshots whose project icons are needed.
    /// - Returns: Decoded images keyed by project identifier.
    static func projectIcons(
        for notifications: [TerminalNotification]
    ) -> [String: NSImage] {
        projectIcons(for: notifications, imageForSource: iconImage(for:))
    }

    /// Testable variant with an injected icon lookup.
    static func projectIcons(
        for notifications: [TerminalNotification],
        imageForSource: (SupermuxNotificationIconSource) -> NSImage?
    ) -> [String: NSImage] {
        var icons: [String: NSImage] = [:]
        for notification in notifications {
            guard let project = notification.project,
                  icons[project.id] == nil,
                  let source = iconSource(for: project, origin: notification.origin),
                  let image = imageForSource(source)
            else { continue }
            icons[project.id] = image
        }
        return icons
    }

    /// Where a notification's project icon is looked up: a record mirrored
    /// from another Mac carries that Mac's project id, which only that Mac's
    /// fetched icons know (``SupermuxNotificationIconSource``).
    static func iconSource(
        for project: SupermuxNotificationProject,
        origin: TerminalNotificationOrigin
    ) -> SupermuxNotificationIconSource? {
        let mirroredFromMachineID: String?
        switch origin {
        case .deviceMac(let machineID): mirroredFromMachineID = machineID
        case .local, .sshRelay, .cloudVM: mirroredFromMachineID = nil
        }
        return SupermuxNotificationIconSource(projectID: project.id, mirroredFromMachineID: mirroredFromMachineID)
    }

    /// The icon already in memory for `source`: this Mac's icon store, or
    /// the other Mac's icons fetched by the remote-projects model. Never
    /// probes the filesystem or the network.
    static func iconImage(for source: SupermuxNotificationIconSource) -> NSImage? {
        switch source {
        case .local(let projectID):
            return SupermuxComposition.projectIconStore.image(for: projectID)
        case .remote(let machineID, let projectID):
            return SupermuxComposition.remoteProjects.icon(machine: SurfaceMachineID(rawValue: machineID), projectID: projectID)
        }
    }
}

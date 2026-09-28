public import Foundation
public import Observation
internal import SupermuxMobileCore

/// The `origin` URL of each local project, observable for the Mac UI, so a
/// local project can be matched with another Mac's copy of the same repo
/// (`SupermuxProjectDTO.gitRemoteIdentity` on the remote side).
///
/// ```swift
/// await remotes.refresh(projects: model.projects)
/// remotes.identity(for: project.id) == remoteDTO.gitRemoteIdentity
/// ```
@MainActor
@Observable
public final class SupermuxProjectGitRemotes {
    /// Resolved origins keyed by project id; projects without one are absent.
    public private(set) var urlsByProjectID: [UUID: String] = [:]

    @ObservationIgnored private let resolver: SupermuxGitRemoteURLResolver

    /// Creates the lookup over a shared resolver (its cache is shared with the
    /// host's `projects.list` payload).
    public init(resolver: SupermuxGitRemoteURLResolver) {
        self.resolver = resolver
    }

    /// The project's `origin` URL, if it has one.
    public func url(for projectID: UUID) -> String? {
        urlsByProjectID[projectID]
    }

    /// The device-independent repository key (`host/owner/repo`) for the
    /// project, comparable with a remote project's `gitRemoteIdentity`.
    public func identity(for projectID: UUID) -> String? {
        SupermuxGitRemoteIdentity.normalized(urlsByProjectID[projectID])
    }

    /// Resolves every project's origin (cached, off the main actor) and
    /// replaces the map, dropping projects no longer in `projects`.
    public func refresh(projects: [SupermuxProject]) async {
        let roots = projects.map(\.rootPath)
        let urls = await resolver.remoteURLs(forRoots: roots)
        var next: [UUID: String] = [:]
        for project in projects {
            if let url = urls[project.rootPath] { next[project.id] = url }
        }
        if next != urlsByProjectID { urlsByProjectID = next }
    }
}

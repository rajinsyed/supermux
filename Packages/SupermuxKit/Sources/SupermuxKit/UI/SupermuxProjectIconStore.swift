import AppKit
import Observation

/// Loads and caches the auto-detected logo image for each project, kept off the
/// core ``SupermuxProjectsModel`` so that model stays free of AppKit.
///
/// Filesystem probing (``SupermuxProjectIconResolver``) runs off the main actor;
/// the resulting `NSImage` is created on the main actor so no non-`Sendable`
/// image ever crosses an actor boundary. The store is read *above* the projects
/// list boundary, and only immutable `NSImage` values are handed down to rows —
/// honoring the snapshot-boundary rule that forbids row subtrees from holding a
/// reference to an observable store.
@MainActor
@Observable
final class SupermuxProjectIconStore {
    /// Detected logo per project id; absent when the project has no logo file.
    private(set) var images: [UUID: NSImage] = [:]

    /// Root path each project's logo was last resolved against, so an unchanged
    /// project is never re-probed across refreshes.
    @ObservationIgnored private var resolvedRoots: [UUID: String] = [:]
    private let resolver = SupermuxProjectIconResolver()

    /// The cached logo for a project, or `nil` when none was found.
    /// - Parameter id: Project identifier.
    func image(for id: UUID) -> NSImage? { images[id] }

    /// Resolves logos for projects whose root changed since the last pass and
    /// drops cache entries for projects that no longer exist.
    ///
    /// Idempotent and cheap to call on every project-list change: projects with
    /// an unchanged root are skipped, so only newly added or moved projects pay
    /// the filesystem probe.
    /// - Parameter projects: Current project list.
    func refresh(projects: [SupermuxProject]) async {
        for project in projects where resolvedRoots[project.id] != project.rootPath {
            resolvedRoots[project.id] = project.rootPath
            let rootPath = project.rootPath
            let resolver = self.resolver
            // Probe off the main actor; build the image on it (NSImage is not Sendable).
            let url = await Task.detached { resolver.resolve(rootPath: rootPath) }.value
            images[project.id] = url.flatMap { NSImage(contentsOf: $0) }
        }
        let live = Set(projects.map(\.id))
        images = images.filter { live.contains($0.key) }
        resolvedRoots = resolvedRoots.filter { live.contains($0.key) }
    }

    /// Forces the next ``refresh(projects:)`` to re-probe a project, e.g. after
    /// the user edits it or drops a logo file into the repository.
    /// - Parameter id: Project to re-resolve.
    func invalidate(_ id: UUID) { resolvedRoots[id] = nil }
}

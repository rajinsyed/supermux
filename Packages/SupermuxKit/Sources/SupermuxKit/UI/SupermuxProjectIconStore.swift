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
    /// Resolved avatar image per project id — the user's custom icon when set
    /// and decodable, otherwise the auto-detected logo; absent when neither
    /// resolves.
    private(set) var images: [UUID: NSImage] = [:]

    /// Identity (root path + custom icon path) each project's avatar was last
    /// resolved against, so an unchanged project is never re-probed across
    /// refreshes; changing either re-resolves on the next pass.
    @ObservationIgnored private var resolvedKeys: [UUID: String] = [:]
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
        for project in projects {
            let key = Self.resolutionKey(for: project)
            guard resolvedKeys[project.id] != key else { continue }
            resolvedKeys[project.id] = key
            let rootPath = project.rootPath
            let customIconPath = project.customIconPath
            let resolver = self.resolver
            // Probe both candidates off the main actor; build images on it
            // (NSImage is not Sendable). URLs are Sendable, so the tuple crosses
            // the actor boundary safely.
            let candidates = await Task.detached { () -> (custom: URL?, detected: URL?) in
                (resolver.customIconURL(customIconPath), resolver.resolve(rootPath: rootPath))
            }.value
            // The custom image overrides detection, but a custom file that fails
            // to decode as an image falls back to the detected logo rather than
            // leaving the avatar blank.
            images[project.id] = candidates.custom.flatMap { NSImage(contentsOf: $0) }
                ?? candidates.detected.flatMap { NSImage(contentsOf: $0) }
        }
        let live = Set(projects.map(\.id))
        images = images.filter { live.contains($0.key) }
        resolvedKeys = resolvedKeys.filter { live.contains($0.key) }
    }

    /// Forces the next ``refresh(projects:)`` to re-probe a project, e.g. after
    /// the user edits it or drops a logo file into the repository.
    /// - Parameter id: Project to re-resolve.
    func invalidate(_ id: UUID) { resolvedKeys[id] = nil }

    /// The cache identity for a project's avatar: its root path and custom icon
    /// path together, so editing either invalidates the cached image.
    private static func resolutionKey(for project: SupermuxProject) -> String {
        "\(project.rootPath)\n\(project.customIconPath ?? "")"
    }
}

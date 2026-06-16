public import AppKit
public import Foundation
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
public final class SupermuxProjectIconStore {
    /// Resolved avatar image per project id — the user's custom icon when set
    /// and decodable, otherwise the auto-detected logo; absent when neither
    /// resolves.
    private(set) var images: [UUID: NSImage] = [:]

    /// Identity (root path + custom icon path) each project's avatar was last
    /// resolved against, so an unchanged project is never re-probed across
    /// refreshes; changing either re-resolves on the next pass.
    @ObservationIgnored private var resolvedKeys: [UUID: String] = [:]
    /// Monotonic token identifying the in-flight ``refresh(projects:)``. Each call
    /// bumps it; a call that suspended for an off-actor probe drops its result if a
    /// newer refresh started meanwhile, so a slow probe can't clobber fresh state.
    @ObservationIgnored private var refreshGeneration = 0
    private let resolver = SupermuxProjectIconResolver()

    /// Creates an empty icon store.
    public init() {}

    /// The cached logo for a project, or `nil` when none was found.
    /// - Parameter id: Project identifier.
    public func image(for id: UUID) -> NSImage? { images[id] }

    /// Resolves logos for projects whose root changed since the last pass and
    /// drops cache entries for projects that no longer exist.
    ///
    /// Idempotent and cheap to call on every project-list change: projects with
    /// an unchanged root are skipped, so only newly added or moved projects pay
    /// the filesystem probe.
    /// - Parameter projects: Current project list.
    public func refresh(projects: [SupermuxProject]) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        for project in projects {
            let key = Self.resolutionKey(for: project)
            guard resolvedKeys[project.id] != key else { continue }
            let rootPath = project.rootPath
            let customIconPath = project.customIconPath
            let resolver = self.resolver
            // Probe both candidates off the main actor; build images on it
            // (NSImage is not Sendable). URLs are Sendable, so the tuple crosses
            // the actor boundary safely.
            let candidates = await Task.detached { () -> (custom: URL?, detected: URL?) in
                (resolver.customIconURL(customIconPath), resolver.resolve(rootPath: rootPath))
            }.value
            // A newer refresh superseded this one while we were probing off-actor;
            // drop our now-stale result rather than clobbering the newer state.
            // (resolvedKeys is recorded only after a kept write, so bailing here
            // never poisons the cache into skipping a future re-probe.)
            guard generation == refreshGeneration else { return }
            // The custom image overrides detection, but a custom file that fails
            // to decode as an image falls back to the detected logo rather than
            // leaving the avatar blank.
            images[project.id] = candidates.custom.flatMap { NSImage(contentsOf: $0) }
                ?? candidates.detected.flatMap { NSImage(contentsOf: $0) }
            resolvedKeys[project.id] = key
        }
        guard generation == refreshGeneration else { return }
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

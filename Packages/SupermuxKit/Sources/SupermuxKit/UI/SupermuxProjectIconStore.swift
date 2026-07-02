public import AppKit
public import Foundation
import Observation

/// Inputs for one project's off-actor icon probe (all Sendable value data).
private struct SupermuxIconProbeInput: Sendable {
    let projectId: UUID
    let rootPath: String
    let customIconPath: String?
}

/// The off-actor probe result for one project: the cache key (which includes
/// the resolved files' mtime/size), and — only when the key changed — the icon
/// files' bytes, so unchanged projects are never re-read or re-decoded.
private struct SupermuxIconProbeResult: Sendable {
    let projectId: UUID
    let key: String
    let isChanged: Bool
    let customURL: URL?
    let customData: Data?
    let detectedURL: URL?
    let detectedData: Data?
}

/// Loads and caches the auto-detected logo image for each project, kept off the
/// core ``SupermuxProjectsModel`` so that model stays free of AppKit.
///
/// Filesystem probing (``SupermuxProjectIconResolver``) *and* the image file
/// reads run off the main actor in one detached hop per refresh; only `Sendable`
/// `Data` crosses back, and the non-`Sendable` `NSImage` is decoded on the main
/// actor. The store is read *above* the projects list boundary, and only
/// immutable `NSImage` values are handed down to rows — honoring the
/// snapshot-boundary rule that forbids row subtrees from holding a reference to
/// an observable store.
@MainActor
@Observable
public final class SupermuxProjectIconStore {
    /// Resolved avatar image per project id — the user's custom icon when set
    /// and decodable, otherwise the auto-detected logo; absent when neither
    /// resolves.
    private(set) var images: [UUID: NSImage] = [:]

    /// Identity each project's avatar was last resolved against: root path,
    /// custom icon path, plus the resolved icon files' path/mtime/size — so an
    /// unchanged avatar is never re-read across refreshes, while editing the
    /// project *or replacing the icon file on disk* re-decodes on the next pass.
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

    /// Resolves logos for projects whose icon source changed since the last
    /// pass and drops cache entries for projects that no longer exist.
    ///
    /// Idempotent and cheap to call on every project-list change: the probe and
    /// all file reads run off the main actor, and a project whose resolved icon
    /// file is unchanged (same path, mtime, and size) skips the read and decode
    /// entirely.
    /// - Parameter projects: Current project list.
    public func refresh(projects: [SupermuxProject]) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let resolver = self.resolver
        let inputs = projects.map {
            SupermuxIconProbeInput(projectId: $0.id, rootPath: $0.rootPath, customIconPath: $0.customIconPath)
        }
        let knownKeys = resolvedKeys
        let results = await Task.detached { () -> [SupermuxIconProbeResult] in
            inputs.map { Self.probe($0, resolver: resolver, knownKey: knownKeys[$0.projectId]) }
        }.value
        // A newer refresh superseded this one while we were probing off-actor;
        // drop our now-stale result rather than clobbering the newer state.
        // (resolvedKeys is recorded only after a kept write, so bailing here
        // never poisons the cache into skipping a future re-probe.)
        guard generation == refreshGeneration else { return }
        for result in results where result.isChanged {
            // The custom image overrides detection, but a custom file that fails
            // to decode as an image falls back to the detected logo rather than
            // leaving the avatar blank.
            images[result.projectId] = Self.decode(result.customData, fallbackURL: result.customURL)
                ?? Self.decode(result.detectedData, fallbackURL: result.detectedURL)
            resolvedKeys[result.projectId] = result.key
        }
        let live = Set(projects.map(\.id))
        // Publish the prune only when it actually removes entries: the store
        // is shared across every window's section (and warmed on each
        // workspace-switcher open), so an unconditional `images` write here
        // would re-render all windows' Projects sections per refresh even
        // when no icon changed. Count comparison suffices — filter only
        // removes. (`resolvedKeys` is @ObservationIgnored; no guard needed.)
        let prunedImages = images.filter { live.contains($0.key) }
        if prunedImages.count != images.count { images = prunedImages }
        resolvedKeys = resolvedKeys.filter { live.contains($0.key) }
    }

    /// Forces the next ``refresh(projects:)`` to re-probe a project, e.g. after
    /// the user edits it or drops a logo file into the repository.
    /// - Parameter id: Project to re-resolve.
    func invalidate(_ id: UUID) { resolvedKeys[id] = nil }

    /// Resolves one project's icon candidates and stats them for the cache key;
    /// reads their bytes only when the key differs from `knownKey`. Runs off
    /// the main actor.
    private nonisolated static func probe(
        _ input: SupermuxIconProbeInput,
        resolver: SupermuxProjectIconResolver,
        knownKey: String?
    ) -> SupermuxIconProbeResult {
        let custom = resolver.customIconURL(input.customIconPath)
        let detected = resolver.resolve(rootPath: input.rootPath)
        let key = resolutionKey(
            rootPath: input.rootPath,
            customIconPath: input.customIconPath,
            customIconURL: custom,
            detectedIconURL: detected
        )
        guard knownKey != key else {
            return SupermuxIconProbeResult(
                projectId: input.projectId, key: key, isChanged: false,
                customURL: nil, customData: nil, detectedURL: nil, detectedData: nil
            )
        }
        // Read both candidates: whether the custom bytes decode is only knowable
        // on the main actor, so the detected fallback must already be in hand.
        return SupermuxIconProbeResult(
            projectId: input.projectId,
            key: key,
            isChanged: true,
            customURL: custom,
            customData: custom.flatMap { try? Data(contentsOf: $0) },
            detectedURL: detected,
            detectedData: detected.flatMap { try? Data(contentsOf: $0) }
        )
    }

    /// Decodes icon bytes into an image; rare formats whose rep needs the file
    /// URL (rather than sniffing the data) fall back to a direct file load.
    private static func decode(_ data: Data?, fallbackURL: URL?) -> NSImage? {
        if let data, let image = NSImage(data: data) { return image }
        return fallbackURL.flatMap { NSImage(contentsOf: $0) }
    }

    /// The cache identity for a project's avatar: its root path, custom icon
    /// path, and the resolved icon files' path/mtime/size — so editing the
    /// project or replacing an icon file invalidates the cached image.
    private nonisolated static func resolutionKey(
        rootPath: String,
        customIconPath: String?,
        customIconURL: URL?,
        detectedIconURL: URL?
    ) -> String {
        let custom = fileFingerprint(customIconURL)
        let detected = fileFingerprint(detectedIconURL)
        return "\(rootPath)\n\(customIconPath ?? "")\n\(custom)\n\(detected)"
    }

    /// A stable identity for one icon file: path plus mtime and size (`-` when
    /// unresolved), so replacing the file's contents changes the identity.
    private nonisolated static func fileFingerprint(_ url: URL?) -> String {
        guard let url else { return "-" }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let size = values?.fileSize ?? -1
        return "\(url.path)|\(mtime)|\(size)"
    }
}

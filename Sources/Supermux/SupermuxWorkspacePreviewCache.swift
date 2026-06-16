import AppKit
import Foundation

/// A small, bounded, in-memory cache of workspace preview thumbnails for the
/// workspace switcher.
///
/// Previews are stills, not live views: the switcher captures the visible
/// workspace cheaply and reuses cached thumbnails for the rest (warmed as the
/// user visits workspaces). The cache is LRU-bounded so memory never grows with
/// session length, and main-actor-isolated because `NSImage` and all reads/writes
/// happen on the UI thread.
@MainActor
final class SupermuxWorkspacePreviewCache {
    private struct Entry {
        let image: NSImage
        let capturedAt: Date
    }

    private var entries: [UUID: Entry] = [:]
    /// LRU recency, least-recent first.
    private var recency: [UUID] = []
    private let limit: Int

    /// Creates a cache holding at most `limit` thumbnails.
    init(limit: Int = 24) {
        self.limit = max(1, limit)
    }

    /// Returns the cached thumbnail for `id`, marking it most-recently-used.
    func image(for id: UUID) -> NSImage? {
        guard let entry = entries[id] else { return nil }
        touch(id)
        return entry.image
    }

    /// Stores (or replaces) the thumbnail for `id`, evicting the least-recently
    /// used entry when over the limit.
    func store(_ image: NSImage, for id: UUID, capturedAt: Date = Date()) {
        entries[id] = Entry(image: image, capturedAt: capturedAt)
        touch(id)
        evictIfNeeded()
    }

    private func touch(_ id: UUID) {
        recency.removeAll { $0 == id }
        recency.append(id)
    }

    private func evictIfNeeded() {
        while recency.count > limit, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
    }
}

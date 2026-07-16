public import Foundation

/// In-memory etag-keyed cache of project icon PNGs (architecture §7).
///
/// Keyed by project id; each entry pairs the PNG bytes with the etag the Mac
/// minted for them, so the next `project.icon` request can ride the
/// `not_modified` fast path. Session-scoped and never authoritative — the
/// Mac re-serves everything on demand.
public actor SupermuxProjectIconCache {
    /// One cached icon: the Mac-minted etag plus the decoded PNG bytes.
    public struct Entry: Sendable, Equatable {
        /// The etag the Mac returned with these bytes.
        public let etag: String
        /// The icon's PNG bytes.
        public let pngData: Data

        /// Creates a cache entry.
        /// - Parameters:
        ///   - etag: The etag the Mac returned with these bytes.
        ///   - pngData: The icon's PNG bytes.
        public init(etag: String, pngData: Data) {
            self.etag = etag
            self.pngData = pngData
        }
    }

    private var entries: [String: Entry] = [:]

    /// Creates an empty cache.
    public init() {}

    /// The cached entry for a project, if any.
    /// - Parameter projectID: The project's UUID string.
    public func entry(forProjectID projectID: String) -> Entry? {
        entries[projectID]
    }

    /// Stores (or replaces) a project's cached icon.
    /// - Parameters:
    ///   - entry: The etag + PNG bytes to cache.
    ///   - projectID: The project's UUID string.
    public func store(_ entry: Entry, forProjectID projectID: String) {
        entries[projectID] = entry
    }

    /// Forgets a project's cached icon.
    /// - Parameter projectID: The project's UUID string.
    public func removeEntry(forProjectID projectID: String) {
        entries[projectID] = nil
    }
}

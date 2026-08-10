import Foundation
import SwiftUI
@testable import SupermuxMobileUI
import Testing

/// ``SupermuxProjectIconImageCache`` is what keeps project avatars from
/// blanking when the hosting table cell is rebuilt.
///
/// The avatar's decoded image lives in `@State`, which does not survive the
/// cell teardown any height-changing table update causes, and the RPC-level
/// `SupermuxProjectIconCache` is an `actor` — so even a guaranteed hit costs an
/// `await` and at least one frame of empty avatar. These pin the two
/// properties that make the synchronous cache correct: a hit needs no `await`,
/// and a hit is keyed on the icon's CONTENT identity so a Mac-side icon
/// replacement can never paint the previous image.
@MainActor
@Suite struct SupermuxProjectIconImageCacheTests {
    private func identity(
        projectID: String = "p1",
        hasCustomIcon: Bool = true,
        iconETag: String? = "etag-1"
    ) -> SupermuxProjectIconIdentity {
        SupermuxProjectIconIdentity(
            projectID: projectID,
            hasCustomIcon: hasCustomIcon,
            iconETag: iconETag
        )
    }

    /// Each test works on its own project id so the shared instance's entries
    /// can't leak between them.
    private func isolatedProjectID(_ label: String) -> String {
        "SupermuxProjectIconImageCacheTests-\(label)-\(UUID().uuidString)"
    }

    @Test func aStoredIconReadsBackSynchronously() {
        let cache = SupermuxProjectIconImageCache.shared
        let id = identity(projectID: isolatedProjectID("readback"))

        #expect(cache.image(for: id) == nil)
        cache.store(Image(systemName: "folder"), for: id)
        // No `await`: this is exactly what a rebuilt avatar's `body` does, and
        // the absence of a suspension point here IS the fix.
        #expect(cache.image(for: id) != nil)
    }

    /// A Mac-side icon replacement keeps `hasCustomIcon` true but moves the
    /// etag. Painting the cached pixels then would show the OLD icon forever,
    /// which is worse than the flash this cache exists to remove.
    @Test func aChangedEtagMissesRatherThanPaintingTheOldIcon() {
        let cache = SupermuxProjectIconImageCache.shared
        let projectID = isolatedProjectID("etag")
        cache.store(Image(systemName: "folder"), for: identity(projectID: projectID, iconETag: "etag-1"))

        #expect(cache.image(for: identity(projectID: projectID, iconETag: "etag-2")) == nil)
        #expect(cache.image(for: identity(projectID: projectID, iconETag: "etag-1")) != nil)
    }

    /// A project that lost its custom icon must fall back to the accent
    /// gradient, not keep painting the icon it no longer has.
    @Test func droppingACustomIconForgetsIt() {
        let cache = SupermuxProjectIconImageCache.shared
        let projectID = isolatedProjectID("drop")
        let id = identity(projectID: projectID)
        cache.store(Image(systemName: "folder"), for: id)

        cache.removeImage(forProjectID: projectID)
        #expect(cache.image(for: id) == nil)
    }

    /// The identity also carries `hasCustomIcon`, so a project toggling it off
    /// and on again cannot serve the stale image through the etag alone.
    @Test func losingTheCustomIconFlagMisses() {
        let cache = SupermuxProjectIconImageCache.shared
        let projectID = isolatedProjectID("flag")
        cache.store(Image(systemName: "folder"), for: identity(projectID: projectID))

        #expect(cache.image(for: identity(projectID: projectID, hasCustomIcon: false)) == nil)
    }
}

import Foundation
import SupermuxMobileKit
import Testing

/// In-memory etag-keyed icon cache behavior.
@Suite struct SupermuxProjectIconCacheTests {
    @Test func storeAndReadBackAnEntry() async {
        let cache = SupermuxProjectIconCache()
        let entry = SupermuxProjectIconCache.Entry(etag: "e1", pngData: Data([1, 2, 3]))
        await cache.store(entry, forProjectID: "p1")
        #expect(await cache.entry(forProjectID: "p1") == entry)
        #expect(await cache.entry(forProjectID: "p2") == nil)
    }

    @Test func storingReplacesThePreviousEtagEntry() async {
        let cache = SupermuxProjectIconCache()
        await cache.store(.init(etag: "e1", pngData: Data([1])), forProjectID: "p1")
        let replacement = SupermuxProjectIconCache.Entry(etag: "e2", pngData: Data([2]))
        await cache.store(replacement, forProjectID: "p1")
        #expect(await cache.entry(forProjectID: "p1") == replacement)
    }

    @Test func removeEntryForgetsTheProject() async {
        let cache = SupermuxProjectIconCache()
        await cache.store(.init(etag: "e1", pngData: Data([1])), forProjectID: "p1")
        await cache.removeEntry(forProjectID: "p1")
        #expect(await cache.entry(forProjectID: "p1") == nil)
    }
}

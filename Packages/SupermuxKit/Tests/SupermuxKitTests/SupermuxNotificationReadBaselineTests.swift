import Foundation
import Testing
@testable import SupermuxKit

/// Ways the per-Mac "rows the other Mac already reported read" baseline could
/// fail (written before the code). A mirrored notification copy is marked
/// read only when its row turned read SINCE the previous feed, so the user's
/// Mark as Unread on a copy (local only) survives the host's next feed:
/// 1. A relaunch (a fresh store on the same defaults) forgets the baseline, so
///    the first feed after it re-applies every host-read row and silently
///    marks the user's unread copies read again.
/// 2. The first feed ever seen from a Mac reports nothing, so reads made on
///    that Mac while this one was away never reach the local copies.
/// 3. A row that turned read since the previous feed is not reported, or one
///    reported earlier is reported again.
/// 4. One Mac's baseline answers for another Mac.
/// 5. The stored baseline grows without bound, per Mac or across Macs.
/// 6. Corrupt stored data wedges the store instead of starting over.
/// 7. Forgetting a Mac leaves its baseline behind.
@MainActor
struct SupermuxNotificationReadBaselineTests {
    private let macA = "device:0F7C2C7E-1D51-4D0E-9D7C-2C9B2A4B7E11@default"
    private let macB = "device:AAAAAAAA-0000-4000-8000-000000000002@default"

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SupermuxNotificationReadBaselineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func aRelaunchKeepsTheBaseline() throws {
        let defaults = try makeDefaults()
        let before = SupermuxNotificationReadBaseline(defaults: defaults)
        #expect(before.newlyRead(["r1", "r2"], on: macA) == ["r1", "r2"])

        let relaunched = SupermuxNotificationReadBaseline(defaults: defaults)
        #expect(relaunched.newlyRead(["r1", "r2"], on: macA).isEmpty, "already-read rows must not be applied again")
        #expect(relaunched.newlyRead(["r1", "r2", "r3"], on: macA) == ["r3"])
    }

    @Test func theFirstFeedFromAMacReportsEveryReadRow() throws {
        let baseline = SupermuxNotificationReadBaseline(defaults: try makeDefaults())
        #expect(baseline.newlyRead(["r1", "r2"], on: macA) == ["r1", "r2"])
    }

    @Test func onlyRowsThatTurnedReadSinceThePreviousFeedAreNew() throws {
        let baseline = SupermuxNotificationReadBaseline(defaults: try makeDefaults())
        _ = baseline.newlyRead(["r1"], on: macA)
        #expect(baseline.newlyRead(["r1", "r2"], on: macA) == ["r2"])
        #expect(baseline.newlyRead(["r1", "r2"], on: macA).isEmpty)
        // A row that left the feed and came back read counts again.
        _ = baseline.newlyRead(["r2"], on: macA)
        #expect(baseline.newlyRead(["r1", "r2"], on: macA) == ["r1"])
    }

    @Test func eachMacHasItsOwnBaseline() throws {
        let baseline = SupermuxNotificationReadBaseline(defaults: try makeDefaults())
        _ = baseline.newlyRead(["r1"], on: macA)
        #expect(baseline.newlyRead(["r1"], on: macB) == ["r1"])
    }

    @Test func theStoredBaselineIsBounded() throws {
        let defaults = try makeDefaults()
        let baseline = SupermuxNotificationReadBaseline(defaults: defaults, maxRowsPerMachine: 3, maxMachines: 2)
        _ = baseline.newlyRead(["a", "b", "c", "d", "e"], on: macA)
        let relaunched = SupermuxNotificationReadBaseline(defaults: defaults, maxRowsPerMachine: 3, maxMachines: 2)
        #expect(relaunched.newlyRead(["a", "b", "c", "d", "e"], on: macA).count == 2, "only the rows past the cap count again")

        let macC = "device:CCCCCCCC-0000-4000-8000-000000000003@default"
        _ = relaunched.newlyRead(["x"], on: macB)
        _ = relaunched.newlyRead(["y"], on: macC)
        let again = SupermuxNotificationReadBaseline(defaults: defaults, maxRowsPerMachine: 3, maxMachines: 2)
        #expect(again.newlyRead(["y"], on: macC).isEmpty)
        #expect(again.newlyRead(["x"], on: macB).isEmpty)
        #expect(again.newlyRead(["a"], on: macA) == ["a"], "the least recently fed Mac is evicted")
    }

    @Test func corruptStoredDataStartsOver() throws {
        let defaults = try makeDefaults()
        defaults.set(Data("not json".utf8), forKey: SupermuxNotificationReadBaseline.defaultsKey)
        let baseline = SupermuxNotificationReadBaseline(defaults: defaults)
        #expect(baseline.newlyRead(["r1"], on: macA) == ["r1"])
        #expect(SupermuxNotificationReadBaseline(defaults: defaults).newlyRead(["r1"], on: macA).isEmpty)
    }

    @Test func forgettingAMacDropsItsBaseline() throws {
        let defaults = try makeDefaults()
        let baseline = SupermuxNotificationReadBaseline(defaults: defaults)
        _ = baseline.newlyRead(["r1"], on: macA)
        _ = baseline.newlyRead(["r9"], on: macB)
        baseline.forget(macA)
        let relaunched = SupermuxNotificationReadBaseline(defaults: defaults)
        #expect(relaunched.newlyRead(["r1"], on: macA) == ["r1"])
        #expect(relaunched.newlyRead(["r9"], on: macB).isEmpty)
    }
}

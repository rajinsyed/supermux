import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessLastUsedModelStoreTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "SupermuxHarnessLastUsedModelStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func emptyStoreAnswersNil() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SupermuxHarnessLastUsedModelStore(defaults: defaults).snapshot() == nil)
    }

    @Test func storesAndReturnsModelWithEffort() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SupermuxHarnessLastUsedModelStore(defaults: defaults)
        store.store(model: "opus[1m]", effort: "high")
        let snapshot = try #require(store.snapshot())
        #expect(snapshot.model == "opus[1m]")
        #expect(snapshot.effort == "high")
    }

    @Test func absentEffortPreservesTheStoredLevel() throws {
        // The wire rarely reports effort (init frames carry none), so a
        // model-only update must not erase the level the user last ran at.
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SupermuxHarnessLastUsedModelStore(defaults: defaults)
        store.store(model: "gpt-5.6-sol", effort: "xhigh")
        store.store(model: "claude-opus-5", effort: nil)
        let snapshot = try #require(store.snapshot())
        #expect(snapshot.model == "claude-opus-5")
        #expect(snapshot.effort == "xhigh")
    }

    @Test func sharedAcrossInstancesOnOneSuite() throws {
        // Two controllers (two panes) on the same defaults suite see one value
        // — the store is machine-wide, not per-pane.
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        SupermuxHarnessLastUsedModelStore(defaults: defaults).store(model: "sonnet", effort: nil)
        let other = SupermuxHarnessLastUsedModelStore(defaults: defaults)
        #expect(other.snapshot()?.model == "sonnet")
    }

    @Test func emptyStringsAreIgnoredAndClearRemoves() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SupermuxHarnessLastUsedModelStore(defaults: defaults)
        store.store(model: "", effort: "high")
        #expect(store.snapshot() == nil)
        store.store(model: "sonnet", effort: "")
        #expect(store.snapshot()?.effort == nil)
        store.clear()
        #expect(store.snapshot() == nil)
    }
}

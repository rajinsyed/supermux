import Testing
@testable import SupermuxMobileCore

/// Shared picker semantics: the CLI's `default` entry folds into the default
/// row, and effort levels resolve for named models AND the default row.
struct SupermuxAgentModelSelectionTests {
    private let all = ["low", "medium", "high", "xhigh", "max"]
    private var catalog: [SupermuxAgentModelDTO] {
        [
            SupermuxAgentModelDTO(value: "default", displayName: "Default (recommended)", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
            SupermuxAgentModelDTO(value: "opus[1m]", displayName: "Opus", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
            SupermuxAgentModelDTO(value: "haiku", displayName: "Haiku"),
        ]
    }

    @Test func defaultEntryIsFoldedOutOfSelectableModels() {
        #expect(catalog.defaultEntry?.displayName == "Default (recommended)")
        #expect(catalog.selectableModels.map(\.value) == ["opus[1m]", "haiku"])
    }

    @Test func effortLevelsFollowTheSelection() {
        #expect(catalog.effortLevels(forSelection: nil) == all, "the default row takes effort too")
        #expect(catalog.effortLevels(forSelection: "opus[1m]") == all)
        #expect(catalog.effortLevels(forSelection: "haiku").isEmpty)
        #expect(catalog.effortLevels(forSelection: "unknown").isEmpty)
    }

    @Test func defaultRowWithoutDefaultEntryUsesTheUnionInCanonicalOrder() {
        let proxy = [
            SupermuxAgentModelDTO(value: "gpt-5.6-sol", supportsEffort: true, supportedEffortLevels: ["high", "low", "ultra"]),
            SupermuxAgentModelDTO(value: "claude-opus-5[1m]", supportsEffort: true, supportedEffortLevels: ["medium", "max"]),
        ]
        #expect(proxy.effortLevels(forSelection: nil) == ["low", "medium", "high", "max", "ultra"])
        let noEffort = [SupermuxAgentModelDTO(value: "x")]
        #expect(noEffort.effortLevels(forSelection: nil).isEmpty)
    }

    @Test func emptyCatalogStillOffersEffort() {
        #expect([SupermuxAgentModelDTO]().effortLevels(forSelection: nil) == all)
    }
}

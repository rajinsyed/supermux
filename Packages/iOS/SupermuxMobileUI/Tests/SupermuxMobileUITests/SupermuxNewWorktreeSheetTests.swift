@testable import SupermuxMobileUI
import Testing

@Suite @MainActor struct SupermuxNewWorktreeSheetTests {
    @Test func configuredProjectBranchWins() {
        #expect(SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: "develop",
            branches: ["main", "develop"]
        ) == "develop")
    }

    @Test func mainIsTheDefaultWhenAvailable() {
        #expect(SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: nil,
            branches: ["experiment", "main"]
        ) == "main")
    }

    @Test func repositoryHeadIsTheFallbackWithoutMain() {
        #expect(SupermuxNewWorktreeSheet.initialBaseBranch(
            configuredDefault: nil,
            branches: ["trunk", "experiment"]
        ).isEmpty)
    }

    @Test func untouchedSelectionDefersToFreshMacDefault() {
        #expect(SupermuxNewWorktreeSheet.requestedBaseBranch(
            selection: "main",
            wasEdited: false
        ) == nil)
    }

    @Test func explicitRepositoryHeadBecomesAnOverride() {
        #expect(SupermuxNewWorktreeSheet.requestedBaseBranch(
            selection: "",
            wasEdited: true
        ) == "HEAD")
    }
}

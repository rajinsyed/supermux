import Testing
@testable import SupermuxKit

/// Offline prompt → (workspace title, branch) naming.
struct SupermuxPromptNamingTests {
    @Test func namesABugReportAfterTheFix() throws {
        let names = try #require(SupermuxPromptNaming.names(
            from: "when i drag a tab between workspaces the app freezes for a few seconds"
        ))
        #expect(names.workspaceName == "Drag Tab Workspaces App Freezes")
        #expect(names.branchName.hasPrefix("fix-"))
        #expect(names.branchName == "fix-drag-tab-workspaces-app")
    }

    @Test func namesAFeatureRequestWithAddPrefix() throws {
        let names = try #require(SupermuxPromptNaming.names(
            from: "I want a dark mode toggle in the settings page"
        ))
        #expect(names.workspaceName == "Dark Mode Toggle Settings Page")
        #expect(names.branchName == "add-dark-mode-toggle-settings")
    }

    @Test func doesNotDoubleAnExistingPrefix() throws {
        let names = try #require(SupermuxPromptNaming.names(from: "Fix login redirect"))
        #expect(names.workspaceName == "Fix Login Redirect")
        #expect(names.branchName == "fix-login-redirect")
    }

    @Test func usesOnlyTheHeadlineLineAndFirstSentence() throws {
        let names = try #require(SupermuxPromptNaming.names(
            from: "Add retry to the uploader. It should back off exponentially\nand log each attempt."
        ))
        #expect(names.workspaceName == "Add Retry Uploader")
        #expect(names.branchName == "add-retry-uploader")
    }

    @Test func preservesIdentifierCasing() throws {
        let names = try #require(SupermuxPromptNaming.names(from: "migrate useEffect hooks to iOS 18 APIs"))
        #expect(names.workspaceName == "Migrate useEffect Hooks iOS 18")
    }

    @Test func returnsNilForFillerOnlyOrEmptyPrompts() {
        #expect(SupermuxPromptNaming.names(from: "") == nil)
        #expect(SupermuxPromptNaming.names(from: "please can you just do it") == nil)
        #expect(SupermuxPromptNaming.names(from: "!!! ???") == nil)
    }
}

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

    /// A short first sentence still ends the headline; only a colon-style
    /// label ("Bug: …") keeps the words after it.
    @Test func splitsAtAShortFirstSentenceButKeepsColonLabels() throws {
        let short = try #require(SupermuxPromptNaming.names(
            from: "Add retry. The uploader should back off exponentially and log each attempt."
        ))
        #expect(short.workspaceName == "Add Retry")
        #expect(short.branchName == "add-retry")

        let label = try #require(SupermuxPromptNaming.names(from: "Bug: login redirect loops"))
        #expect(label.workspaceName == "Bug Login Redirect Loops")
        #expect(label.branchName == "fix-bug-login-redirect-loops")

        let version = try #require(SupermuxPromptNaming.names(from: "Upgrade to v2.0 and fix login"))
        #expect(version.workspaceName == "Upgrade V2.0 Fix Login", "a dot inside a word is not a terminator")
    }

    /// Contractions stay whole (no stray "Don" / "T" words) and drop out as
    /// filler; the apostrophe never reaches the branch.
    @Test func keepsContractionsTogether() throws {
        let names = try #require(SupermuxPromptNaming.names(
            from: "Don't crash when the user’s token expires"
        ))
        #expect(names.workspaceName == "Crash User’s Token Expires")
        #expect(names.branchName == "fix-crash-users-token-expires")
    }

    /// The task type comes from the headline: details that mention an error
    /// do not turn a feature into a `fix-` branch.
    @Test func branchPrefixComesFromTheHeadlineNotTheDetails() throws {
        let names = try #require(SupermuxPromptNaming.names(
            from: "Add a retry button to the uploader\nRight now a failed upload shows an error and the user has to reload."
        ))
        #expect(names.workspaceName == "Add Retry Button Uploader")
        #expect(names.branchName == "add-retry-button-uploader")
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

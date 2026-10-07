import Foundation
import Testing
@testable import SupermuxKit

/// Tests the pull-request value's raw-value contract with cmux.
struct SupermuxPullRequestTests {
    // MARK: Status raw-value contract

    @Test func statusRawValuesBridgeWithCmux() {
        // The value bridges both cmux's `SidebarPullRequestStatus` and CmuxGit's
        // `PullRequestStatus` via `rawValue`; these strings are that contract.
        #expect(SupermuxPullRequest.Status.open.rawValue == "open")
        #expect(SupermuxPullRequest.Status.merged.rawValue == "merged")
        #expect(SupermuxPullRequest.Status.closed.rawValue == "closed")
        #expect(SupermuxPullRequest.Status(rawValue: "open") == .open)
        #expect(SupermuxPullRequest.Status(rawValue: "merged") == .merged)
        #expect(SupermuxPullRequest.Status(rawValue: "closed") == .closed)
        #expect(SupermuxPullRequest.Status(rawValue: "draft") == nil)
    }
}

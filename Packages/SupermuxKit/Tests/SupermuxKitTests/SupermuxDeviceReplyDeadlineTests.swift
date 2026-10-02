import Foundation
import Testing
@testable import SupermuxKit

/// Ways a Mac-to-Mac call's reply deadline could fail. A reply that misses its
/// deadline makes the device link reconnect, which drops every mirror of that
/// Mac, so each failure below is "the whole link flaps", not "one call fails":
///
/// 1. A Changes history page (the host runs `git fetch` first, then several
///    git reads) gets the link's 20 s default, so a slow fetch tears the link
///    down, and the reconnect refresh asks again (a flap loop).
/// 2. A commit (pre-commit hooks) or an AI commit message (a 30 s gateway
///    request after the diff capture) gets the 20 s default.
/// 3. Push or pull lose the long deadline they had.
/// 4. A worktree removal (teardown script plus `git worktree remove`) or a
///    worktree creation (`git worktree add`) gets a deadline shorter than the
///    host's own bounds for that work.
/// 5. A clone gets less than the host's clone timeout.
/// 6. A call the host answers from memory gets a long deadline, so a dead link
///    is noticed late.
/// 7. A method that is not a `mobile.supermux.*` call gets a fork deadline.
/// 8. A mirror's Files panel duplicates a multi-GB folder or trashes many
///    items over the link with the 20 s default, so a long copy drops every
///    mirror of that Mac while the copy keeps running there.
/// 9. Any other `files.*` call (a listing that stats a huge folder on a slow
///    volume, a read from a stalled disk) gets less than the host's own bound
///    on it, which is how long the host may take before it answers.
struct SupermuxDeviceReplyDeadlineTests {
    /// DeviceLinkRuntime's default reply deadline.
    private static let linkDefault: Duration = .seconds(20)
    /// The host's bound on one local git command.
    private static let git = SupermuxGitChangesService.gitTimeout
    /// The host AI gateway's request timeout (`SupermuxAIGatewayClient`).
    private static let aiRequest: TimeInterval = 30

    private func deadline(_ method: String) -> Duration? {
        SupermuxDeviceReplyDeadline.forMethod("mobile.supermux." + method)
    }

    private func outlasts(_ method: String, hostSeconds: TimeInterval) -> Bool {
        guard let deadline = deadline(method) else { return false }
        return deadline > Self.linkDefault && deadline > .seconds(hostSeconds)
    }

    @Test func aHistoryPageOutlastsTheHostFetchAndItsReads() {
        // fetch, then status, log, unpushed probe and incoming.
        #expect(outlasts("changes.history", hostSeconds: SupermuxGitChangesService.fetchTimeout + 4 * Self.git))
    }

    @Test func commitsAndAICommitMessagesOutlastHooksAndTheGateway() {
        // stage_all, commit (hooks run inside it), then read HEAD.
        #expect(outlasts("changes.commit", hostSeconds: 3 * Self.git))
        // Diff capture, then the gateway request.
        #expect(outlasts("changes.generate_commit_message", hostSeconds: 2 * Self.git + Self.aiRequest))
    }

    @Test func everyChangesCallThatRunsGitOutlastsOneGitCommand() {
        for method in ["status", "diff", "stage", "unstage", "discard", "stash", "stash_pop"] {
            #expect(outlasts("changes." + method, hostSeconds: 2 * Self.git), "\(method)")
        }
    }

    @Test func pushAndPullOutlastTheHostNetworkTimeout() {
        for method in ["changes.push", "changes.pull"] {
            // A status read, then the network command.
            #expect(outlasts(method, hostSeconds: SupermuxGitChangesService.networkTimeout + Self.git), "\(method)")
        }
    }

    @Test func worktreeCheckoutsAndRemovalsOutlastTheHostBounds() {
        let checkout = SupermuxGitWorktreeService.checkoutTimeout
        #expect(outlasts("worktree.create", hostSeconds: checkout + Self.aiRequest))
        #expect(outlasts("agent.start", hostSeconds: checkout + Self.aiRequest))
        #expect(outlasts("worktree.remove", hostSeconds: Self.git + SupermuxGitWorktreeService.teardownTimeout + checkout))
    }

    @Test func otherHostWorkOutlastsItsOwnBounds() {
        #expect(outlasts("project.clone", hostSeconds: SupermuxProjectSetupService.cloneTimeout))
        #expect(outlasts("worktrees.list", hostSeconds: 2 * Self.git))
        #expect(outlasts("worktree.suggest_branch", hostSeconds: Self.aiRequest))
        #expect(outlasts("project.create", hostSeconds: 3 * Self.git))
        #expect(outlasts("project.probe", hostSeconds: Self.git))
        // A cold Claude catalog probe (15 s) through the login shell.
        #expect(outlasts("agent.options", hostSeconds: 60))
    }

    @Test func duplicateAndTrashOutlastTheHostCopyBound() {
        for method in ["files.duplicate", "files.trash"] {
            #expect(outlasts(method, hostSeconds: SupermuxMobileFileBrowser.copyTimeout), "\(method)")
        }
    }

    @Test func everyOtherFileCallOutlastsTheHostBoundOnIt() {
        for method in ["files.list", "files.read", "files.create", "files.rename", "files.search"] {
            #expect(outlasts(method, hostSeconds: SupermuxMobileFileBrowser.operationTimeout), "\(method)")
        }
        // git_status waits for git within the call's own bound.
        #expect(outlasts("files.git_status", hostSeconds: SupermuxMobileFileBrowser.gitStatusTimeout))
    }

    @Test func callsTheHostAnswersFromMemoryKeepTheLinkDefault() {
        for method in [
            "projects.list", "project.icon", "project.open", "run.state", "run.start", "run.stop",
            "changes.watch", "files.watch", "ports.list", "action.run", "preset.launch", "workspace.select", "usage.state",
        ] {
            #expect(deadline(method) == nil, "\(method)")
        }
    }

    @Test func nonForkMethodsKeepTheLinkDefault() {
        for method in ["mobile.terminal.input", "workspace.create", "mobile.host.status", "mobile.supermux.nope"] {
            #expect(SupermuxDeviceReplyDeadline.forMethod(method) == nil, "\(method)")
        }
    }
}

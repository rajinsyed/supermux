import Foundation

/// The AI "Generate & Commit" flow for ``SupermuxChangesModel``.
///
/// Split out of `SupermuxChangesModel.swift` so the core model file stays
/// focused on status and working-tree mutations (and within the Swift
/// file-length budget).
extension SupermuxChangesModel {

    /// Whether the commit button is in AI mode: the message box is empty, AI is
    /// configured, and there is at least one change to commit.
    public var isAICommitMode: Bool {
        trimmedCommitMessage.isEmpty
            && aiCommitConfigured
            && snapshot.totalChangeCount > 0
    }

    /// Whether the commit button should be enabled. With a typed message it
    /// requires staged changes; with an empty message it requires AI mode.
    public var canCommit: Bool {
        guard !isWorking, snapshot.isRepository else { return false }
        if trimmedCommitMessage.isEmpty {
            return isAICommitMode
        }
        return !snapshot.staged.isEmpty
    }

    /// Localized title for the commit button, reflecting AI vs. normal mode.
    public var commitButtonTitle: String {
        isAICommitMode
            ? String(localized: "supermux.changes.ai.generateAndCommit", defaultValue: "Generate & Commit")
            : String(localized: "supermux.changes.commit", defaultValue: "Commit")
    }

    /// Commit entry point used by the button: a typed message commits staged
    /// changes directly; an empty message triggers the AI flow
    /// (``generateAndCommit()``).
    public func performCommit() async {
        if trimmedCommitMessage.isEmpty {
            await generateAndCommit()
        } else {
            await commit()
        }
    }

    private enum AICommitOutcome {
        case committed
        case failed(String)
    }

    /// Generates a commit message with AI, then stages everything and commits.
    ///
    /// Atomic by construction: the message is produced from a *non-mutating*
    /// diff (``SupermuxGitChangesService/uncommittedDiff(repoPath:)``), so a
    /// missing key, an offline gateway, or an empty diff returns without ever
    /// touching the index — `git add -A` runs only once a message is in hand.
    /// All network/git work happens in ``runAICommit(generator:directory:)``;
    /// the resulting state is applied only if the user has not switched
    /// workspaces during the (multi-second) AI call, so a slow commit's
    /// outcome never bleeds onto another workspace's panel.
    private func generateAndCommit() async {
        guard let commitGenerator, let directory, !isWorking,
              snapshot.totalChangeCount > 0 else { return }
        let generation = directoryGeneration
        isWorking = true
        defer { isWorking = false }
        // Drain any in-flight background fetch so the stage+commit git work never
        // races the silent fetch into a ref-lock error (see ``performMutation``).
        await drainActiveFetch()
        let outcome = await runAICommit(generator: commitGenerator, directory: directory)
        // Drop the result if the user switched the focused workspace mid-flight.
        guard generation == directoryGeneration else { return }
        switch outcome {
        case .committed:
            commitMessage = ""
            lastError = nil
        case .failed(let message):
            lastError = message
        }
        await refresh()
    }

    /// One point-in-time identity of everything `git add -A && git commit`
    /// would capture: the AI-facing diff, the untracked-content token the
    /// diff cannot carry (untracked files appear in it by name only), and the
    /// full-diff digest covering tracked edits past the diff's 64 KiB cap.
    private struct AIChangeCapture: Equatable {
        let diff: String
        let untrackedIdentity: String
        /// Identity of the FULL tracked diff (uncapped); consumed only via
        /// the `Equatable` compare — the model never sees its content.
        let fullDiffDigest: String
    }

    private func captureChanges(directory: String) async -> AIChangeCapture {
        // Independent read-only captures on the service actor; run them
        // concurrently to cut the staleness-guard latency.
        async let diff = service.uncommittedDiff(repoPath: directory)
        async let untrackedIdentity = service.untrackedContentDigest(repoPath: directory)
        async let fullDiffDigest = service.trackedDiffDigest(repoPath: directory)
        return await AIChangeCapture(
            diff: diff,
            untrackedIdentity: untrackedIdentity,
            fullDiffDigest: fullDiffDigest
        )
    }

    /// Runs the AI commit pipeline against `directory`, returning the outcome
    /// without mutating any observable model state (the caller applies it).
    ///
    /// Staleness guard: `git add -A` sweeps in whatever the working tree holds
    /// at commit time, so the change identity the message was generated from —
    /// the exact diff content plus the untracked-content token — is
    /// re-captured once the (multi-second) AI call returns and compared. (A
    /// status fingerprint of kinds+paths is not enough: an edit to an
    /// already-modified or untracked file changes no path or kind but would be
    /// committed under a message describing the older content.) On mismatch
    /// the message is regenerated ONCE from the fresh diff; if the tree shifts
    /// yet again the flow aborts without staging rather than committing blind.
    /// A residual millisecond-scale window remains between the final recheck
    /// and `git add -A` — irreducible for a "commit everything now" gesture;
    /// the guard narrows the described-vs-committed divergence from seconds
    /// to milliseconds.
    private func runAICommit(
        generator: any SupermuxAICommitMessaging,
        directory: String
    ) async -> AICommitOutcome {
        guard await generator.isConfigured() else {
            return .failed(SupermuxAIError.notConfigured.localizedDescription)
        }
        let capture = await captureChanges(directory: directory)
        switch await generateMessage(generator: generator, forDiff: capture.diff) {
        case .failed(let failure):
            return .failed(failure)
        case .generated(var message):
            let current = await captureChanges(directory: directory)
            if current != capture {
                switch await generateMessage(generator: generator, forDiff: current.diff) {
                case .failed(let failure):
                    return .failed(failure)
                case .generated(let regenerated):
                    message = regenerated
                }
                let recheck = await captureChanges(directory: directory)
                guard recheck == current else {
                    return .failed(String(
                        localized: "supermux.changes.ai.changesKeptShifting",
                        defaultValue: "Files kept changing while the message was generated. Nothing was committed — try again."
                    ))
                }
            }
            do {
                try await service.stageAll(repoPath: directory)
                try await service.commit(repoPath: directory, message: message)
                return .committed
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    private enum AIMessageResult {
        case generated(String)
        case failed(String)
    }

    /// Asks the generator for a message describing `diff`; failures map to the
    /// user-facing error strings.
    private func generateMessage(
        generator: any SupermuxAICommitMessaging,
        forDiff diff: String
    ) async -> AIMessageResult {
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(String(
                localized: "supermux.changes.ai.nothingToCommit",
                defaultValue: "Nothing to commit."
            ))
        }
        guard let message = await generator.generateMessage(forDiff: diff) else {
            return .failed(String(
                localized: "supermux.changes.ai.generateFailed",
                defaultValue: "Couldn’t generate a commit message. Check your AI settings."
            ))
        }
        return .generated(message)
    }
}

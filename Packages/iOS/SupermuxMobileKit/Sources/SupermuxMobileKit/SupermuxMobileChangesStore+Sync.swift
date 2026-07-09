public import SupermuxMobileCore

/// The commit / generate / push / pull / stash / history actions completing
/// ``SupermuxMobileChangesStore`` (m3-f2's wire shapes). State lives in the
/// main class; every mutation here shares the store's single `mutate()` gate
/// so exactly one round-trip is on the wire at a time.
extension SupermuxMobileChangesStore {
    // MARK: - Commit

    /// `mobile.supermux.changes.commit` with the trimmed composer draft.
    /// A blank draft is a no-op (the screen swaps in Generate & Commit
    /// instead). On success the sha surfaces in ``lastCommitShortSha``, the
    /// draft clears, the status refetches, and the history invalidates.
    /// - Parameter stageAll: Whether the Mac stages everything first.
    public func commit(stageAll: Bool = false) async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        lastCommitShortSha = nil
        await mutate {
            let response = try await self.client.changesCommit(SupermuxChangesCommitRequest(
                workspaceID: self.workspaceID,
                message: message,
                stageAll: stageAll
            ))
            self.lastCommitShortSha = response.sha.map { String($0.prefix(7)) }
            self.commitMessage = ""
            self.invalidateHistory()
        }
    }

    /// `changes.generate_commit_message` then `changes.commit` — the
    /// composer's one-tap flow when the draft is empty. The generated
    /// message lands in ``commitMessage`` first, so a failed commit leaves
    /// it editable. `ai_unavailable` surfaces the Mac's message on
    /// ``aiUnavailableNotice`` and commits nothing.
    /// - Parameter stageAll: Whether the Mac stages everything first.
    public func generateAndCommit(stageAll: Bool = false) async {
        guard !isGeneratingMessage, !isMutating else { return }
        isGeneratingMessage = true
        aiUnavailableNotice = nil
        var generated: String?
        do {
            let response = try await client.changesGenerateCommitMessage(
                SupermuxChangesGenerateCommitMessageRequest(workspaceID: workspaceID)
            )
            if let message = response.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                generated = message
            }
        } catch {
            surfaceGenerationFailure(error)
        }
        isGeneratingMessage = false
        guard let generated else { return }
        commitMessage = generated
        await commit(stageAll: stageAll)
    }

    private func surfaceGenerationFailure(_ error: any Error) {
        if SupermuxWireErrorCode.code(from: error) == SupermuxWireErrorCode.aiUnavailable {
            // Distinct Mac messages for no-key vs failed-generation — worth
            // surfacing verbatim under the screen's localized headline.
            aiUnavailableNotice = SupermuxWireErrorCode.message(from: error)
                ?? error.localizedDescription
        } else {
            lastErrorDescription = error.localizedDescription
        }
    }

    // MARK: - Push / pull / stash

    /// `mobile.supermux.changes.push` (extended RPC deadline — see
    /// ``SupermuxChangesSyncDeadline``).
    /// - Returns: The log entry for the result sheet, or `nil` on failure
    ///   (surfaced in ``lastErrorDescription``).
    public func push() async -> SupermuxChangesSyncLogEntry? {
        await performSync(.push) {
            try await self.client.changesPush(
                SupermuxChangesPushRequest(workspaceID: self.workspaceID)
            )
        }
    }

    /// `mobile.supermux.changes.pull` (extended RPC deadline — see
    /// ``SupermuxChangesSyncDeadline``).
    /// - Returns: The log entry for the result sheet, or `nil` on failure
    ///   (surfaced in ``lastErrorDescription``).
    public func pull() async -> SupermuxChangesSyncLogEntry? {
        await performSync(.pull) {
            try await self.client.changesPull(
                SupermuxChangesPullRequest(workspaceID: self.workspaceID)
            )
        }
    }

    /// `mobile.supermux.changes.stash`: stashes the working tree (tracked
    /// files; the desktop's plain "Stash Changes"). The refetched status
    /// carries the new `stash_count`.
    /// - Parameter message: Optional stash message.
    public func stash(message: String? = nil) async {
        await mutate {
            _ = try await self.client.changesStash(SupermuxChangesStashRequest(
                workspaceID: self.workspaceID,
                message: message
            ))
        }
    }

    /// `mobile.supermux.changes.stash_pop`: pops the latest stash entry.
    public func stashPop() async {
        await mutate {
            _ = try await self.client.changesStashPop(
                SupermuxChangesStashPopRequest(workspaceID: self.workspaceID)
            )
        }
    }

    /// One network-bound sync at a time through the shared mutation gate:
    /// send, refetch (ahead/behind moved), invalidate history (`is_pushed` /
    /// new commits shifted), and hand the log to the caller's result sheet.
    private func performSync(
        _ operation: SupermuxChangesSyncOperation,
        _ send: @MainActor () async throws -> SupermuxChangesSyncResponse
    ) async -> SupermuxChangesSyncLogEntry? {
        guard !isMutating else { return nil }
        isMutating = true
        activeSyncOperation = operation
        defer {
            isMutating = false
            activeSyncOperation = nil
        }
        do {
            let response = try await send()
            invalidateHistory()
            await refetchStatus()
            return SupermuxChangesSyncLogEntry(
                operation: operation,
                lines: response.logLines ?? [],
                truncated: response.logTruncated ?? false
            )
        } catch {
            lastErrorDescription = error.localizedDescription
            return nil
        }
    }

    // MARK: - History

    /// Loads the first history page unless fresh pages are already loaded
    /// (or a load is in flight). The screen calls this from a `.task` keyed
    /// on segment + ``SupermuxMobileChangesStore/historyEpoch``.
    public func loadHistoryIfNeeded() async {
        guard showsChanges, !hasLoadedHistory, !isLoadingHistory else { return }
        await fetchHistoryPage(cursor: nil)
    }

    /// Fetches the next page with the stored cursor and appends it. A no-op
    /// while loading, after the last page, or on stale (invalidated) pages.
    public func loadMoreHistory() async {
        guard hasLoadedHistory, !isLoadingHistory, let cursor = historyNextCursor else { return }
        await fetchHistoryPage(cursor: cursor)
    }

    /// Marks the loaded history pages stale (after commit/push/pull) and
    /// bumps ``SupermuxMobileChangesStore/historyEpoch`` so a visible
    /// History segment reloads itself.
    func invalidateHistory() {
        historyEpoch += 1
        hasLoadedHistory = false
    }

    private func fetchHistoryPage(cursor: String?) async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let response = try await client.changesHistory(SupermuxChangesHistoryRequest(
                workspaceID: workspaceID,
                cursor: cursor
            ))
            let page = response.commits ?? []
            if cursor == nil {
                historyCommits = page
                // Incoming rides the first page only (m3-f2).
                incomingCommits = response.incoming ?? []
            } else {
                historyCommits += page
            }
            historyNextCursor = response.nextCursor
            hasLoadedHistory = true
            historyErrorDescription = nil
        } catch {
            historyErrorDescription = error.localizedDescription
        }
    }
}

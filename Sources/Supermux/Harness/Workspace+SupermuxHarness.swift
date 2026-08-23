import Bonsplit
import CmuxWorkspaces
import Foundation

extension Workspace {
    @discardableResult
    func newSupermuxHarnessSurface(
        inPane paneId: PaneID,
        workingDirectory: String? = nil,
        restoreState: SessionSupermuxHarnessPanelSnapshot? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> SupermuxHarnessPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView
        let directory: String? = {
            if let workingDirectory { return workingDirectory }
            if let restored = restoreState?.workingDirectory { return restored }
            return usesRemoteDirectoryProvenance ? presentedCurrentDirectory : currentDirectory
        }()
        let focusedPanelUsesRemoteFallback = focusedPanelId.map {
            reportedPanelDirectory(panelId: $0) == nil && terminalPanel(for: $0) == nil
        } ?? true
        let trustsHarnessDirectory = workingDirectory == nil &&
            restoreState?.workingDirectory == nil &&
            (focusedPanelId.map { remoteDirectoryReportPanelIds.contains($0) } == true ||
                (usesRemoteDirectoryProvenance && focusedPanelUsesRemoteFallback && directory != nil))

        let harnessPanel = SupermuxHarnessPanel(
            workspaceId: id,
            workingDirectory: directory,
            restoreState: restoreState,
            sessionRepository: SupermuxComposition.harnessSessionRepository,
            transcriptService: SupermuxComposition.harnessSubagentTranscriptService
        )
        panels[harnessPanel.id] = harnessPanel
        panelTitles[harnessPanel.id] = harnessPanel.displayTitle
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[harnessPanel.id] = directory
        }

        guard let newTabId = bonsplitController.createTab(
            title: harnessPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(harnessPanel.displayIcon),
            iconAsset: harnessPanel.displayIconAsset,
            kind: SurfaceKind.claudeHarness.rawValue,
            isDirty: harnessPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: harnessPanel.id)
            panelTitles.removeValue(forKey: harnessPanel.id)
            panelDirectories.removeValue(forKey: harnessPanel.id)
            return nil
        }
        if trustsHarnessDirectory, let directory {
            _ = updateRemotePanelDirectory(panelId: harnessPanel.id, directory: directory)
        }

        bindSurface(newTabId, toPanelId: harnessPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            harnessPanel.id,
            paneId: paneId,
            kind: "claude_harness",
            origin: "claude_harness_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            harnessPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: harnessPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installSupermuxHarnessPanelSubscription(harnessPanel)
        scheduleSupermuxHarnessGitMetadataProbe(
            panelId: harnessPanel.id,
            reason: "harnessSurfaceCreate"
        )

        return harnessPanel
    }

    @discardableResult
    func splitPaneWithSupermuxHarness(
        targetPane paneId: PaneID,
        restoreState: SessionSupermuxHarnessPanelSnapshot,
        orientation: SplitOrientation = .horizontal,
        insertFirst: Bool = false
    ) -> SupermuxHarnessPanel? {
        let directory = restoreState.workingDirectory
            ?? (usesRemoteDirectoryProvenance ? presentedCurrentDirectory : currentDirectory)
        let sourcePanelId = bonsplitController.selectedTab(inPane: paneId)
            .flatMap { panelIdFromSurfaceId($0.id) }
        let sourcePanelUsesRemoteFallback = sourcePanelId.map {
            reportedPanelDirectory(panelId: $0) == nil && terminalPanel(for: $0) == nil
        } ?? true
        let sourceHasTrustedRemoteDirectory = sourcePanelId.map {
            remoteDirectoryReportPanelIds.contains($0)
        } == true
        let trustsHarnessDirectory = sourceHasTrustedRemoteDirectory ||
            (restoreState.workingDirectory == nil &&
                usesRemoteDirectoryProvenance && sourcePanelUsesRemoteFallback && directory != nil)
        let harnessPanel = SupermuxHarnessPanel(
            workspaceId: id,
            workingDirectory: directory,
            restoreState: restoreState,
            sessionRepository: SupermuxComposition.harnessSessionRepository,
            transcriptService: SupermuxComposition.harnessSubagentTranscriptService
        )
        panels[harnessPanel.id] = harnessPanel
        panelTitles[harnessPanel.id] = harnessPanel.displayTitle
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[harnessPanel.id] = directory
        }

        let newTab = Bonsplit.Tab(
            title: harnessPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(harnessPanel.displayIcon),
            iconAsset: harnessPanel.displayIconAsset,
            kind: SurfaceKind.claudeHarness.rawValue,
            isDirty: harnessPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: harnessPanel.id)
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            panels.removeValue(forKey: harnessPanel.id)
            panelTitles.removeValue(forKey: harnessPanel.id)
            panelDirectories.removeValue(forKey: harnessPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        if trustsHarnessDirectory, let directory {
            _ = updateRemotePanelDirectory(panelId: harnessPanel.id, directory: directory)
        }
        suppressReparentFocusUntilLayoutFollowUp(
            previousHostedView,
            reason: "workspace.supermuxHarnessSplitReparent"
        )
        focusPanel(harnessPanel.id, previousHostedView: previousHostedView)
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: orientation,
            surfaceId: harnessPanel.id,
            kind: "claude_harness",
            origin: "claude_harness_session_split",
            focused: true
        )
        installSupermuxHarnessPanelSubscription(harnessPanel)
        scheduleSupermuxHarnessGitMetadataProbe(
            panelId: harnessPanel.id,
            reason: "harnessSplitCreate"
        )
        return harnessPanel
    }

    /// Item 9: a harness pane must contribute a branch to the workspace tab.
    ///
    /// The sidebar/tab branch chip is derived from `panelGitBranches` (see
    /// `Workspace+SidebarDirectories.sidebarGitBranchesInDisplayOrder` and the
    /// fork's `supermuxSidebarBranch`), which upstream only ever populates from
    /// the sidebar git probe. That probe is scheduled solely from terminal
    /// surface creation/respawn sites, and `SidebarGitMetadataService` further
    /// gates its periodic re-watch on `host.hasTerminalPanel(...)`. A workspace
    /// whose ONLY pane is a harness pane therefore never gets a probe scheduled
    /// and shows no branch.
    ///
    /// The harness pane already knows its project/worktree path (it spawns the
    /// Claude CLI with that cwd, and the path is mirrored into
    /// `panelDirectories`, which is exactly what `TabManager.gitProbeDirectory`
    /// reads). So the fix is to schedule the SAME probe upstream schedules for a
    /// terminal — no new branch-resolution code, no shelling out. Terminal panes
    /// keep their existing scheduling untouched.
    func scheduleSupermuxHarnessGitMetadataProbe(panelId: UUID, reason: String) {
        guard panels[panelId] is SupermuxHarnessPanel else { return }
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id)
        manager?.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: id,
            panelId: panelId,
            reason: reason
        )
    }

    /// Re-arms the probe for every harness pane in this workspace.
    ///
    /// Session restore rebuilds panels before the workspace is attached to its
    /// `TabManager`, and upstream's post-restore sweep walks only
    /// `TerminalPanel`s, so a restored harness-only workspace would come back
    /// branchless until some unrelated event scheduled a probe.
    func scheduleSupermuxHarnessGitMetadataProbes(reason: String) {
        for panelId in panels.keys where panels[panelId] is SupermuxHarnessPanel {
            scheduleSupermuxHarnessGitMetadataProbe(panelId: panelId, reason: reason)
        }
    }

    func installSupermuxHarnessPanelSubscription(_ harnessPanel: SupermuxHarnessPanel) {
        harnessPanel.onAgentLifecycleChanged = { [weak self, weak harnessPanel] lifecycle in
            guard let self, let harnessPanel else { return }
            // Same key + lifecycle store terminal Claude Code tabs use, so the
            // sidebar and tab indicators (working spinner / needs-input dot /
            // ready dot) render identically for the harness pane.
            switch lifecycle {
            case .running:
                self.setAgentLifecycle(key: "claude_code", panelId: harnessPanel.id, lifecycle: .running)
            case .needsInput:
                self.setAgentLifecycle(key: "claude_code", panelId: harnessPanel.id, lifecycle: .needsInput)
            case .idle:
                // Idle renders as the green ready-for-review dot, which is only
                // meaningful after a turn actually ran. A fresh pane's initial
                // idle emission must not paint one.
                guard self.agentLifecycleStatesByPanelId[harnessPanel.id]?["claude_code"] != nil else { return }
                self.setAgentLifecycle(key: "claude_code", panelId: harnessPanel.id, lifecycle: .idle)
            }
        }
        harnessPanel.onDisplayStateChanged = { [weak self, weak harnessPanel] newTitle, displayIcon, isDirty in
            guard let self,
                  let harnessPanel,
                  let tabId = self.surfaceIdFromPanelId(harnessPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            if self.panelTitles[harnessPanel.id] != newTitle {
                self.panelTitles[harnessPanel.id] = newTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(panelId: harnessPanel.id, fallback: newTitle)
            let resolvedIcon = RenderableSystemSymbol.resolvedSurfaceTabIcon(displayIcon)
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let iconUpdate: String?? = existing.icon == resolvedIcon ? nil : .some(resolvedIcon)
            let dirtyUpdate: Bool? = existing.isDirty == isDirty ? nil : isDirty
            guard titleUpdate != nil || iconUpdate != nil || dirtyUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                icon: iconUpdate,
                hasCustomTitle: self.panelCustomTitles[harnessPanel.id] != nil,
                isDirty: dirtyUpdate
            )
        }
    }

    func discardSupermuxHarnessPanelSubscription(panelId: UUID, panel: (any Panel)?) {
        guard let harnessPanel = panel as? SupermuxHarnessPanel else { return }
        harnessPanel.onDisplayStateChanged = nil
        harnessPanel.onAgentLifecycleChanged = nil
        _ = clearAgentLifecycle(key: "claude_code", panelId: panelId)
    }

    func restoreSupermuxHarnessPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        restoresSavedDirectory: Bool = true
    ) -> UUID? {
        guard var harnessState = snapshot.claudeHarness else { return nil }
        let savedDirectory = harnessState.workingDirectory ?? snapshot.directory
        if !restoresSavedDirectory {
            harnessState.workingDirectory = nil
        }
        guard let harnessPanel = newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: restoresSavedDirectory ? savedDirectory : nil,
            restoreState: harnessState,
            focus: false
        ) else {
            return nil
        }
        applySessionPanelMetadata(snapshot, toPanelId: harnessPanel.id)
        return harnessPanel.id
    }

    func supermuxHarnessSessionSnapshot(for panel: any Panel) -> SessionSupermuxHarnessPanelSnapshot? {
        guard let harnessPanel = panel as? SupermuxHarnessPanel else { return nil }
        return harnessPanel.currentSnapshot
    }
}

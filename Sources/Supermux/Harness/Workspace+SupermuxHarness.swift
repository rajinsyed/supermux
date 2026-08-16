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

        let harnessPanel = SupermuxHarnessPanel(
            workspaceId: id,
            workingDirectory: directory,
            restoreState: restoreState
        )
        panels[harnessPanel.id] = harnessPanel
        panelTitles[harnessPanel.id] = harnessPanel.displayTitle
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[harnessPanel.id] = directory
        }

        guard let newTabId = bonsplitController.createTab(
            title: harnessPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(harnessPanel.displayIcon),
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

        return harnessPanel
    }

    func installSupermuxHarnessPanelSubscription(_ harnessPanel: SupermuxHarnessPanel) {
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
        _ = panelId
        guard let harnessPanel = panel as? SupermuxHarnessPanel else { return }
        harnessPanel.onDisplayStateChanged = nil
    }

    func restoreSupermuxHarnessPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        guard let harnessState = snapshot.claudeHarness else { return nil }
        guard let harnessPanel = newSupermuxHarnessSurface(
            inPane: paneId,
            workingDirectory: harnessState.workingDirectory ?? snapshot.directory,
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

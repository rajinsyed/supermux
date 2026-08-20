import AppKit
import Foundation
import SupermuxKit

@MainActor
final class SupermuxHarnessPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .claudeHarness
    private(set) var workspaceId: UUID
    private(set) var workingDirectory: String?
    private(set) var restoreState: SessionSupermuxHarnessPanelSnapshot?
    let rendererSession: SupermuxHarnessWebRendererSession

    private(set) var displayTitle: String
    private(set) var isDirty: Bool = false
    private(set) var needsUserInput: Bool = false
    /// The Claude brand mark, same asset the terminal's Claude Code tabs use.
    let displayIconAsset = "AgentIcons/Claude"
    var displayIcon: String? {
        isDirty ? "sparkle" : "sparkles"
    }

    var onDisplayStateChanged: ((String, String?, Bool) -> Void)? {
        didSet {
            onDisplayStateChanged?(displayTitle, displayIcon, isDirty)
        }
    }

    /// Mirrors the agent lifecycle terminal tabs report (`running`/`needsInput`/
    /// `idle`) so the workspace can feed the shared status-indicator machinery.
    var onAgentLifecycleChanged: ((SupermuxHarnessAgentLifecycle) -> Void)? {
        didSet {
            onAgentLifecycleChanged?(agentLifecycle)
        }
    }

    var agentLifecycle: SupermuxHarnessAgentLifecycle {
        if needsUserInput { return .needsInput }
        return isDirty ? .running : .idle
    }

    init(
        workspaceId: UUID,
        workingDirectory: String? = nil,
        restoreState: SessionSupermuxHarnessPanelSnapshot? = nil,
        sessionRepository: any SupermuxHarnessSessionReading,
        transcriptService: any SupermuxHarnessSubagentTranscriptLoading
    ) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.workingDirectory = workingDirectory
        self.restoreState = restoreState
        rendererSession = SupermuxHarnessWebRendererSession(
            sessionRepository: sessionRepository,
            transcriptService: transcriptService
        )
        let restoredTitle = restoreState?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayTitle = (restoredTitle?.isEmpty == false ? restoredTitle : nil) ?? Self.defaultTitle
        self.rendererSession.onSessionStateChanged = { [weak self] isRunning in
            self?.setRunning(isRunning)
        }
        self.rendererSession.onSessionTitleChanged = { [weak self] title in
            self?.setSessionTitle(title)
        }
        self.rendererSession.onPendingUserInputChanged = { [weak self] needsInput in
            self?.setNeedsUserInput(needsInput)
        }
        self.rendererSession.onRestoreStateRetired = { [weak self] in
            self?.retireRestoreState()
        }
    }

    nonisolated static var defaultTitle: String {
        String(localized: "supermux.harness.panel.title", defaultValue: "Claude")
    }

    var currentSnapshot: SessionSupermuxHarnessPanelSnapshot {
        var snapshot = rendererSession.persistedSnapshot
        if snapshot.workingDirectory == nil {
            snapshot.workingDirectory = workingDirectory
        }
        if snapshot.title == nil, displayTitle != Self.defaultTitle {
            snapshot.title = displayTitle
        }
        if snapshot.sessionId == nil {
            snapshot.sessionId = restoreState?.sessionId
        }
        if snapshot.model == nil {
            snapshot.model = restoreState?.model
        }
        if snapshot.permissionMode == nil {
            snapshot.permissionMode = restoreState?.permissionMode
                ?? SessionSupermuxHarnessPanelSnapshot.defaultPermissionMode
        }
        return snapshot
    }

    func focus() {
        rendererSession.focus()
    }

    func unfocus() {
        rendererSession.unfocus()
    }

    func close() {
        rendererSession.close()
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
    }

    func retireRestoreState() {
        restoreState = nil
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func setRunning(_ isRunning: Bool) {
        guard isDirty != isRunning else { return }
        isDirty = isRunning
        emitDisplayStateChanged()
        onAgentLifecycleChanged?(agentLifecycle)
    }

    private func setNeedsUserInput(_ needsInput: Bool) {
        guard needsUserInput != needsInput else { return }
        needsUserInput = needsInput
        onAgentLifecycleChanged?(agentLifecycle)
    }

    private func setSessionTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (trimmed?.isEmpty == false ? trimmed : nil) ?? Self.defaultTitle
        guard displayTitle != resolved else { return }
        displayTitle = resolved
        emitDisplayStateChanged()
    }

    private func emitDisplayStateChanged() {
        onDisplayStateChanged?(displayTitle, displayIcon, isDirty)
    }
}

/// The harness pane's contribution to the shared agent status indicator,
/// matching the states terminal Claude Code tabs report.
enum SupermuxHarnessAgentLifecycle {
    case idle
    case running
    case needsInput
}

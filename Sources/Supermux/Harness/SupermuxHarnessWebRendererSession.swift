import Foundation
import SupermuxKit

@MainActor
final class SupermuxHarnessWebRendererSession {
    private let ownedCoordinator: SupermuxHarnessWebRendererCoordinator

    init(transcriptService: any SupermuxHarnessSubagentTranscriptLoading) {
        ownedCoordinator = SupermuxHarnessWebRendererCoordinator(
            transcriptService: transcriptService
        )
    }
    var onSessionStateChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onSessionStateChanged = onSessionStateChanged
        }
    }
    var onSessionTitleChanged: ((String?) -> Void)? {
        didSet {
            ownedCoordinator.onSessionTitleChanged = onSessionTitleChanged
        }
    }
    var onPendingUserInputChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onPendingUserInputChanged = onPendingUserInputChanged
        }
    }
    var onRestoreStateRetired: (() -> Void)? {
        didSet {
            ownedCoordinator.onRestoreStateRetired = onRestoreStateRetired
        }
    }

    var persistedSnapshot: SessionSupermuxHarnessPanelSnapshot {
        ownedCoordinator.persistedSnapshot
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        workingDirectory: String?,
        restoreState: SessionSupermuxHarnessPanelSnapshot?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> SupermuxHarnessWebRendererCoordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            workingDirectory: workingDirectory,
            restoreState: restoreState,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
    }

    func close() {
        ownedCoordinator.close()
    }
}

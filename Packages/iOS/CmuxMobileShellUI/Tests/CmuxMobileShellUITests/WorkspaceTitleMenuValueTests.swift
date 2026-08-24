import CMUXMobileCore
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceTitleMenuValueTests {
    @Test func labelBranchChangesInvalidateTheMenuValue() {
        let standard = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal")
        )
        let browser = menuValue(
            labelToken: .browser(title: "Workspace")
        )
        #expect(menuValue(labelToken: standard.labelToken) == standard)
        #expect(browser != standard)
    }

    @Test func customizationCapabilityInvalidatesTheMenuValue() {
        let available = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal"),
            canCustomizeWorkspace: true
        )
        let unavailable = menuValue(
            labelToken: available.labelToken,
            canCustomizeWorkspace: false
        )

        #expect(available != unavailable)
    }

    @Test func forkMenuFingerprintInvalidatesTheMenuValue() {
        let stopped = menuValue(
            labelToken: .standard(title: "Workspace", subtitle: "Terminal"),
            toolEntriesFingerprint: "run:false|close:true"
        )
        let running = menuValue(
            labelToken: stopped.labelToken,
            toolEntriesFingerprint: "run:true|close:true"
        )

        #expect(stopped != running)
    }

    private func menuValue(
        labelToken: WorkspaceTitleMenuLabelToken,
        canCustomizeWorkspace: Bool = true,
        toolEntriesFingerprint: String = ""
    ) -> WorkspaceTitleMenuValue {
        WorkspaceTitleMenuValue(
            contentWidth: 390,
            hasBackButton: true,
            hasTrailingCluster: true,
            measuredTrailingItemsWidth: 0,
            measuredTrailingItemCount: 0,
            trailingItemCount: 0,
            isEnabled: true,
            workspaceName: "Workspace",
            hasUnread: false,
            canCustomizeWorkspace: canCustomizeWorkspace,
            canRenameWorkspace: true,
            canToggleReadState: true,
            canCloseWorkspace: true,
            toolEntriesFingerprint: toolEntriesFingerprint,
            labelToken: labelToken,
            terminalTheme: .monokai
        )
    }
}

// SUPERMUX:begin supermux-mobile-selection-sync
import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct SupermuxSelectionSyncTests {
    @Test func advertisedV2FollowsMacBrowserFocus() {
        let store = makeStore()
        store.supportedHostCapabilities = ["supermux.selection_sync.v2"]

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-b",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": browserPanel("browser-b1"),
            ]
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-b")
        #expect(store.selectedWorkspaceFocusedPanel == browserPanel("browser-b1"))
    }

    @Test func advertisedV2FollowsMacSimulatorFocus() {
        let store = makeStore()
        store.supportedHostCapabilities = ["supermux.selection_sync.v2"]

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-b",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": simulatorPanel("simulator-b1"),
            ]
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-b")
        #expect(store.selectedWorkspaceFocusedPanel == simulatorPanel("simulator-b1"))
    }

    @Test func advertisedV1StillFollowsMacTerminalFocus() {
        let store = makeStore()
        store.supportedHostCapabilities = ["supermux.selection_sync.v1"]

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-b",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": terminalPanel("terminal-b2"),
            ],
            includeGenericFocusedPanel: false
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-b")
        #expect(store.selectedTerminalID?.rawValue == "terminal-b2")
        #expect(store.selectedWorkspaceFocusedPanel == terminalPanel("terminal-b2"))
    }

    @Test func upstreamMacKeepsExistingPhoneLocalSelectionBehavior() {
        let store = makeStore()

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-b",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": browserPanel("browser-b1"),
            ]
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-a")
        #expect(store.selectedTerminalID?.rawValue == "terminal-a1")
        #expect(store.selectedWorkspaceFocusedPanel == terminalPanel("terminal-a1"))
    }

    @Test func pendingPhoneBrowserSelectionRejectsStaleMacStateUntilConfirmed() {
        let store = makeStore()
        store.supportedHostCapabilities = ["supermux.selection_sync.v2"]
        store.setSelectedWorkspaceID("workspace-b")
        store.selectedWorkspaceFocusedPanel = browserPanel("browser-b1")
        store.pendingSupermuxSelectionSyncIntent = SupermuxMobileSelectionSyncIntent(
            requestID: UUID(),
            workspaceID: "workspace-b",
            focusedPanel: browserPanel("browser-b1")
        )

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-a",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": terminalPanel("terminal-b1"),
            ]
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-b")
        #expect(store.selectedWorkspaceFocusedPanel == browserPanel("browser-b1"))
        #expect(store.pendingSupermuxSelectionSyncIntent != nil)

        store.applyRemoteWorkspaceList(response(
            selectedWorkspaceID: "workspace-b",
            focusedPanelByWorkspaceID: [
                "workspace-a": terminalPanel("terminal-a1"),
                "workspace-b": browserPanel("browser-b1"),
            ]
        ))

        #expect(store.selectedWorkspaceID?.rawValue == "workspace-b")
        #expect(store.selectedWorkspaceFocusedPanel == browserPanel("browser-b1"))
        #expect(store.pendingSupermuxSelectionSyncIntent == nil)
    }

    private func makeStore() -> MobileShellComposite {
        let store = MobileShellComposite(workspaces: [
            previewWorkspace(
                id: "workspace-a",
                terminalIDs: ["terminal-a1", "terminal-a2"],
                focusedPanel: terminalPanel("terminal-a1")
            ),
            previewWorkspace(
                id: "workspace-b",
                terminalIDs: ["terminal-b1", "terminal-b2"],
                focusedPanel: terminalPanel("terminal-b1")
            ),
        ])
        store.setSelectedWorkspaceID("workspace-a")
        store.selectedTerminalID = "terminal-a1"
        return store
    }

    private func previewWorkspace(
        id: String,
        terminalIDs: [String],
        focusedPanel: MobileWorkspaceFocusedPanel
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            focusedPanel: focusedPanel,
            terminals: terminalIDs.map { terminalID in
                MobileTerminalPreview(
                    id: .init(rawValue: terminalID),
                    name: terminalID,
                    isFocused: focusedPanel.kind == MobileWorkspaceFocusedPanel.terminalKind
                        && terminalID == focusedPanel.panelID
                )
            },
            simulators: [simulatorDescriptor(workspaceID: id)]
        )
    }

    private func response(
        selectedWorkspaceID: String,
        focusedPanelByWorkspaceID: [String: MobileWorkspaceFocusedPanel],
        includeGenericFocusedPanel: Bool = true
    ) -> MobileSyncWorkspaceListResponse {
        MobileSyncWorkspaceListResponse(
            workspaces: [
                responseWorkspace(
                    id: "workspace-a",
                    terminalIDs: ["terminal-a1", "terminal-a2"],
                    isSelected: selectedWorkspaceID == "workspace-a",
                    focusedPanel: focusedPanelByWorkspaceID["workspace-a"],
                    includeGenericFocusedPanel: includeGenericFocusedPanel
                ),
                responseWorkspace(
                    id: "workspace-b",
                    terminalIDs: ["terminal-b1", "terminal-b2"],
                    isSelected: selectedWorkspaceID == "workspace-b",
                    focusedPanel: focusedPanelByWorkspaceID["workspace-b"],
                    includeGenericFocusedPanel: includeGenericFocusedPanel
                ),
            ],
            groups: [],
            createdWorkspaceID: nil,
            createdTerminalID: nil
        )
    }

    private func responseWorkspace(
        id: String,
        terminalIDs: [String],
        isSelected: Bool,
        focusedPanel: MobileWorkspaceFocusedPanel?,
        includeGenericFocusedPanel: Bool
    ) -> MobileSyncWorkspaceListResponse.Workspace {
        MobileSyncWorkspaceListResponse.Workspace(
            id: id,
            windowID: nil,
            title: id,
            currentDirectory: nil,
            isSelected: isSelected,
            focusedPanel: includeGenericFocusedPanel ? focusedPanel : nil,
            isPinned: false,
            groupID: nil,
            preview: nil,
            previewAt: nil,
            lastActivityAt: nil,
            hasUnread: false,
            terminals: terminalIDs.map { terminalID in
                MobileSyncWorkspaceListResponse.Terminal(
                    id: terminalID,
                    title: terminalID,
                    currentDirectory: nil,
                    isFocused: focusedPanel?.kind == MobileWorkspaceFocusedPanel.terminalKind
                        && terminalID == focusedPanel?.panelID,
                    isReady: true
                )
            },
            simulators: [simulatorDescriptor(workspaceID: id)]
        )
    }

    private func simulatorDescriptor(workspaceID: String) -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: "simulator-b1",
            workspaceID: workspaceID,
            title: "Simulator",
            selectedDeviceName: "iPhone 17 Pro",
            selectedDeviceState: "Booted",
            status: "streaming",
            isReady: true,
            supportsTouch: true,
            supportsKeyboard: true,
            supportsHardwareButtons: true,
            supportsRotation: true
        )
    }

    private func terminalPanel(_ id: String) -> MobileWorkspaceFocusedPanel {
        MobileWorkspaceFocusedPanel(
            panelID: id,
            kind: MobileWorkspaceFocusedPanel.terminalKind
        )
    }

    private func browserPanel(_ id: String) -> MobileWorkspaceFocusedPanel {
        MobileWorkspaceFocusedPanel(
            panelID: id,
            kind: MobileWorkspaceFocusedPanel.browserKind
        )
    }

    private func simulatorPanel(_ id: String) -> MobileWorkspaceFocusedPanel {
        MobileWorkspaceFocusedPanel(
            panelID: id,
            kind: MobileWorkspaceFocusedPanel.simulatorKind
        )
    }
}
// SUPERMUX:end supermux-mobile-selection-sync

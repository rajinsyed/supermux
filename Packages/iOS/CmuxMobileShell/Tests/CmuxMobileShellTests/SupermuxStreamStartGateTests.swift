// SUPERMUX:begin supermux-mobile-selection-sync
import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct SupermuxStreamStartGateTests {
    @Test func browserStartRequiresActivePhoneSurfaceAndReadyMacFocus() {
        let browserStore = BrowserStreamStore()
        browserStore.browserPanelCreated(Self.browserDescriptor())
        let composite = MobileShellComposite(
            workspaces: [Self.workspace()],
            browserStreamEvents: browserStore
        )
        composite.supportedHostCapabilities = ["supermux.selection_sync.v2"]
        composite.setSelectedWorkspaceID("workspace-main")
        composite.selectedWorkspaceFocusedPanel = Self.browserPanel

        #expect(!composite.supermuxAllowsBrowserStreamStart(panelID: "browser-1"))

        _ = browserStore.activate(panelID: "browser-1", in: "workspace-main")
        #expect(!composite.supermuxAllowsBrowserStreamStart(panelID: "browser-1"))

        composite.supermuxStreamFocusReadiness = SupermuxMobileStreamFocusReadiness(
            workspaceID: "workspace-main",
            focusedPanel: Self.browserPanel
        )
        #expect(composite.supermuxAllowsBrowserStreamStart(panelID: "browser-1"))

        browserStore.deactivate(in: "workspace-main")
        #expect(!composite.supermuxAllowsBrowserStreamStart(panelID: "browser-1"))
    }

    @Test func simulatorStartRequiresActivePhoneSurfaceAndReadyMacFocus() {
        let simulatorStore = MobileSimulatorStreamStore()
        simulatorStore.replaceSimulatorPanels(
            in: "workspace-main",
            with: [Self.simulatorDescriptor()]
        )
        let composite = MobileShellComposite(
            workspaces: [Self.workspace()],
            simulatorStreamStore: simulatorStore
        )
        composite.supportedHostCapabilities = ["supermux.selection_sync.v2"]
        composite.setSelectedWorkspaceID("workspace-main")
        composite.selectedWorkspaceFocusedPanel = Self.simulatorPanel

        #expect(!composite.supermuxAllowsSimulatorStreamStart(
            panelID: "simulator-1",
            workspaceID: "workspace-main"
        ))

        _ = simulatorStore.activate(panelID: "simulator-1", in: "workspace-main")
        composite.supermuxStreamFocusReadiness = SupermuxMobileStreamFocusReadiness(
            workspaceID: "workspace-main",
            focusedPanel: Self.simulatorPanel
        )
        #expect(composite.supermuxAllowsSimulatorStreamStart(
            panelID: "simulator-1",
            workspaceID: "workspace-main"
        ))

        simulatorStore.deactivate(panelID: "simulator-1", in: "workspace-main")
        #expect(!composite.supermuxAllowsSimulatorStreamStart(
            panelID: "simulator-1",
            workspaceID: "workspace-main"
        ))
    }

    private static let browserPanel = MobileWorkspaceFocusedPanel(
        panelID: "browser-1",
        kind: MobileWorkspaceFocusedPanel.browserKind
    )

    private static let simulatorPanel = MobileWorkspaceFocusedPanel(
        panelID: "simulator-1",
        kind: MobileWorkspaceFocusedPanel.simulatorKind
    )

    private static func workspace() -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "Workspace",
            terminals: []
        )
    }

    private static func browserDescriptor() -> MobileBrowserPanelDescriptor {
        MobileBrowserPanelDescriptor(
            panelID: "browser-1",
            workspaceID: "workspace-main",
            url: nil,
            title: "Browser",
            pageWidth: 800,
            pageHeight: 600,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
    }

    private static func simulatorDescriptor() -> MobileSimulatorPanelDescriptor {
        MobileSimulatorPanelDescriptor(
            panelID: "simulator-1",
            workspaceID: "workspace-main",
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
}
// SUPERMUX:end supermux-mobile-selection-sync

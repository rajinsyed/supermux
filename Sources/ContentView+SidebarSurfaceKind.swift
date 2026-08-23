import CmuxExtensionKit

extension VerticalTabsSidebar {
    func cmuxSidebarSurfaceKind(for panelType: PanelType) -> CmuxSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar, .simulator, .extensionBrowser, .workspaceTodo, .notifications, .cloudVMLoading,
             .mobilePairing, .accountSignIn:
            return .unknown
        // SUPERMUX:begin claude-harness-sidebar-kind
        case .claudeHarness:
            return .unknown
        // SUPERMUX:end claude-harness-sidebar-kind
        case .agentSession:
            return .agentSession
        case .project:
            return .project
        }
    }
}

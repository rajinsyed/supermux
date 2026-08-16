import AppKit
import SwiftUI
import WebKit

struct SupermuxHarnessWebRenderer: NSViewRepresentable {
    let panel: SupermuxHarnessPanel
    let isFocused: Bool
    let backgroundColor: NSColor
    let theme: AgentSessionWebTheme
    let sessionContentWidthPresentation: SessionContentWidthPresentation
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> SupermuxHarnessWebRendererCoordinator {
        panel.rendererSession.coordinator(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            workingDirectory: panel.workingDirectory,
            restoreState: panel.restoreState,
            theme: theme,
            isFocused: isFocused
        )
    }

    func makeNSView(context: Context) -> NSView {
        let host = SupermuxHarnessWebHostView()
        host.wantsLayer = true
        applyBackground(to: host)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? SupermuxHarnessWebHostView else { return }
        context.coordinator.bind(
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            workingDirectory: panel.workingDirectory,
            restoreState: panel.restoreState,
            theme: theme,
            isFocused: isFocused
        )
        let webView = context.coordinator.ensureWebView(onPointerDown: onRequestPanelFocus)
        webView.onPointerDown = onRequestPanelFocus
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        applyBackground(to: host)
        applyBackground(to: webView)
        applyAppearance(to: webView)
        host.setSessionContentWidthPresentation(sessionContentWidthPresentation)
        host.attachWebView(webView)
        host.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.loadShellIfNeeded()
            coordinator?.flushVisiblePaintIfReady()
        }
        host.onGeometryChanged = { [weak coordinator = context.coordinator] in
            coordinator?.flushVisiblePaintIfReady()
        }
        context.coordinator.loadShellIfNeeded()
        context.coordinator.flushVisiblePaintIfReady()
        if isFocused {
            context.coordinator.focus()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: SupermuxHarnessWebRendererCoordinator) {
        if let host = nsView as? SupermuxHarnessWebHostView {
            host.detachHostedWebViewIfOwned(coordinator.webView)
            host.onDidMoveToWindow = nil
            host.onGeometryChanged = nil
        }
    }

    private func applyBackground(to host: NSView) {
        host.wantsLayer = true
        host.layer?.backgroundColor = backgroundColor.cgColor
        host.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func applyAppearance(to webView: WKWebView) {
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }
}

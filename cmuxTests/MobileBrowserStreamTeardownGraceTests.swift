// SUPERMUX:begin mac-browser-stream-teardown-grace
import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Rapid phone-side panel switching stops and restarts the Mac browser
/// stream in quick succession. Each teardown used to reparent the live
/// WKWebView and close its WebKit-hosting window immediately, amplifying a
/// WebKit layer-tree commit crash on macOS 26/27 betas. These tests pin the
/// grace behavior: a stop parks the render host, a restart inside the grace
/// reuses it, expiry tears it down, and panel close skips the grace.
@MainActor
@Suite("Mobile browser stream teardown grace", .serialized)
struct MobileBrowserStreamTeardownGraceTests {
    @Test("A stopped stream parks the render host and a restart reuses it")
    func rapidRestartReusesParkedRenderHost() throws {
        let panel = try makeStreamingPanel()
        defer { panel.close() }
        let host = try #require(panel.mobileBrowserStreamRenderHost)

        panel.removeMobileBrowserStreamSignalHandler(id: Self.handlerID)

        // Parked, not torn down: the WKWebView stays in the offscreen host.
        #expect(panel.mobileBrowserStreamRenderHost === host)
        #expect(panel.mobileBrowserStreamViewportTeardownTask != nil)

        let restartID = UUID()
        panel.addMobileBrowserStreamSignalHandler(id: restartID) { _ in }

        // The restart cancels the pending teardown and keeps the same host.
        #expect(panel.mobileBrowserStreamViewportTeardownTask == nil)
        #expect(panel.mobileBrowserStreamRenderHost === host)
        #expect(panel.applyMobileStreamViewport(width: 390, height: 700, scale: 3.0))
        #expect(panel.mobileBrowserStreamRenderHost === host)

        panel.removeMobileBrowserStreamSignalHandler(id: restartID)
    }

    @Test("Grace expiry with no restart tears the render host down")
    func graceExpiryTearsDownRenderHost() async throws {
        let panel = try makeStreamingPanel(grace: 0.05)
        defer { panel.close() }
        #expect(panel.mobileBrowserStreamRenderHost != nil)

        panel.removeMobileBrowserStreamSignalHandler(id: Self.handlerID)
        #expect(panel.mobileBrowserStreamRenderHost != nil)

        let deadline = Date().addingTimeInterval(2.0)
        while panel.mobileBrowserStreamRenderHost != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(panel.mobileBrowserStreamRenderHost == nil)
        #expect(panel.mobileBrowserStreamViewportTeardownTask == nil)
        #expect(panel.mobileBrowserStreamViewport == nil)
    }

    @Test("A web-view replacement during grace restores the desktop viewport")
    func webViewReplacementDuringGraceRestoresViewport() throws {
        let panel = try makeStreamingPanel()
        defer { panel.close() }
        #expect(panel.viewportModel.requestedViewport != nil)

        panel.removeMobileBrowserStreamSignalHandler(id: Self.handlerID)
        panel.debugSimulateWebContentProcessTermination()

        #expect(panel.mobileBrowserStreamRenderHost == nil)
        #expect(panel.mobileBrowserStreamViewportTeardownTask == nil)
        #expect(panel.viewportModel.requestedViewport == nil)
    }

    @Test("Panel close during the grace skips the wait and tears down now")
    func panelCloseDuringGraceTearsDownImmediately() throws {
        let panel = try makeStreamingPanel()
        panel.removeMobileBrowserStreamSignalHandler(id: Self.handlerID)
        #expect(panel.mobileBrowserStreamRenderHost != nil)

        panel.close()

        #expect(panel.mobileBrowserStreamRenderHost == nil)
        #expect(panel.mobileBrowserStreamViewportTeardownTask == nil)
    }

    private static let handlerID = UUID()

    /// Builds a headless panel with one live stream handler and an active
    /// offscreen render host at a phone-shaped viewport.
    private func makeStreamingPanel(grace: TimeInterval = 60.0) throws -> BrowserPanel {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "about:blank"))
        )
        panel.mobileBrowserStreamViewportTeardownGrace = grace
        panel.addMobileBrowserStreamSignalHandler(id: Self.handlerID) { _ in }
        #expect(panel.applyMobileStreamViewport(width: 390, height: 700, scale: 3.0))
        return panel
    }
}
// SUPERMUX:end mac-browser-stream-teardown-grace

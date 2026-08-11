// SUPERMUX:begin ios-terminal-scroll-speed
import CMUXMobileCore
// SUPERMUX:end ios-terminal-scroll-speed
import CmuxMobileRPC
import Foundation
import OSLog

private let terminalScrollDeliveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Forward a scroll gesture to the Mac's real surface. libghostty does the
    /// mode-correct thing: normal screen moves the viewport into scrollback;
    /// alt screen + mouse reporting encodes mouse-wheel to the PTY for the
    /// program. The render-grid mirrors the result (it exports the live
    /// `vp_top`).
    ///
    // SUPERMUX:begin ios-terminal-alt-scroll-budget
    /// Fire-and-forget and single-flight per surface. The phone's scroll view
    /// has no inertia (it stops at touch-up — physically verified), so the
    /// deltas arriving here track a live finger; while one RPC is in flight,
    /// newer deltas are summed into the next request instead of piling up
    /// stale scroll packets.
    // SUPERMUX:end ios-terminal-alt-scroll-budget
    public func scrollTerminal(surfaceID: String, lines: Double, col: Int, row: Int) async {
        // Screen-anchored sessions own primary-screen scrolling: the gesture
        // already moved the local mirror's viewport over locally accumulated
        // scrollback, the Mac's viewport is not shared, and no prefetch window
        // is needed. Only alternate-screen scrolls still round-trip (they are
        // mouse-wheel input for the TUI, not viewport movement). Suppress only
        // on a CONFIRMED primary screen: with no per-surface entry yet (before
        // the first frame, after surface removal) the screen is unknown, and
        // dropping what may be alternate-screen wheel input would eat TUI
        // scrolling, while forwarding a primary-screen scroll merely moves the
        // Mac's own viewport, which screen-anchored frames ignore.
        if usesScreenAnchoredRenderGrid,
           terminalActiveScreenBySurfaceID[surfaceID] == .primary {
            return
        }
        // SUPERMUX:begin ios-terminal-alt-scroll-budget
        // On a confirmed alternate screen each forwarded line becomes a
        // discrete TUI input whose visible effect only arrives via a later
        // repaint. A fast drag can emit lines faster than that pipeline
        // consumes them, and the surplus replays AFTER the finger lifts —
        // phantom momentum. Budget delivery and DROP the excess (queuing it
        // would recreate exactly the deferred playback being prevented).
        var budgetedLines = lines
        if terminalActiveScreenBySurfaceID[surfaceID] == .alternate {
            var budget = terminalAlternateScrollBudgetsBySurfaceID[surfaceID]
                ?? TerminalAlternateScrollBudget()
            // Incoming lines are already scaled by the user's scroll-speed
            // preference (the surface applies it at gesture time). Admit in
            // unscaled gesture units so the burst/refill cap scales with the
            // preference too — otherwise fast drags saturate at the same
            // absolute count and the Settings slider does nothing on TUIs.
            budgetedLines = budget.admit(
                lines: lines,
                speed: MobileTerminalScrollSpeedPreference.resolve(),
                at: ProcessInfo.processInfo.systemUptime
            )
            terminalAlternateScrollBudgetsBySurfaceID[surfaceID] = budget
            // SUPERMUX:begin ios-terminal-alt-scroll-direct-apply
            // Stamp scroll activity so gesture-window repaint deltas skip the
            // verified per-frame fence (see requiresVerifiedReplayApplication).
            terminalAlternateScrollLastInputAtBySurfaceID[surfaceID] =
                ProcessInfo.processInfo.systemUptime
            // SUPERMUX:end ios-terminal-alt-scroll-direct-apply
            guard budgetedLines != 0 else { return }
            // SUPERMUX:begin ios-terminal-alt-scroll-quantize
            // TUIs consume scroll as whole wheel ticks, and hosts round each
            // RPC's delta toward a minimum magnitude of one line — so
            // fractional gesture packets scroll one line PER PACKET and speed
            // tracks packet rate, not finger travel (why the slider felt
            // dead). Accumulate fractions and forward only whole lines.
            var quantizer = terminalAlternateScrollQuantizersBySurfaceID[surfaceID]
                ?? TerminalAlternateScrollLineQuantizer()
            budgetedLines = quantizer.emit(lines: budgetedLines)
            terminalAlternateScrollQuantizersBySurfaceID[surfaceID] = quantizer
            guard budgetedLines != 0 else { return }
            // SUPERMUX:end ios-terminal-alt-scroll-quantize
        }
        // SUPERMUX:end ios-terminal-alt-scroll-budget
        var prefetchState = terminalScrollbackPrefetchStatesBySurfaceID[surfaceID]
            ?? TerminalScrollbackPrefetchState()
        let maxScrollbackRows = prefetchState.rowsToPrefetch(forScrollLines: budgetedLines)
        terminalScrollbackPrefetchStatesBySurfaceID[surfaceID] = prefetchState
        enqueueTerminalScroll(TerminalScrollDelivery(
            surfaceID: surfaceID,
            lines: budgetedLines,
            col: col,
            row: row,
            maxScrollbackRows: maxScrollbackRows
        ))
    }

    private func enqueueTerminalScroll(_ delivery: TerminalScrollDelivery) {
        guard delivery.lines != 0 else { return }
        let queueToken = terminalScrollQueueTokensBySurfaceID[delivery.surfaceID] ?? UUID()
        terminalScrollQueueTokensBySurfaceID[delivery.surfaceID] = queueToken
        var queue = terminalScrollQueuesBySurfaceID[delivery.surfaceID] ?? TerminalScrollDeliveryQueue()
        let immediate = queue.enqueue(delivery)
        terminalScrollQueuesBySurfaceID[delivery.surfaceID] = queue
        if let immediate {
            sendTerminalScroll(immediate, queueToken: queueToken)
        }
    }

    private func sendTerminalScroll(_ delivery: TerminalScrollDelivery, queueToken: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTerminalScroll(delivery)
            self.terminalScrollDidComplete(surfaceID: delivery.surfaceID, queueToken: queueToken)
        }
    }

    func terminalScrollDidComplete(surfaceID: String, queueToken: UUID) {
        guard terminalScrollQueueTokensBySurfaceID[surfaceID] == queueToken,
              var queue = terminalScrollQueuesBySurfaceID[surfaceID] else { return }
        let next = queue.completeInFlight()
        terminalScrollQueuesBySurfaceID[surfaceID] = queue
        if let next {
            sendTerminalScroll(next, queueToken: queueToken)
        }
    }

    private func performTerminalScroll(_ delivery: TerminalScrollDelivery) async {
        guard let client = remoteClient,
              let workspaceID = workspaceID(forTerminalID: delivery.surfaceID) else {
            return
        }
        do {
            let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
            var params: [String: Any] = [
                "workspace_id": remoteWorkspaceID.rawValue,
                "surface_id": delivery.surfaceID,
                "client_id": clientID,
                "delta_lines": delivery.lines,
                "col": delivery.col,
                "row": delivery.row,
            ]
            if let maxScrollbackRows = delivery.maxScrollbackRows {
                params["max_scrollback_rows"] = maxScrollbackRows
            }
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.scroll",
                params: params
            )
            let data = try await client.sendRequest(request)
            guard let maxScrollbackRows = delivery.maxScrollbackRows,
                  maxScrollbackRows > 0,
                  remoteClient === client else {
                return
            }
            guard let payload = try? MobileTerminalReplayResponse.decode(data),
                  let renderGrid = payload.renderGrid,
                  renderGrid.surfaceID == delivery.surfaceID else {
                return
            }
            deliverAuthoritativeTerminalRenderGrid(
                renderGrid,
                expectedSurfaceID: delivery.surfaceID,
                source: "scroll_prefetch"
            )
        } catch {
            terminalScrollDeliveryLog.error("scroll forward failed surface=\(delivery.surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}

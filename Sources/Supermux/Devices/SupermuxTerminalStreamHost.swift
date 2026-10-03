import CMUXMobileCore
import CmuxFoundation
import CmuxMobileHost
import CmuxTerminal
import Foundation
import os
import SupermuxMobileCore

/// The host half of terminal streaming to another Mac's device mirror
/// (`supermux.terminal_stream.v1`, touchpoints #777–#783).
///
/// - `mobile.supermux.terminal.watch {surface_ids}` names the terminals one
///   connection mirrors. Its event queue then sends `terminal.bytes` only for
///   those and never sheds them (`terminal-stream-watch`).
/// - `mobile.terminal.replay` with `supermux_resume_from_seq` answers with
///   the bytes since that position, from the byte tee's tail, when the tail
///   still holds them, the stream stayed continuous (same
///   `supermux_stream_epoch`) and the grid is the one the viewer has; else the
///   usual render-grid replay runs (`terminal-stream-resume`).
/// - PTY reads are coalesced into fewer, larger `terminal.bytes` events
///   (``SupermuxTerminalByteCoalescer``).
enum SupermuxTerminalStreamHost {
    nonisolated static let watchMethod = SupermuxMobileMethod.terminalWatch.rawValue
    /// Replay params a streaming viewer sends.
    nonisolated static let streamParam = "supermux_stream"
    nonisolated static let resumeFromParam = "supermux_resume_from_seq"
    nonisolated static let resumeEpochParam = "supermux_resume_epoch"
    nonisolated static let resumeColumnsParam = "supermux_resume_columns"
    nonisolated static let resumeRowsParam = "supermux_resume_rows"
    /// Replay reply keys.
    nonisolated static let epochKey = "supermux_stream_epoch"
    nonisolated static let resumedKey = "supermux_resumed"

    /// `mobile.supermux.terminal.watch`, answered on the connection itself
    /// (its event queue is the filter).
    nonisolated static func watch(_ params: [String: Any], queue: MobileHostConnectionEventQueue) -> MobileHostRPCResult {
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost {
            return .failure(MobileHostRPCError(code: "method_not_found", message: "Unknown mobile method"))
        }
        #endif
        guard let raw = params["surface_ids"] as? [String] else {
            return .failure(MobileHostRPCError(code: "invalid_params", message: "surface_ids is required"))
        }
        let surfaceIDs = Set(raw.compactMap { UUID(uuidString: $0)?.uuidString })
        queue.supermuxWatchTerminalBytes(surfaceIDs: surfaceIDs)
        return .ok(["watching": surfaceIDs.sorted()])
    }
}

// MARK: - Replay: resume from a byte position

extension TerminalController {
    /// The reply to a replay that asked to resume from a byte position, or
    /// nil when it did not ask or cannot be served that way (the usual
    /// render-grid replay runs then).
    func supermuxTerminalStreamResume(
        params: [String: Any],
        workspaceID: UUID,
        surfaceID: UUID,
        terminalTarget: ControlTerminalSocketTarget,
        expectedViewport: (columns: Int, rows: Int)?
    ) -> [String: Any]? {
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost { return nil }
        #endif
        guard let from = (params[SupermuxTerminalStreamHost.resumeFromParam] as? NSNumber)?.uint64Value,
              let epoch = params[SupermuxTerminalStreamHost.resumeEpochParam] as? String,
              let columns = v2Int(params, SupermuxTerminalStreamHost.resumeColumnsParam),
              let rows = v2Int(params, SupermuxTerminalStreamHost.resumeRowsParam) else { return nil }
        func refuse(_ reason: String) -> [String: Any]? {
            #if DEBUG
            cmuxDebugLog("supermux.terminal.resume REFUSED surface=\(surfaceID.uuidString.prefix(8)) from=\(from) reason=\(reason)")
            #endif
            return nil
        }
        guard let bytes = MobileTerminalByteTee.shared.supermuxBytes(surfaceID: surfaceID, from: from, epoch: epoch) else {
            return refuse("not_in_tail_or_epoch")
        }
        guard let surface = terminalTarget.surface.liveSurfaceForGhosttyAccess(reason: "supermuxTerminalStreamResume") else {
            return refuse("no_surface")
        }
        let size = ghostty_surface_size(surface)
        let current = (columns: max(Int(size.columns), 1), rows: max(Int(size.rows), 1))
        // The bytes continue the viewer's screen only at the grid it has.
        guard current == (columns, rows) else {
            return refuse("grid host=\(current.columns)x\(current.rows) viewer=\(columns)x\(rows)")
        }
        if let expectedViewport, !MobileTerminalReplayViewportFence.accepts(
            capturedColumns: current.columns, capturedRows: current.rows,
            expectedColumns: expectedViewport.columns, expectedRows: expectedViewport.rows
        ) { return refuse("viewport_pending expected=\(expectedViewport.columns)x\(expectedViewport.rows)") }
        #if DEBUG
        cmuxDebugLog("supermux.terminal.resume surface=\(surfaceID.uuidString.prefix(8)) from=\(from) bytes=\(bytes.data.count)")
        #endif
        return [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "seq": bytes.sequence,
            "columns": current.columns,
            "rows": current.rows,
            "data_b64": bytes.data.base64EncodedString(),
            SupermuxTerminalStreamHost.resumedKey: true,
            SupermuxTerminalStreamHost.epochKey: epoch,
        ]
    }

    /// Adds the byte stream's epoch to a replay a streaming viewer asked for,
    /// so its next resume can prove the stream stayed continuous.
    func supermuxAddTerminalStreamEpoch(to payload: inout [String: Any], params: [String: Any], surfaceID: UUID) {
        guard params[SupermuxTerminalStreamHost.streamParam] != nil else { return }
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost { return }
        #endif
        payload[SupermuxTerminalStreamHost.epochKey] = MobileTerminalByteTee.shared.supermuxStreamEpoch(surfaceID: surfaceID)
    }
}

// MARK: - Byte tee: continuity

/// Whether the byte tee skipped PTY output since it last looked. The tee
/// records nothing while no client subscribes, so after such a stretch no
/// byte position from before it may be resumed: every surface's stream
/// epoch moves on. The PTY thread only sets a flag; the main actor turns it
/// into a new generation.
enum SupermuxTerminalStreamContinuity {
    nonisolated private static let skipped = AtomicBooleanGate(false)
    nonisolated private static let generation = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Called on the PTY read thread for output the tee did not record.
    nonisolated static func noteSkipped() {
        if !skipped.loadRelaxed() { skipped.storeRelease(true) }
    }

    /// The current continuity generation (a skip since the last call starts a new one).
    nonisolated static func currentGeneration() -> UInt64 {
        generation.withLock { value in
            if skipped.loadAcquire() {
                skipped.storeRelease(false)
                value &+= 1
            }
            return value
        }
    }
}

extension MobileTerminalByteTee {
    /// The surface's stream epoch: stable while its byte sequence stayed
    /// continuous, new after the tee skipped output.
    func supermuxStreamEpoch(surfaceID: UUID) -> String {
        supermuxContinuousEpoch(state(for: surfaceID))
    }

    func supermuxContinuousEpoch(_ state: SurfaceState) -> String {
        let generation = SupermuxTerminalStreamContinuity.currentGeneration()
        if state.supermuxSkipGeneration != generation {
            state.supermuxSkipGeneration = generation
            state.supermuxStreamEpoch = UUID().uuidString
        }
        return state.supermuxStreamEpoch
    }

    /// The bytes from `from` to the current sequence, when the tail still
    /// holds them and the stream is the one `epoch` names.
    func supermuxBytes(surfaceID: UUID, from: UInt64, epoch: String) -> (sequence: UInt64, data: Data)? {
        guard replayState(surfaceID: surfaceID) != nil else { return nil }
        let state = state(for: surfaceID)
        guard supermuxContinuousEpoch(state) == epoch, from <= state.seq else { return nil }
        let missing = state.seq - from
        guard missing <= UInt64(state.replayBuffer.count) else { return nil }
        return (state.seq, Data(state.replayBuffer.suffix(Int(missing))))
    }
}

// MARK: - Byte tee: coalesced events

/// Turns many small PTY reads into fewer `terminal.bytes` events: the first
/// chunk after a quiet spell goes out at once (keystroke echo never waits),
/// and chunks arriving within the next ~2 ms join one event per terminal,
/// up to 32 KB. Sequences are untouched, so every receiver's gap check holds.
@MainActor
final class SupermuxTerminalByteCoalescer {
    static let shared = SupermuxTerminalByteCoalescer()
    static let window: DispatchTimeInterval = .microseconds(2_000)
    static let maximumEventByteCount = 32 * 1024

    private struct Pending {
        var sequence: UInt64
        var data: Data
        var end: UInt64 { sequence &+ UInt64(data.count) }
    }

    private var pending: [UUID: Pending] = [:]
    private var windowOpen = false

    func append(surfaceID: UUID, sequence: UInt64, data: Data) {
        if var queued = pending[surfaceID] {
            if queued.end == sequence {
                queued.data.append(data)
            } else {
                emit(surfaceID: surfaceID, queued)
                queued = Pending(sequence: sequence, data: data)
            }
            pending[surfaceID] = queued
        } else if windowOpen {
            pending[surfaceID] = Pending(sequence: sequence, data: data)
        } else {
            emit(surfaceID: surfaceID, Pending(sequence: sequence, data: data))
            openWindow()
            return
        }
        if let queued = pending[surfaceID], queued.data.count >= Self.maximumEventByteCount {
            pending[surfaceID] = nil
            emit(surfaceID: surfaceID, queued)
        }
    }

    private func openWindow() {
        windowOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window) {
            MainActor.assumeIsolated { SupermuxTerminalByteCoalescer.shared.windowElapsed() }
        }
    }

    private func windowElapsed() {
        guard !pending.isEmpty else {
            windowOpen = false
            return
        }
        let flushing = pending
        pending.removeAll(keepingCapacity: true)
        for (surfaceID, queued) in flushing { emit(surfaceID: surfaceID, queued) }
        openWindow()
    }

    private func emit(surfaceID: UUID, _ chunk: Pending) {
        // Upstream's wire payload (JSON + base64), one event per coalesced chunk.
        MobileHostService.shared.emitEvent(topic: "terminal.bytes", payload: [
            "surface_id": surfaceID.uuidString,
            "seq": chunk.sequence,
            "data_b64": chunk.data.base64EncodedString(),
        ])
    }
}

#if DEBUG
/// DEBUG: lets the loopback E2E play an older host that does not stream
/// (`supermux.devices.terminal_stream.pretend_old_host`).
enum SupermuxTerminalStreamDebug {
    nonisolated(unsafe) static var pretendsOldHost = false
}
#endif

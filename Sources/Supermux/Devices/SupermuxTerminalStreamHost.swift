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
///   those and never sheds them (`terminal-stream-watch`). The optional
///   `background_surface_ids` (a subset; an older host ignores it) names the
///   ones its Mac has off screen: a terminal every watcher has off screen,
///   while no connection takes every terminal, streams in ~500 ms batches
///   (``SupermuxTerminalByteDemand``, ``SupermuxTerminalByteCoalescer``).
/// - `mobile.terminal.replay` with `supermux_resume_from_seq` answers with
///   the bytes since that position, from the byte tee's tail, when the tail
///   still holds them, the stream stayed continuous (same
///   `supermux_stream_epoch`) and the grid is the one the viewer has; else the
///   usual render-grid replay runs (`terminal-stream-resume`).
/// - PTY reads are coalesced into fewer, larger `terminal.bytes` events
///   (``SupermuxTerminalByteCoalescer``), never across a grid change.
/// - Grid generations (`supermux.terminal_stream.v2`): every `terminal.bytes`
///   event carries `supermux_grid_gen`, the count of grid changes asked of
///   the PTY when it was sent (``SupermuxTerminalGridGeneration``); replays
///   report the generation they captured and a resume continues only the
///   one it names. A mirror re-anchors whenever the generation moves.
enum SupermuxTerminalStreamHost {
    nonisolated static let watchMethod = SupermuxMobileMethod.terminalWatch.rawValue
    /// Watch params: the terminals mirrored, and those of them off screen.
    nonisolated static let watchSurfacesParam = "surface_ids"
    nonisolated static let watchBackgroundParam = "background_surface_ids"
    /// Replay params a streaming viewer sends.
    nonisolated static let streamParam = "supermux_stream"
    nonisolated static let resumeFromParam = "supermux_resume_from_seq"
    nonisolated static let resumeEpochParam = "supermux_resume_epoch"
    nonisolated static let resumeColumnsParam = "supermux_resume_columns"
    nonisolated static let resumeRowsParam = "supermux_resume_rows"
    nonisolated static let resumeGridGenerationParam = "supermux_resume_grid_gen"
    /// Replay reply keys.
    nonisolated static let epochKey = "supermux_stream_epoch"
    nonisolated static let resumedKey = "supermux_resumed"
    /// `terminal.bytes` and replay key: the grid generation (v2).
    nonisolated static let gridGenerationKey = "supermux_grid_gen"

    /// `mobile.supermux.terminal.watch`, answered on the connection itself
    /// (its event queue is the filter).
    nonisolated static func watch(_ params: [String: Any], queue: MobileHostConnectionEventQueue) -> MobileHostRPCResult {
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost {
            return .failure(MobileHostRPCError(code: "method_not_found", message: "Unknown mobile method"))
        }
        #endif
        guard let raw = params[watchSurfacesParam] as? [String] else {
            return .failure(MobileHostRPCError(code: "invalid_params", message: "surface_ids is required"))
        }
        let surfaceIDs = canonicalSurfaceIDs(raw)
        let background = canonicalSurfaceIDs(params[watchBackgroundParam] as? [String] ?? []).intersection(surfaceIDs)
        queue.supermuxWatchTerminalBytes(surfaceIDs: surfaceIDs, background: background)
        // A terminal back on screen sends what its batch holds now, not at the batch's end.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SupermuxTerminalByteCoalescer.shared.flushForegroundBatches() }
        }
        return .ok(["watching": surfaceIDs.sorted(), "background": background.sorted()])
    }

    nonisolated private static func canonicalSurfaceIDs(_ raw: [String]) -> Set<String> {
        Set(raw.compactMap { UUID(uuidString: $0)?.uuidString })
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
        // The same grid may have been left and come back since: bytes from the
        // other grid in between would land in the wrong one.
        let generation = SupermuxTerminalGridGeneration.current(surfaceID: surfaceID)
        guard let viewerGeneration = (params[SupermuxTerminalStreamHost.resumeGridGenerationParam] as? NSNumber)?.uint64Value,
              viewerGeneration == generation else {
            return refuse("grid_generation host=\(generation.map(String.init) ?? "nil")")
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
            SupermuxTerminalStreamHost.gridGenerationKey: viewerGeneration,
        ]
    }

    /// Adds the byte stream's epoch to a replay a streaming viewer asked for,
    /// so its next resume can prove the stream stayed continuous, and the
    /// grid generation the capture holds. A capture taken while the PTY's
    /// grid change is still on its way to the parser holds the previous grid,
    /// so it reports none: the viewer re-anchors once the new grid shows.
    func supermuxAddTerminalStreamEpoch(to payload: inout [String: Any], params: [String: Any], surfaceID: UUID) {
        guard params[SupermuxTerminalStreamHost.streamParam] != nil else { return }
        #if DEBUG
        if SupermuxTerminalStreamDebug.pretendsOldHost { return }
        #endif
        payload[SupermuxTerminalStreamHost.epochKey] = MobileTerminalByteTee.shared.supermuxStreamEpoch(surfaceID: surfaceID)
        if let columns = (payload["columns"] as? NSNumber)?.intValue,
           let rows = (payload["rows"] as? NSNumber)?.intValue,
           let requested = SupermuxTerminalGridGeneration.requestedGrid(surfaceID: surfaceID),
           requested == (columns, rows),
           let generation = SupermuxTerminalGridGeneration.current(surfaceID: surfaceID) {
            payload[SupermuxTerminalStreamHost.gridGenerationKey] = generation
        }
        #if DEBUG
        let generation = payload[SupermuxTerminalStreamHost.gridGenerationKey].map { "\($0)" } ?? "nil"
        cmuxDebugLog("supermux.terminal.replay surface=\(surfaceID.uuidString.prefix(8)) gridGen=\(generation)")
        #endif
    }
}

// MARK: - Byte tee: continuity

/// The terminals whose PTY output the byte tee skipped since it last looked.
/// The tee records nothing while no client subscribes, so after such a
/// stretch no byte position from before it may be resumed: the stream epoch
/// of each terminal that printed meanwhile moves on. A terminal that stayed
/// quiet keeps its epoch, so a reconnect resumes it with no bytes (until
/// 2026-10-05 one flag moved every terminal's epoch, and every mirror came
/// back as a full replay). The PTY thread only records the terminal; the
/// main actor turns it into a new epoch.
enum SupermuxTerminalStreamContinuity {
    nonisolated private static let skipped = OSAllocatedUnfairLock(initialState: Set<UUID>())

    /// Called on the PTY read thread for output the tee did not record.
    nonisolated static func noteSkipped(surfaceID: UUID) {
        skipped.withLock { surfaces in
            if !surfaces.contains(surfaceID) { surfaces.insert(surfaceID) }
        }
    }

    /// Whether the tee skipped output of `surfaceID` since the last call.
    nonisolated static func takeSkipped(surfaceID: UUID) -> Bool {
        skipped.withLock { $0.remove(surfaceID) != nil }
    }
}

/// The byte tee keeps recording for a while after the last mirror left.
///
/// With no `terminal.bytes` subscriber the tee records nothing, so every
/// terminal that printed while a viewing Mac's link redialed moved its
/// stream epoch, and the reconnect's resume was refused for a multi-MB full
/// replay (2026-10-05 red run, D3: every ticker printing a line a second;
/// STREAM.md P5). The tee now records for ``grace`` after the last
/// subscriber left, into the same bounded tail (256-512 KB per terminal), so
/// a reconnect after a short drop resumes. Meanwhile each PTY read costs
/// what it costs with a subscriber, minus the sending: one copy and a main
/// hop. Phones' render frames need no byte position, so only the Mac
/// mirrors' topic arms it.
enum SupermuxTerminalTeeGrace {
    nonisolated static let graceNanoseconds: UInt64 = 120 * 1_000_000_000
    /// Uptime (ns) until which the tee records without a subscriber; 0 while
    /// one subscribes or before the first left.
    nonisolated private static let recordUntil = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Whether the tee records although nobody subscribes. On the PTY read
    /// thread, only after the subscriber checks failed.
    nonisolated static var isRecording: Bool {
        let until = recordUntil.withLock { $0 }
        return until != 0 && DispatchTime.now().uptimeNanoseconds < until
    }

    /// `terminal.bytes` gained its first subscriber (`active`) or lost its last.
    nonisolated static func subscribersChanged(active: Bool) {
        let until = active ? 0 : DispatchTime.now().uptimeNanoseconds + graceNanoseconds
        recordUntil.withLock { $0 = until }
    }
}

extension MobileTerminalByteTee {
    /// The surface's stream epoch: stable while its byte sequence stayed
    /// continuous, new after the tee skipped some of its output.
    func supermuxStreamEpoch(surfaceID: UUID) -> String {
        supermuxContinuousEpoch(state(for: surfaceID), surfaceID: surfaceID)
    }

    func supermuxContinuousEpoch(_ state: SurfaceState, surfaceID: UUID) -> String {
        if SupermuxTerminalStreamContinuity.takeSkipped(surfaceID: surfaceID) {
            state.supermuxStreamEpoch = UUID().uuidString
        }
        return state.supermuxStreamEpoch
    }

    /// The bytes from `from` to the current sequence, when the tail still
    /// holds them and the stream is the one `epoch` names.
    func supermuxBytes(surfaceID: UUID, from: UInt64, epoch: String) -> (sequence: UInt64, data: Data)? {
        guard replayState(surfaceID: surfaceID) != nil else { return nil }
        let state = state(for: surfaceID)
        guard supermuxContinuousEpoch(state, surfaceID: surfaceID) == epoch, from <= state.seq else { return nil }
        let missing = state.seq - from
        guard missing <= UInt64(state.replayBuffer.count) else { return nil }
        return (state.seq, Data(state.replayBuffer.suffix(Int(missing))))
    }
}

// MARK: - Byte tee: coalesced events

/// Turns many small PTY reads into fewer `terminal.bytes` events, paced by
/// what the connections ask of each terminal (``SupermuxTerminalByteDemand``):
/// - Foreground: the first chunk after a quiet spell goes out at once
///   (keystroke echo never waits), and chunks arriving within the next ~2 ms
///   join one event per terminal, up to 32 KB.
/// - Background (every connection watching it has it off screen): chunks join
///   one event per terminal for ~500 ms, up to 64 KB, so a hidden mirror
///   costs about two events a second instead of one per redraw. A terminal
///   back on screen, or about to be captured by a full replay, sends its
///   batch before anything newer. The cap bounds the frame a shown
///   terminal's echo may find on the wire ahead of it (~90 KB encoded, 0.3 s
///   at 300 KB/s; it was 256 KB, ~1.1 s, until 2026-10-05).
/// - Unwatched: no event at all; the byte tee's tail keeps the bytes for a
///   resume.
/// Sequences are untouched, so every receiver's gap check holds. Each event
/// carries the grid generation its bytes were sent under, and two
/// generations never share an event.
@MainActor
final class SupermuxTerminalByteCoalescer {
    static let shared = SupermuxTerminalByteCoalescer()
    static let window: DispatchTimeInterval = .microseconds(2_000)
    static let maximumEventByteCount = 32 * 1024
    static let backgroundWindow: DispatchTimeInterval = .milliseconds(500)
    static let backgroundLeeway: DispatchTimeInterval = .milliseconds(100)
    static let maximumBackgroundEventByteCount = 64 * 1024

    private struct Pending {
        var sequence: UInt64
        var data: Data
        var gridGeneration: UInt64?
        var end: UInt64 { sequence &+ UInt64(data.count) }

        /// Appends `next` when it continues this chunk under the same grid.
        mutating func join(_ next: Pending) -> Bool {
            guard end == next.sequence, gridGeneration == next.gridGeneration else { return false }
            data.append(next.data)
            return true
        }
    }

    private var pending: [UUID: Pending] = [:]
    private var windowOpen = false
    private var backgroundPending: [UUID: Pending] = [:]
    private var backgroundTimer: DispatchSourceTimer?
    private var backgroundFlushScheduled = false

    func append(surfaceID: UUID, sequence: UInt64, data: Data) {
        let delivery = SupermuxTerminalByteDemand.shared.delivery(surfaceID: surfaceID)
        // Probed for every chunk, watched or not, so a grid that changes and
        // changes back while nobody watches still moves the generation.
        let generation = SupermuxTerminalGridGeneration.current(surfaceID: surfaceID)
        let chunk = Pending(sequence: sequence, data: data, gridGeneration: generation)
        switch delivery {
        case .foreground: appendForeground(surfaceID: surfaceID, chunk)
        case .background: appendBackground(surfaceID: surfaceID, chunk)
        case .unwatched: return
        }
    }

    /// Sends now the batch of every terminal no longer in the background (a
    /// watcher brought it on screen, or a connection takes every terminal).
    func flushForegroundBatches() {
        let demand = SupermuxTerminalByteDemand.shared
        let promoted = backgroundPending.keys.filter { demand.delivery(surfaceID: $0) != .background }
        for surfaceID in promoted { flushBatch(surfaceID: surfaceID) }
    }

    /// Sends now what the terminal's background batch holds. A full replay
    /// calls it before its capture: the viewer then sees the output that
    /// raced the capture during its attach, not ~500 ms after it, and
    /// confirms the replay (`SupermuxTerminalStream.fullReplayApplied`).
    func flushBatch(surfaceID: UUID) {
        if let batch = backgroundPending.removeValue(forKey: surfaceID) { emit(surfaceID: surfaceID, batch) }
    }

    // MARK: Foreground

    private func appendForeground(surfaceID: UUID, _ chunk: Pending) {
        // A batch held while the terminal was in the background goes first.
        if let batch = backgroundPending.removeValue(forKey: surfaceID) { emit(surfaceID: surfaceID, batch) }
        guard windowOpen else {
            emit(surfaceID: surfaceID, chunk)
            openWindow()
            return
        }
        var held = chunk
        if var queued = pending.removeValue(forKey: surfaceID) {
            if queued.join(chunk) { held = queued } else { emit(surfaceID: surfaceID, queued) }
        }
        if held.data.count >= Self.maximumEventByteCount {
            emit(surfaceID: surfaceID, held)
        } else {
            pending[surfaceID] = held
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

    // MARK: Background

    private func appendBackground(surfaceID: UUID, _ chunk: Pending) {
        // A chunk held while the terminal was on screen goes first.
        if let queued = pending.removeValue(forKey: surfaceID) { emit(surfaceID: surfaceID, queued) }
        var held = chunk
        if var batch = backgroundPending.removeValue(forKey: surfaceID) {
            if batch.join(chunk) { held = batch } else { emit(surfaceID: surfaceID, batch) }
        }
        if held.data.count >= Self.maximumBackgroundEventByteCount {
            emit(surfaceID: surfaceID, held)
        } else {
            backgroundPending[surfaceID] = held
            scheduleBackgroundFlush()
        }
    }

    /// One timer for every background terminal, armed only while a batch
    /// waits; its leeway lets the system fold the wakeup into others.
    private func scheduleBackgroundFlush() {
        guard !backgroundFlushScheduled else { return }
        backgroundFlushScheduled = true
        if let backgroundTimer {
            backgroundTimer.schedule(deadline: .now() + Self.backgroundWindow, leeway: Self.backgroundLeeway)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler {
            MainActor.assumeIsolated { SupermuxTerminalByteCoalescer.shared.backgroundWindowElapsed() }
        }
        timer.schedule(deadline: .now() + Self.backgroundWindow, leeway: Self.backgroundLeeway)
        timer.resume()
        backgroundTimer = timer
    }

    private func backgroundWindowElapsed() {
        backgroundFlushScheduled = false
        let flushing = backgroundPending
        backgroundPending.removeAll(keepingCapacity: true)
        for (surfaceID, batch) in flushing { emit(surfaceID: surfaceID, batch) }
    }

    private func emit(surfaceID: UUID, _ chunk: Pending) {
        // Upstream's wire payload (JSON + base64), one event per coalesced
        // chunk, plus its grid generation (receivers ignore unknown keys).
        var payload: [String: Any] = [
            "surface_id": surfaceID.uuidString,
            "seq": chunk.sequence,
            "data_b64": chunk.data.base64EncodedString(),
        ]
        if let generation = chunk.gridGeneration {
            payload[SupermuxTerminalStreamHost.gridGenerationKey] = generation
        }
        MobileHostService.shared.emitEvent(topic: "terminal.bytes", payload: payload)
    }
}

#if DEBUG
/// DEBUG: lets the loopback E2E play an older host that does not stream
/// (`supermux.devices.terminal_stream.pretend_old_host`).
enum SupermuxTerminalStreamDebug {
    nonisolated(unsafe) static var pretendsOldHost = false
}
#endif

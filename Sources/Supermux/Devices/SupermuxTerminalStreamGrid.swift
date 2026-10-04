import CmuxTerminal
import Foundation
import os
import SupermuxMobileCore

// Grid integrity for terminal streaming (`supermux.terminal_stream.v2`).
//
// A byte stream is only meaningful at the grid the program wrote it for: a
// mirror that draws bytes written for 100 columns into 40 (or the reverse)
// wraps them at the wrong column, and a program's relative cursor moves then
// overwrite the wrong rows. The host stamps every `terminal.bytes` event with
// the grid generation it was sent under; the mirror re-anchors on a replay
// whenever the generation moves, and applies each replay only once its own
// surface has parsed what came before and holds the replay's grid.

// MARK: - Host: the grid generation of a terminal

/// The host's count of grid changes asked of one terminal's PTY
/// (`TerminalSurface.supermuxGridRequestGeneration`).
@MainActor
enum SupermuxTerminalGridGeneration {
    static func current(surfaceID: UUID) -> UInt64? {
        GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID)?.supermuxGridRequestGeneration
    }

    /// The grid last asked of the PTY (which Ghostty's parser may not hold yet).
    static func requestedGrid(surfaceID: UUID) -> (columns: Int, rows: Int)? {
        guard let surface = GhosttyApp.terminalSurfaceRegistry.terminalSurface(id: surfaceID)?
            .liveSurfaceForGhosttyAccess(reason: "supermuxRequestedGrid") else { return nil }
        let size = ghostty_surface_size(surface)
        return (max(Int(size.columns), 1), max(Int(size.rows), 1))
    }
}

// MARK: - Host: PTY output reaches the byte tee in order, on demand

/// Carries PTY output from Ghostty's read thread to the byte tee on the main
/// actor (upstream hopped through a serial queue into a main-actor task).
///
/// A replay captures the parsed screen, which already holds output the main
/// actor has not counted yet; its byte position would then be behind its
/// content and the mirror would draw those bytes twice. A replay drains this
/// inbox first (``drainNow()``), so its position counts what was read.
final class SupermuxTerminalTeeInbox: @unchecked Sendable {
    static let shared = SupermuxTerminalTeeInbox()

    private struct State {
        var chunks: [(surfaceID: UUID, data: Data)] = []
        var drainScheduled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Any thread: queues one PTY read and schedules a main-actor drain.
    func push(surfaceID: UUID, data: Data) {
        let schedule = state.withLock { state -> Bool in
            state.chunks.append((surfaceID, data))
            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { SupermuxTerminalTeeInbox.shared.drainNow() }
        }
    }

    /// Publishes every queued read, oldest first.
    @MainActor
    func drainNow() {
        let chunks = state.withLock { state -> [(surfaceID: UUID, data: Data)] in
            state.drainScheduled = false
            defer { state.chunks.removeAll(keepingCapacity: true) }
            return state.chunks
        }
        for chunk in chunks {
            MobileTerminalByteTee.shared.publishFromMain(surfaceID: chunk.surfaceID, data: chunk.data)
        }
    }
}

// MARK: - Viewer: generations seen, ordered re-pins

/// What one mirror knows about the host's grid generations.
struct SupermuxTerminalGridTracker: Sendable {
    /// The generation the mirror's screen holds (its last replay or resume);
    /// nil when unknown (a capture taken mid-resize, a host without v2).
    private(set) var screen: UInt64?
    /// The newest generation seen on the stream since the attach began.
    private var newestSeen: UInt64?
    /// The next attach must be a full replay (the grid moved).
    var needsFullReplay = false

    /// An attach starts: what the stream says from now on is compared with
    /// the reply's capture.
    mutating func attachStarted() {
        newestSeen = nil
    }

    /// The stream sent bytes under `generation`. True when the mirror's
    /// screen is attached and holds an older generation (re-anchor now).
    /// Generations only grow on one host, so bytes sent before the screen's
    /// capture (an older generation, arriving late) never re-anchor.
    mutating func streamed(_ generation: UInt64, attached: Bool) -> Bool {
        newestSeen = max(newestSeen ?? generation, generation)
        guard attached, let screen, generation > screen else { return false }
        needsFullReplay = true
        return true
    }

    /// A reply's screen holds `generation` (nil: unknown).
    mutating func replied(_ generation: UInt64?) {
        screen = generation
        needsFullReplay = false
    }

    /// After an attach: true when bytes sent after the reply's capture already
    /// moved to a newer grid (re-anchor again).
    mutating func movedPastScreen() -> Bool {
        guard let screen, let newestSeen, newestSeen > screen else { return false }
        needsFullReplay = true
        return true
    }

    /// The link is gone: the next host may count from anywhere.
    mutating func reset() {
        self = SupermuxTerminalGridTracker()
    }

    /// Reads `supermux_grid_gen` from a `terminal.bytes` payload without
    /// decoding it twice (the key's value is a bare integer; base64 holds no
    /// quotes, so the marker cannot occur inside the data).
    static func generation(inBytesPayload payload: Data) -> UInt64? {
        guard let key = payload.range(of: marker) else { return nil }
        var value: UInt64 = 0
        var digits = 0
        for byte in payload[key.upperBound...] {
            guard byte >= 0x30, byte <= 0x39 else { break }
            let (shifted, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = shifted.addingReportingOverflow(UInt64(byte - 0x30))
            guard !overflow1, !overflow2 else { return nil }
            value = sum
            digits += 1
        }
        return digits > 0 ? value : nil
    }

    private static let marker = Data("\"\(SupermuxTerminalStreamHost.gridGenerationKey)\":".utf8)
}

extension TerminalSurface {
    /// Pins a mirror surface to `grid` in stream order: output already handed
    /// to it is parsed at the grid it had, and the call returns once the
    /// parser holds the new grid, so what follows is parsed at that one.
    @MainActor
    func supermuxPinInStreamOrder(columns: Int, rows: Int, pin: () -> Void) async {
        await supermuxRemoteOutputParsed()
        pin()
        // A pane never laid out cannot take the pin yet; nothing to wait for.
        guard let live = liveSurfaceForGhosttyAccess(reason: "supermuxPinInStreamOrder") else { return }
        let requested = ghostty_surface_size(live)
        guard Int(requested.columns) == columns, Int(requested.rows) == rows else { return }
        for _ in 0..<250 {
            if let settled = settledGridCells(), settled == (columns, rows) { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #if DEBUG
        cmuxDebugLog("supermux.terminal.mirror pin did not settle at \(columns)x\(rows): \(settledGridCells().map { "\($0.columns)x\($0.rows)" } ?? "nil")")
        #endif
    }
}

// SUPERMUX:begin terminal-stream-fair-queue (the order a watching connection's terminal bytes leave in — see SUPERMUX-TOUCHPOINTS.md)
import Foundation

/// The turns a watching connection's terminal bytes take out of its event
/// queue: fair, shown terminals first, hidden ones that fall far behind
/// paused. ``MobileHostConnectionEventQueue`` stores the events; this keeps
/// which terminal goes next.
///
/// Each watched terminal queues its own bytes in order. The shared lane's
/// drain sends every other event first (status, grids, layouts: small, and
/// never overtaken by later bytes), then one chunk per terminal in turn,
/// shown terminals before hidden ones (`background_surface_ids`). So a
/// keystroke's echo waits for at most one chunk of each other shown
/// terminal plus the frame already on the wire, never for a backlog. The
/// terminal being typed in gets every other turn among shown terminals.
/// (Until 2026-10-05 one queue in arrival order held every terminal: on a
/// 300 KB/s relay the echo waited 11 s behind a hidden terminal's output.)
///
/// A hidden terminal whose oldest queued chunk has waited
/// ``backgroundMaximumAge`` pauses: its backlog goes and its bytes stop,
/// keeping only the newest chunk refused since. Shown again (the
/// connection's next watch, or input typed into it), that chunk is queued
/// first: its position is past what the viewer has, so the viewer sees the
/// gap and resumes or replays the terminal, as for any gap; when the viewer
/// already holds that position (a replay since), it ignores the chunk. A
/// hidden mirror stays at its last screen meanwhile, and the link carries
/// what is shown.
struct SupermuxWatchedByteScheduler {
    /// A `terminal.bytes` event as the queue received it.
    struct Chunk {
        let coalesceKey: String?
        let stateSeq: UInt64?
        let frame: Data
    }

    /// One watched terminal's queued byte events, oldest first.
    private struct Terminal {
        var order = MobileHostQueuedEventOrder()
        var count = 0
    }

    /// How long a hidden terminal's oldest queued bytes may wait before it pauses.
    var backgroundMaximumAge: Duration = .seconds(8)
    /// Times a hidden terminal fell that far behind and paused.
    private(set) var pauseCount = 0
    private var terminals: [String: Terminal] = [:]
    /// Watched terminals with queued bytes, in the order they are served.
    private var serveOrder: [String] = []
    /// Paused hidden terminals and the newest chunk each was refused since.
    private var pausedNewest: [String: Chunk] = [:]
    /// The terminal this connection last typed into, and whether the last
    /// chunk served was its.
    private var interactiveSurfaceID: String?
    private var servedInteractive = false

    // MARK: Queued events

    /// `eventID`, a byte event of `surfaceID`, joined the queue.
    mutating func queued(_ eventID: UUID, surfaceID: String) {
        if terminals[surfaceID] == nil { serveOrder.append(surfaceID) }
        terminals[surfaceID, default: Terminal()].order.append(eventID)
        terminals[surfaceID]?.count += 1
    }

    /// A queued event of `surfaceID` left the queue; `isQueued` says which
    /// event ids still are.
    mutating func left(surfaceID: String, isQueued: (UUID) -> Bool) {
        guard var terminal = terminals[surfaceID] else { return }
        terminal.count -= 1
        guard terminal.count > 0 else {
            terminals[surfaceID] = nil
            serveOrder.removeAll { $0 == surfaceID }
            return
        }
        terminal.order.compact(liveCount: terminal.count, isQueued: isQueued)
        terminals[surfaceID] = terminal
    }

    /// The ids of `surfaceID`'s queued byte events, oldest first.
    func queuedEventIDs(of surfaceID: String) -> ArraySlice<UUID> {
        guard let terminal = terminals[surfaceID] else { return [] }
        return terminal.order.ids[terminal.order.head...]
    }

    // MARK: Turns

    /// The terminal this connection typed into last.
    mutating func noteInteractive(_ surfaceID: String) {
        interactiveSurfaceID = surfaceID
    }

    /// The terminal served next: every other turn the one being typed in,
    /// else the first shown terminal in turn, else the first hidden one.
    mutating func nextTerminal(background: Set<String>) -> String? {
        let typedIn = interactiveSurfaceID.flatMap { surfaceID in
            !servedInteractive && terminals[surfaceID] != nil && !background.contains(surfaceID) ? surfaceID : nil
        }
        guard let surfaceID = typedIn
            ?? serveOrder.first(where: { !background.contains($0) && $0 != interactiveSurfaceID })
            ?? serveOrder.first(where: { !background.contains($0) })
            ?? serveOrder.first else { return nil }
        servedInteractive = surfaceID == interactiveSurfaceID
        return surfaceID
    }

    /// Takes the oldest queued event id of `surfaceID`.
    mutating func popOldest(of surfaceID: String) -> UUID? {
        terminals[surfaceID]?.order.popFirst()
    }

    /// `surfaceID` was served: it goes to the back of the turns.
    mutating func served(_ surfaceID: String) {
        guard let index = serveOrder.firstIndex(of: surfaceID) else { return }
        serveOrder.remove(at: index)
        serveOrder.append(surfaceID)
    }

    // MARK: Pausing

    /// Whether `surfaceID` is paused; a chunk it refuses becomes its newest.
    mutating func refusesWhilePaused(_ chunk: Chunk, of surfaceID: String) -> Bool {
        guard pausedNewest[surfaceID] != nil else { return false }
        pausedNewest[surfaceID] = chunk
        return true
    }

    /// Whether a hidden terminal whose oldest queued chunk was queued at
    /// `oldestQueuedAt` has fallen far enough behind to pause.
    func fellBehind(oldestQueuedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant = .now) -> Bool {
        guard let oldestQueuedAt else { return false }
        return now - oldestQueuedAt >= backgroundMaximumAge
    }

    /// `surfaceID` pauses (its backlog already dropped), keeping `newest`.
    mutating func pause(_ surfaceID: String, newest: Chunk) {
        pausedNewest[surfaceID] = newest
        pauseCount += 1
    }

    /// The paused terminals now shown (watched and not background), whose
    /// newest chunk goes back in the queue; paused terminals no longer
    /// watched are forgotten.
    mutating func takeShown(watched: Set<String>?, background: Set<String>) -> [(surfaceID: String, chunk: Chunk)] {
        var shown: [(surfaceID: String, chunk: Chunk)] = []
        for (surfaceID, chunk) in pausedNewest {
            if watched?.contains(surfaceID) != true {
                pausedNewest[surfaceID] = nil
            } else if !background.contains(surfaceID) {
                pausedNewest[surfaceID] = nil
                shown.append((surfaceID, chunk))
            }
        }
        return shown
    }

    /// The connection closed.
    mutating func reset() {
        terminals.removeAll()
        serveOrder.removeAll()
        pausedNewest.removeAll()
        interactiveSurfaceID = nil
    }
}
// SUPERMUX:end terminal-stream-fair-queue

import CmuxSurfaceCatalogModel
import Foundation
import SupermuxMobileCore

/// The viewer half of terminal streaming (`supermux.terminal_stream.v1`,
/// touchpoints #777–#783): what makes a device mirror follow another Mac's
/// terminal like a local one when that Mac's host streams.
///
/// - Per-terminal subscription: each link names the terminals it mirrors
///   (``SupermuxTerminalStreamWatch``); the host sends `terminal.bytes` only for
///   those, and never sheds them. A terminal whose panes here have all been off
///   screen for ``backgroundAfter`` is named as background too, and the host
///   sends its bytes in ~500 ms batches until a pane shows it again.
/// - Resume instead of replay: a seq gap, a reconnect or a re-anchor asks the
///   host for the bytes since the mirror's last byte position (exact while the
///   host's byte tail holds them and the stream stayed continuous); only then a
///   render-grid replay, which asks for deep scrollback (screen-anchored,
///   ``scrollbackRows`` rows) instead of upstream's ~240.
/// - Grid integrity (`supermux.terminal_stream.v2`): a remote grid change,
///   seen as a new grid generation on the stream or a new grid from the
///   host, re-anchors the mirror on a full replay, applied only once the
///   mirror has parsed what came before and holds the replay's grid
///   (``SupermuxTerminalGridTracker``). Bytes are never drawn into a grid
///   the program did not write them for. (Until 2026-10-04 a resize only
///   re-pinned the mirror, and output written around it garbled.)
///
/// A host without v2 keeps upstream's path unchanged.
@MainActor
final class SupermuxTerminalStream {
    /// Events a mirror session may hold before its stream drops (upstream: 512).
    static let sessionEventBufferLimit = 4096
    /// Bytes a session buffers while a replay or resume is in flight
    /// (upstream: 512 chunks / 256 KB; past them it replays again).
    static let attachBufferChunkLimit = 16_384
    static let attachBufferByteLimit = 16 * 1024 * 1024
    /// History rows a render-grid replay carries (the phone's ceiling is 20000).
    static let scrollbackRows = 10_000
    /// Drops this Mac's scrollback before a full replay: a screen-anchored
    /// replay without history repaints in place and would keep stale rows.
    static let historyReset = Data([0x1B, 0x5B, 0x33, 0x4A])

    let watch: SupermuxTerminalStreamWatch
    let surfaceID: UUID
    private var registered = false
    /// The link connection this mirror streams on, when the host streams.
    private var streamingConnection: UInt64?
    /// The host's name for the byte stream the mirror's position belongs to.
    private var epoch: String?
    private(set) var fullReplays = 0
    private(set) var resumes = 0
    private(set) var gaps = 0
    /// Re-anchors because the grid moved (a new generation or host grid).
    private(set) var gridResyncs = 0
    /// The host's grid generations as this mirror saw them.
    private(set) var grid = SupermuxTerminalGridTracker()
    /// The newest grid the host reported (`terminal.updated`, `device.terminal.grid`).
    private var hostGrid: (columns: Int, rows: Int)?
    /// Bumps with every grid signal; a re-anchor waits until it holds still.
    private var gridSignals: UInt64 = 0
    /// Re-anchors in a row that ended behind the host's grid, and how often
    /// that ran out (each retry then waits twice as long).
    private var consecutiveBehind = 0
    private var giveUps = 0
    static let maxConsecutiveGridReanchors = 4
    /// How long the grid must hold still before a re-anchor's replay: a window
    /// dragged on the other Mac replays once it stops, not for every step.
    static let gridQuietNanoseconds: UInt64 = 120_000_000
    static let gridQuietLimitNanoseconds: UInt64 = 2_000_000_000

    init(link: DeviceLink, surfaceID: UUID) {
        watch = SupermuxTerminalStreamWatch.of(link)
        self.surfaceID = surfaceID
    }

    /// Whether the mirror streams on the link's current connection.
    var isActive: Bool { streamingConnection == watch.connection }

    /// Before each replay: watch this terminal on the current connection.
    /// False when the host does not stream (upstream's path then).
    func prepare() async -> Bool {
        if !registered {
            registered = true
            watch.add(surfaceID, background: background)
        }
        let connection = watch.connection
        let streams = await watch.ensure(including: surfaceID)
        streamingConnection = streams ? connection : nil
        return streams && isActive
    }

    func stop() {
        cancelConfirmation()
        backgroundTask?.cancel()
        backgroundTask = nil
        guard registered else { return }
        registered = false
        streamingConnection = nil
        watch.remove(surfaceID, background: background)
    }

    func noteGap() { gaps += 1 }

    /// An attach begins.
    func attachStarted() { grid.attachStarted() }

    /// The stream announced a grid generation. True when the attached
    /// mirror must re-anchor on a full replay now.
    func streamedGridGeneration(_ generation: UInt64, attached: Bool) -> Bool {
        guard isActive else { return false }
        gridSignals &+= 1
        guard grid.streamed(generation, attached: attached) else { return false }
        gridResyncs += 1
        confirming = false
        return true
    }

    /// The host reported a grid the mirror does not hold: the next attach is
    /// a full replay.
    func gridChanged() {
        grid.needsFullReplay = true
        gridResyncs += 1
        confirming = false
    }

    /// The link is gone. What the mirror's screen holds stays, so the
    /// reconnect can resume; the host refuses a stale position.
    func linkLost() {
        grid.linkLost()
        hostGrid = nil
        consecutiveBehind = 0
        cancelConfirmation()
        confirming = false
        confirmationsInRow = 0
    }

    // MARK: Visibility

    /// How long a pane stays off screen before its terminal is named as
    /// background: the portal hides panes briefly during layout churn.
    static let backgroundAfter: Duration = .seconds(2)
    /// Whether the mirror's pane is off screen here
    /// (`DeviceTerminalMirrorSession.supermuxHidden`).
    private var hidden = false
    /// Whether this mirror names its terminal as background.
    private var background = false
    private var backgroundTask: Task<Void, Never>?

    /// The pane went off screen or came back. Hidden, an armed confirmation
    /// waits for the show (``takeDueConfirmation()``) and, after
    /// ``backgroundAfter``, the terminal becomes background; shown, it leaves
    /// the background at once.
    func visibilityChanged(hidden: Bool) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden
        backgroundTask?.cancel()
        backgroundTask = nil
        guard hidden else {
            setBackground(false)
            return
        }
        if confirmationTask != nil {
            cancelConfirmation()
            pendingConfirmation = true
        }
        backgroundTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.backgroundAfter)) != nil,
                  let self, self.hidden, !Task.isCancelled else { return }
            self.backgroundTask = nil
            self.setBackground(true)
        }
    }

    private func setBackground(_ value: Bool) {
        guard value != background else { return }
        background = value
        if registered { watch.setBackground(surfaceID, value) }
    }

    // MARK: Replay boundary

    /// A full replay captures the screen while PTY reads may still be on their
    /// way to the parser, or with the parser inside an escape sequence; when
    /// output was flowing around the capture, the live bytes that follow may
    /// not continue it exactly. Such a replay is confirmed by another one once
    /// output has been quiet for ``outputQuiet``, which captures an idle
    /// parser exactly. A confirmation that raced output again is confirmed
    /// again after twice the quiet, at most ``maximumConfirmationsInRow``
    /// times in a row, and after the first only when output came right before
    /// its request; a hidden pane's confirmation waits for its show. (Until
    /// 2026-10-05 the wait polled at 10 Hz, and a terminal printing every
    /// second chained full replays.)
    private var lastBytesAt: ContinuousClock.Instant?
    private var bytesDuringAttach = false
    private var requestRacedOutput = false
    private var confirmationTask: Task<Void, Never>?
    /// Confirmations since the last full replay that was not one.
    private var confirmationsInRow = 0
    /// The next full replay is a confirmation.
    private var confirming = false
    /// A confirmation came due while the pane was hidden.
    private var pendingConfirmation = false
    private(set) var confirmations = 0
    static let outputRaceWindow: Duration = .milliseconds(150)
    static let outputQuiet: Duration = .milliseconds(400)
    static let maximumConfirmationQuiet: Duration = .seconds(8)
    static let maximumConfirmationsInRow = 3
    static let confirmationTolerance: Duration = .milliseconds(100)

    /// Live bytes arrived.
    func noteBytes(attaching: Bool) {
        lastBytesAt = .now
        if attaching { bytesDuringAttach = true }
    }

    /// A replay request leaves now.
    func replayRequested() {
        bytesDuringAttach = false
        requestRacedOutput = lastBytesAt.map { ContinuousClock.now - $0 < Self.outputRaceWindow } ?? false
    }

    /// A full replay was applied: when output raced it, `confirm` runs once
    /// output has been quiet (cancelled by a newer replay, a link loss or stop).
    func fullReplayApplied(confirm: @escaping @MainActor () -> Void) {
        cancelConfirmation()
        pendingConfirmation = false
        if !confirming { confirmationsInRow = 0 }
        confirming = false
        let raced = confirmationsInRow == 0 ? requestRacedOutput || bytesDuringAttach : requestRacedOutput
        guard isActive, raced, confirmationsInRow < Self.maximumConfirmationsInRow else { return }
        guard !hidden else {
            pendingConfirmation = true
            return
        }
        let quiet = min(Self.outputQuiet * (1 << confirmationsInRow), Self.maximumConfirmationQuiet)
        confirmationTask = Task { [weak self] in
            // Each byte moves the deadline; the task wakes only at deadlines.
            while let deadline = self?.quietDeadline(after: quiet) {
                do {
                    try await Task.sleep(until: deadline, tolerance: Self.confirmationTolerance, clock: .continuous)
                } catch {
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.confirmationTask = nil
            self.startConfirmation()
            confirm()
        }
    }

    /// The pane came on screen: true when a confirmation came due while it
    /// was hidden, and the caller re-anchors now.
    func takeDueConfirmation() -> Bool {
        guard pendingConfirmation, !hidden else { return false }
        pendingConfirmation = false
        startConfirmation()
        return true
    }

    private func startConfirmation() {
        confirmationsInRow += 1
        confirming = true
        confirmations += 1
        grid.needsFullReplay = true
    }

    /// When output will have been quiet for `quiet`; nil once it has.
    private func quietDeadline(after quiet: Duration) -> ContinuousClock.Instant? {
        guard let lastBytesAt else { return nil }
        let deadline = lastBytesAt + quiet
        return deadline > .now ? deadline : nil
    }

    private func cancelConfirmation() {
        confirmationTask?.cancel()
        confirmationTask = nil
    }

    /// Returns once no grid signal arrived for ``gridQuietNanoseconds`` (at
    /// most ``gridQuietLimitNanoseconds``).
    func awaitGridQuiet() async {
        var waited: UInt64 = 0
        while waited < Self.gridQuietLimitNanoseconds, !Task.isCancelled {
            let mark = gridSignals
            try? await Task.sleep(nanoseconds: Self.gridQuietNanoseconds)
            waited += Self.gridQuietNanoseconds
            if gridSignals == mark { return }
        }
    }

    /// The replay request's streaming params: deep scrollback, and the byte
    /// position to resume from when the mirror has one on this stream.
    func replayParams(expectedSequence: UInt64?, grid: (columns: Int, rows: Int)?) -> [String: Any] {
        guard isActive else { return [:] }
        var params: [String: Any] = [
            SupermuxTerminalStreamHost.streamParam: 1,
            "anchor": "screen",
            "max_scrollback_rows": Self.scrollbackRows,
        ]
        if !self.grid.needsFullReplay, let epoch, let expectedSequence, let grid,
           let generation = self.grid.screen {
            params[SupermuxTerminalStreamHost.resumeFromParam] = expectedSequence
            params[SupermuxTerminalStreamHost.resumeEpochParam] = epoch
            params[SupermuxTerminalStreamHost.resumeColumnsParam] = grid.columns
            params[SupermuxTerminalStreamHost.resumeRowsParam] = grid.rows
            params[SupermuxTerminalStreamHost.resumeGridGenerationParam] = generation
        }
        return params
    }

    func noteReply(_ reply: Reply) {
        epoch = reply.epoch
        if reply.resumed == nil { fullReplays += 1 } else { resumes += 1 }
    }

    /// The host's latest grid, as its grid events report it.
    func noteHostGrid(columns: Int, rows: Int) {
        guard isActive else { return }
        if hostGrid.map({ $0 != (columns, rows) }) ?? true { gridSignals &+= 1 }
        hostGrid = (columns, rows)
    }

    /// What an attach found once its screen was applied.
    enum GridVerdict: Equatable {
        /// The screen holds the host's grid.
        case current
        /// The grid moved during the round trip: re-anchor again now.
        case behind
        /// Behind too many times in a row: look again after this long.
        case retryLater(nanoseconds: UInt64)
    }

    /// The screen an attach applied holds `generation` (from its reply) at
    /// the grid the mirror is pinned to; is that still the host's?
    func screenApplied(_ generation: UInt64?, assigned: (columns: Int, rows: Int)?) -> GridVerdict {
        guard isActive else { return .current }
        grid.replied(generation)
        guard isBehind(assigned: assigned) else {
            consecutiveBehind = 0
            giveUps = 0
            return .current
        }
        grid.needsFullReplay = true
        confirming = false
        consecutiveBehind += 1
        guard consecutiveBehind > Self.maxConsecutiveGridReanchors else {
            gridResyncs += 1
            return .behind
        }
        // A host whose reports never match its captures must not spin the
        // attach loop: look again later, backing off.
        consecutiveBehind = 0
        giveUps += 1
        let seconds = UInt64(1) << UInt64(min(giveUps - 1, 5))
        #if DEBUG
        cmuxDebugLog("supermux.terminal.mirror grid re-anchor backs off \(seconds)s host=\(hostGrid.map { "\($0.columns)x\($0.rows)" } ?? "nil")")
        #endif
        return .retryLater(nanoseconds: seconds * 1_000_000_000)
    }

    /// Whether the mirror's screen is behind the host's grid: a newer
    /// generation streamed, or the host reports another grid than the pin.
    func isBehind(assigned: (columns: Int, rows: Int)?) -> Bool {
        guard isActive else { return false }
        if grid.streamedPastScreen { return true }
        if let hostGrid, let assigned, hostGrid != assigned { return true }
        return false
    }

    /// A replay reply, as far as streaming reads it.
    struct Reply: Sendable {
        struct Resumed: Sendable {
            let bytes: Data
            let sequence: UInt64
            let columns: Int?
            let rows: Int?
        }

        var epoch: String?
        /// The bytes since the requested position, when the host resumed.
        var resumed: Resumed?
        /// The grid generation the reply's screen holds (v2), if settled.
        var gridGeneration: UInt64?
    }

    private nonisolated static let resumedMarker = Data("\"\(SupermuxTerminalStreamHost.resumedKey)\":true".utf8)
    private nonisolated static let epochMarker = Data("\"\(SupermuxTerminalStreamHost.epochKey)\":\"".utf8)

    /// Reads a replay reply off the main actor. A full replay (often MBs of
    /// grid) is only scanned for its epoch, never parsed a second time.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func decodeReply(_ data: Data) async -> Reply {
        guard data.range(of: resumedMarker) != nil else {
            return Reply(epoch: scannedEpoch(data), gridGeneration: SupermuxTerminalGridTracker.generation(inBytesPayload: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object[SupermuxTerminalStreamHost.resumedKey] as? Bool == true,
              let sequence = (object["seq"] as? NSNumber)?.uint64Value,
              let encoded = object["data_b64"] as? String,
              let bytes = Data(base64Encoded: encoded) else {
            return Reply(epoch: scannedEpoch(data), gridGeneration: SupermuxTerminalGridTracker.generation(inBytesPayload: data))
        }
        return Reply(
            epoch: object[SupermuxTerminalStreamHost.epochKey] as? String,
            resumed: Reply.Resumed(
                bytes: bytes,
                sequence: sequence,
                columns: (object["columns"] as? NSNumber)?.intValue,
                rows: (object["rows"] as? NSNumber)?.intValue
            ),
            gridGeneration: (object[SupermuxTerminalStreamHost.gridGenerationKey] as? NSNumber)?.uint64Value
        )
    }

    /// The epoch's value (a UUID string, so never escaped) after its key.
    private nonisolated static func scannedEpoch(_ data: Data) -> String? {
        guard let key = data.range(of: epochMarker) else { return nil }
        let rest = data[key.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")),
              let value = String(data: rest[rest.startIndex..<end], encoding: .utf8),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }
}

/// One link's watched terminals: the set its host sends `terminal.bytes` for,
/// kept in step with the mirror sessions that stream on it, and the ones of
/// them every session has off screen (sent in batches). Each connection
/// starts topic-wide on the host, so both sets are sent again after every
/// (re)connect (``SupermuxDeviceLinkEvents``).
@MainActor
final class SupermuxTerminalStreamWatch {
    private static var byInstance: [SurfaceDeviceInstanceID: SupermuxTerminalStreamWatch] = [:]

    static func of(_ link: DeviceLink) -> SupermuxTerminalStreamWatch {
        if let existing = byInstance[link.instance], existing.link === link { return existing }
        let watch = SupermuxTerminalStreamWatch(link: link)
        byInstance[link.instance] = watch
        return watch
    }

    static func existing(_ instance: SurfaceDeviceInstanceID) -> SupermuxTerminalStreamWatch? {
        byInstance[instance]
    }

    /// What the host is asked for.
    struct Watched: Equatable {
        var surfaces: Set<UUID>
        var background: Set<UUID>
    }

    private weak var link: DeviceLink?
    let instance: SurfaceDeviceInstanceID
    /// Bumps when the link loses its connection: what was watched is gone.
    private(set) var connection: UInt64 = 0
    /// Sessions streaming each terminal, and how many of them are background.
    private var counts: [UUID: Int] = [:]
    private var backgroundCounts: [UUID: Int] = [:]
    private var acked: (connection: UInt64, watched: Watched)?
    private var failedConnection: UInt64?
    private var syncTask: Task<Void, Never>?
    #if DEBUG
    /// Every `terminal.bytes` byte this link received, by remote terminal.
    private(set) var bytesReceived: [UUID: Int] = [:]
    #endif

    private init(link: DeviceLink) {
        self.link = link
        instance = link.instance
        #if DEBUG
        link.terminalEvents.supermuxOnBytes = { [weak self] surfaceID, count in
            self?.bytesReceived[surfaceID, default: 0] += count
        }
        #endif
    }

    var watching: Set<UUID>? { acked?.connection == connection ? acked?.watched.surfaces : nil }

    /// A terminal is background only while every session streaming it is.
    private var desired: Watched {
        let background = backgroundCounts.compactMap { surfaceID, count in count == counts[surfaceID] ? surfaceID : nil }
        return Watched(surfaces: Set(counts.keys), background: Set(background))
    }

    func add(_ surfaceID: UUID, background: Bool) {
        counts[surfaceID, default: 0] += 1
        if background { adjustBackground(surfaceID, by: 1) }
        syncIfAcked()
    }

    func remove(_ surfaceID: UUID, background: Bool) {
        guard let count = counts[surfaceID] else { return }
        counts[surfaceID] = count > 1 ? count - 1 : nil
        if background { adjustBackground(surfaceID, by: -1) }
        syncIfAcked()
    }

    /// One session's pane went to the background or came back.
    func setBackground(_ surfaceID: UUID, _ background: Bool) {
        guard counts[surfaceID] != nil else { return }
        adjustBackground(surfaceID, by: background ? 1 : -1)
        syncIfAcked()
    }

    private func adjustBackground(_ surfaceID: UUID, by delta: Int) {
        let count = backgroundCounts[surfaceID, default: 0] + delta
        backgroundCounts[surfaceID] = count > 0 ? count : nil
    }

    func linkLost() {
        connection &+= 1
        acked = nil
        failedConnection = nil
    }

    /// A fresh connection: name the watched terminals (none yet, possibly) so
    /// the host stops sending the others' bytes at once.
    func linkConnected() {
        Task { [weak self] in _ = await self?.ensure(including: nil) }
    }

    /// Whether the host streams on the current connection with `surfaceID`
    /// (when given) watched; sends the sets first when the watched one
    /// changed (a background change alone goes out without holding this up).
    func ensure(including surfaceID: UUID?) async -> Bool {
        let connection = self.connection
        guard let link, link.isConnected,
              await SupermuxComposition.devices.supports(.terminalStreamV2, on: .device(instance)),
              connection == self.connection else { return false }
        for _ in 0..<3 {
            if let acked, acked.connection == connection, acked.watched.surfaces == Set(counts.keys) { break }
            failedConnection = nil
            await sync().value
            guard connection == self.connection, failedConnection != connection else { return false }
        }
        guard let acked, acked.connection == connection else { return false }
        return surfaceID.map(acked.watched.surfaces.contains) ?? true
    }

    /// A change once the host has the sets on this connection goes out now;
    /// before that, ``ensure(including:)`` sends the latest.
    private func syncIfAcked() {
        if acked?.connection == connection { _ = sync() }
    }

    /// Single-flight: sends the sets until the host has the latest ones.
    private func sync() -> Task<Void, Never> {
        if let syncTask { return syncTask }
        let task = Task { [weak self] in
            while let self {
                let connection = self.connection
                let desired = self.desired
                if let acked = self.acked, acked.connection == connection, acked.watched == desired { break }
                guard let link = self.link, link.isConnected else { break }
                do {
                    _ = try await link.request(
                        SupermuxMobileMethod.terminalWatch.rawValue,
                        params: [
                            SupermuxTerminalStreamHost.watchSurfacesParam: desired.surfaces.map(\.uuidString).sorted(),
                            SupermuxTerminalStreamHost.watchBackgroundParam: desired.background.map(\.uuidString).sorted(),
                        ]
                    )
                    guard connection == self.connection else { break }
                    self.acked = (connection, desired)
                } catch {
                    self.failedConnection = connection
                    break
                }
            }
            self?.syncTask = nil
        }
        syncTask = task
        return task
    }
}

#if DEBUG
extension SupermuxTerminalStreamWatch {
    /// `supermux.devices.terminal_stream.stats` for this link.
    func debugStats(sessions: [UUID: DeviceTerminalMirrorSession]) -> [String: Any] {
        let panes = sessions.sorted { $0.key.uuidString < $1.key.uuidString }.map { panelID, session -> [String: Any] in
            let stream = session.supermuxStream
            return [
                "panel_id": panelID.uuidString,
                "remote_surface_id": session.remoteSurfaceID.uuidString,
                "streaming": stream?.isActive ?? false,
                "full_replays": stream?.fullReplays ?? 0,
                "resumes": stream?.resumes ?? 0,
                "gaps": stream?.gaps ?? 0,
                "grid_resyncs": stream?.gridResyncs ?? 0,
                "replay_confirmations": stream?.confirmations ?? 0,
            ]
        }
        let background = acked?.connection == connection ? acked?.watched.background : nil
        return [
            "supported": watching != nil,
            "watching": watching.map { $0.map(\.uuidString).sorted() } ?? NSNull(),
            "background": background.map { $0.map(\.uuidString).sorted() } ?? NSNull(),
            "bytes_received_by_surface": Dictionary(uniqueKeysWithValues: bytesReceived.map { ($0.key.uuidString, $0.value) }),
            "panes": panes,
        ]
    }
}
#endif

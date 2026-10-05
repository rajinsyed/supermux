import CmuxMobileRPC
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
    /// History rows a hidden mirror's re-attach asks for. A 10000-row replay
    /// is MBs, and a reply frame is never split, so on a slow link one blocks
    /// every pane's output on that connection until it is through (a hidden
    /// mirror's 1.7 MB replay after a reconnect held the shown ECHO
    /// terminal's echo ~6 s at 300 KB/s, 2026-10-05 D3). Hidden, the mirror
    /// gets its screen and this much history; the rest comes with a full
    /// replay once a pane shows it and its output is quiet (the replay
    /// boundary's confirmation, ``fullReplayApplied(confirm:)``).
    static let hiddenScrollbackRows = 100
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
    /// Names this mirror's replay requests to the host, so a newer one from
    /// the same pane supersedes an older reply still waiting there
    /// (``SupermuxTerminalReplaySupersession``).
    let replayOwner = UUID().uuidString

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
        pendingConfirmation = false
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

    /// The pane went off screen or came back. Hidden for ``backgroundAfter``,
    /// the terminal becomes background and an armed confirmation stops
    /// waiting until the show (a brief hide leaves it armed). Shown, the
    /// terminal leaves the background at once, and a confirmation that
    /// waited for the show waits for quiet output again.
    func visibilityChanged(hidden: Bool) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden
        backgroundTask?.cancel()
        backgroundTask = nil
        guard hidden else {
            shownAt = .now
            setBackground(false)
            resumePendingConfirmation()
            return
        }
        backgroundTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.backgroundAfter)) != nil,
                  let self, self.hidden, !Task.isCancelled else { return }
            self.backgroundTask = nil
            self.setBackground(true)
            self.parkConfirmation()
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
    /// its request. A hidden pane's confirmation waits for its show, then for
    /// quiet output. (Until 2026-10-05 the wait polled at 10 Hz, and a
    /// terminal printing every second chained full replays.)
    ///
    /// Each one also waits until nothing was typed into the pane for
    /// ``inputIdle``, nor since it was last shown: a multi-MB reply shares
    /// the link with the echo (on one ordered stream it holds it for its
    /// whole transfer), and the pane the user just looked at is the one
    /// they are about to type in. A keystroke moves the wait on. The re-capture
    /// itself keeps the pane attached (the session's live re-capture): output
    /// is drawn as it comes and again over the new screen.
    private var lastBytesAt: ContinuousClock.Instant?
    private var bytesDuringAttach = false
    private var requestRacedOutput = false
    private var confirmationTask: Task<Void, Never>?
    /// Re-anchors the mirror for a confirmation (the session's, from
    /// ``fullReplayApplied(confirm:)``).
    private var confirm: (@MainActor () -> Void)?
    /// Confirmations since the last full replay that was not one.
    private var confirmationsInRow = 0
    /// The next full replay is a confirmation.
    private var confirming = false
    /// A confirmation waits for the pane's show.
    private var pendingConfirmation = false
    private(set) var confirmations = 0
    /// Whether the replay request leaving now asks for the hidden mirror's
    /// short history, and whether the last full replay applied did.
    private var requestIsShallow = false
    private var historyIsShallow = false
    static let outputRaceWindow: Duration = .milliseconds(150)
    /// The race window while the host batches this terminal's bytes: they
    /// arrive up to its ~500 ms batch window plus 100 ms leeway late
    /// (`SupermuxTerminalByteCoalescer.backgroundWindow`).
    static let backgroundOutputRaceWindow: Duration = .milliseconds(750)
    static let outputQuiet: Duration = .milliseconds(400)
    /// How long a re-capture of the pane waits after its last keystroke, and
    /// after the pane was shown.
    static let inputIdle: Duration = .seconds(3)
    /// When typing last went to the pane (the session's input pipeline).
    var lastInputAt: (@MainActor () -> ContinuousClock.Instant?)?
    /// When the pane was last shown.
    private var shownAt: ContinuousClock.Instant?
    static let maximumConfirmationQuiet: Duration = .seconds(8)
    static let maximumConfirmationsInRow = 3
    static let confirmationTolerance: Duration = .milliseconds(100)

    /// Live bytes arrived.
    func noteBytes(attaching: Bool) {
        lastBytesAt = .now
        if attaching { bytesDuringAttach = true }
    }

    #if DEBUG
    /// Replay requests sent (full or resume), for `terminal_stream.stats`:
    /// more than the replies applied means some were asked again or lost.
    private(set) var replayRequests = 0

    /// The next attach asks a full replay, as a grid change does
    /// (`terminal_close.replay {full: true}`).
    func debugNeedsFullReplay() { grid.needsFullReplay = true }
    #endif

    /// A replay request leaves now.
    func replayRequested() {
        #if DEBUG
        replayRequests += 1
        #endif
        bytesDuringAttach = false
        let window = background ? Self.backgroundOutputRaceWindow : Self.outputRaceWindow
        requestRacedOutput = lastBytesAt.map { ContinuousClock.now - $0 < window } ?? false
    }

    /// A full replay was applied: when output raced it, `confirm` runs once
    /// output has been quiet (cancelled by a newer replay, a link loss or stop).
    func fullReplayApplied(confirm: @escaping @MainActor () -> Void) {
        cancelConfirmation()
        pendingConfirmation = false
        if !confirming { confirmationsInRow = 0 }
        confirming = false
        let raced = confirmationsInRow == 0 ? requestRacedOutput || bytesDuringAttach : requestRacedOutput
        // A hidden mirror's short history is completed the same way: by a full
        // replay once it is shown and quiet.
        guard isActive, raced || historyIsShallow, confirmationsInRow < Self.maximumConfirmationsInRow else { return }
        self.confirm = confirm
        guard !hidden else {
            pendingConfirmation = true
            return
        }
        armConfirmation()
    }

    /// Runs the confirmation once output has been quiet for its quiet; one
    /// that comes due while the pane is off screen waits for the show.
    private func armConfirmation() {
        cancelConfirmation()
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
            guard !self.hidden else {
                self.pendingConfirmation = true
                return
            }
            self.startConfirmation()
            self.confirm?()
        }
    }

    /// The pane came back on screen: a confirmation that waited for the show
    /// waits for quiet output again, so it still captures an idle parser.
    private func resumePendingConfirmation() {
        guard pendingConfirmation else { return }
        pendingConfirmation = false
        armConfirmation()
    }

    /// The pane has been off screen for ``backgroundAfter``: an armed
    /// confirmation stops waking and waits for the show.
    private func parkConfirmation() {
        guard confirmationTask != nil else { return }
        cancelConfirmation()
        pendingConfirmation = true
    }

    private func startConfirmation() {
        confirmationsInRow += 1
        confirming = true
        confirmations += 1
        grid.needsFullReplay = true
    }

    /// When output will have been quiet for `quiet`, and the pane free of
    /// typing (and shown) for ``inputIdle``; nil once both hold.
    private func quietDeadline(after quiet: Duration) -> ContinuousClock.Instant? {
        let deadlines = [
            lastBytesAt.map { $0 + quiet },
            lastInputAt?().map { $0 + Self.inputIdle },
            shownAt.map { $0 + Self.inputIdle },
        ]
        guard let deadline = deadlines.compactMap({ $0 }).max() else { return nil }
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
        // A hidden mirror that attached before (it has an epoch) asks for its
        // screen and a short history; the rest comes once it is shown.
        requestIsShallow = hidden && epoch != nil
        var params: [String: Any] = [
            SupermuxTerminalStreamHost.streamParam: 1,
            SupermuxTerminalStreamHost.replayOwnerParam: replayOwner,
            "anchor": "screen",
            "max_scrollback_rows": requestIsShallow ? Self.hiddenScrollbackRows : Self.scrollbackRows,
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

    // MARK: Replay deadline

    /// How long a replay's reply may take. A full replay is MBs: on a slow
    /// relay several of them leave the host one after another (7 at 300 KB/s
    /// took ~40 s), so the link's 20 s missed the late ones, and each was
    /// asked for again while the host still sent the first (STREAM.md H3b).
    nonisolated static let replayDeadlineNanoseconds: UInt64 = 90_000_000_000

    /// The deadline of a mirror request: a replay's own (a suite may set it,
    /// `terminal_stream.replay_deadline`), else the link's.
    nonisolated static func deadline(forMethod method: String) -> UInt64? {
        guard method == "mobile.terminal.replay" else { return nil }
        #if DEBUG
        if let seconds = SupermuxTerminalStreamDebug.replayDeadlineSeconds { return UInt64(seconds * 1_000_000_000) }
        #endif
        return replayDeadlineNanoseconds
    }

    /// The wait before asking again after the `attempt`-th replay in a row
    /// missed its deadline on a live link: 2 s, doubling, at most 30 s.
    static func replayRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(UInt64(2) << UInt64(min(max(attempt - 1, 0), 4)), 30)
        return seconds * 1_000_000_000
    }

    func noteReply(_ reply: Reply) {
        epoch = reply.epoch
        if reply.resumed == nil {
            fullReplays += 1
            historyIsShallow = requestIsShallow
        } else {
            resumes += 1
        }
        // Journaled in every build: its counters (`replay-full`,
        // `replay-resumed`) go into `cmux iroh-diag`, so a field report shows
        // whether reconnects resumed or re-sent whole screens.
        MobileHostIrxRuntime.journal.record("terminal-stream", reply.resumed == nil ? "replay-full" : "replay-resumed", [
            "device": String(watch.instance.deviceID.prefix(8)),
            "tag": watch.instance.tag,
        ])
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
        /// A resumed reply's sizing fields (a full replay's come with its decode).
        var sizing: MobileTerminalReplaySizing?
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
            gridGeneration: (object[SupermuxTerminalStreamHost.gridGenerationKey] as? NSNumber)?.uint64Value,
            sizing: replaySizing(in: object)
        )
    }

    /// A replay reply's `size_state` and `self_participant_id`, from the
    /// dictionary its decode already parsed off the main actor: the same
    /// decoder as `MobileTerminalReplaySizing.decodeIfPresent`, over just
    /// those two fields instead of the whole (often multi-MB) reply.
    nonisolated static func replaySizing(in object: [String: Any]) -> MobileTerminalReplaySizing? {
        var fields: [String: Any] = [:]
        for key in ["size_state", "self_participant_id"] { fields[key] = object[key] }
        guard !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
        return MobileTerminalReplaySizing.decodeIfPresent(data)
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
    /// Sends that failed in a row; retries stop at ``maximumRetries`` (a host
    /// that always rejects the call, such as a workspace-scoped ticket),
    /// unless a pane shown here is still background on the host.
    private var consecutiveFailures = 0
    private static let maximumRetries = 5
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
        consecutiveFailures = 0
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
                    self.consecutiveFailures = 0
                } catch {
                    self.failedConnection = connection
                    self.consecutiveFailures += 1
                    if self.consecutiveFailures <= Self.maximumRetries || self.hostBatchesAShownTerminal(on: connection) {
                        self.retryAfterFailure(on: connection)
                    }
                    break
                }
            }
            self?.syncTask = nil
        }
        syncTask = task
        return task
    }

    /// A send that failed on a connection that stays up (a busy host, a missed
    /// deadline) goes out again shortly: a background change alone has no
    /// other path that sends it again, and a shown pane would keep getting
    /// its bytes in background batches, or stay frozen where the host paused
    /// it. A connection's first send retries too, or the host would keep
    /// sending every terminal's bytes. ``maximumRetries`` in a row 2 s
    /// apart; past them only while the host still batches a terminal shown
    /// here, backing off to 30 s (a host that keeps rejecting the call is
    /// otherwise asked again only by the next change or attach).
    private func retryAfterFailure(on connection: UInt64) {
        let delay = Self.retryDelay(afterFailures: consecutiveFailures)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.connection == connection, self.failedConnection == connection else { return }
            self.failedConnection = nil
            _ = self.sync()
        }
    }

    /// 2 s for the first ``maximumRetries`` failures in a row, then doubling to 30 s.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        let past = min(max(failures - maximumRetries, 0), 4)
        return .seconds(min(2 << past, 30))
    }

    /// Whether the host, as last acknowledged on `connection`, still batches
    /// (or paused) a terminal that some pane here now shows.
    private func hostBatchesAShownTerminal(on connection: UInt64) -> Bool {
        guard let acked, acked.connection == connection else { return false }
        return !acked.watched.background.subtracting(desired.background).isEmpty
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
                "replay_requests": stream?.replayRequests ?? 0,
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

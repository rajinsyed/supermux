import CMUXMobileCore
// SUPERMUX:begin device-mirror-viewer-colors
import CmuxCloudTui
// SUPERMUX:end device-mirror-viewer-colors
import CmuxMobileRPC
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation
import OSLog
// SUPERMUX:begin device-mirror-input-batch
import SupermuxKit
// SUPERMUX:end device-mirror-input-batch

nonisolated private let deviceMirrorLog = Logger(subsystem: "dev.cmux", category: "device-terminal-mirror")

/// Owns one local projection of a terminal running on another Mac.
///
/// The remote Mac's Ghostty surface stays the PTY owner. This session feeds
/// that surface's raw PTY bytes (`terminal.bytes`, chained by sequence from a
/// render-grid replay on attach) into a local manual-mirror ``TerminalSurface``,
/// sends local keystrokes back as `mobile.terminal.input`. The source Mac owns
/// the terminal grid: mirrors follow its replay and resize events.
///
/// With a sizing identity this Mac is a participant of the source Mac's
/// shared sizing (docs/shared-terminal-sizing.md), exactly like a paired
/// phone: it reports its pane's grid as `device_kind: mac`, counts by the
/// same rules, shows the bounds and chip in its pane, and can be
/// disconnected and reattached through the same size panel actions.
@MainActor
final class DeviceTerminalMirrorSession {
    enum Phase: Equatable {
        case idle
        case attaching
        case attached
        case detached
        case stopped
    }

    private let isConnected: @MainActor @Sendable () -> Bool
    private let events: DeviceLinkTerminalEvents
    private let requestData: @MainActor @Sendable (String, [String: Any]) async throws -> Data
    let remoteWorkspaceID: String
    let remoteSurfaceID: UUID
    let inputRouter: DeviceTerminalInputRouter
    // SUPERMUX:begin terminal-input-pipeline
    let supermuxInputPipeline: SupermuxTerminalInputPipeline
    // SUPERMUX:end terminal-input-pipeline
    let attachment: DeviceTerminalAttachmentStatus
    private(set) var phase: Phase = .idle {
        didSet {
            // SUPERMUX:begin terminal-stream-grid-viewer (a grid re-anchor on a live link keeps input flowing and the pane connected; upstream: `inputRouter.setEnabled(phase == .attached)` and `attachment.update(connected: phase == .attached, connecting: phase == .attaching)`)
            if phase != .attaching { supermuxGridResyncing = false }
            let supermuxLive = phase == .attached || supermuxGridResyncing
            inputRouter.setEnabled(supermuxLive)
            // SUPERMUX:end terminal-stream-grid-viewer
            // SUPERMUX:begin terminal-input-pipeline
            supermuxInputPipeline.setEnabled(supermuxLive)
            // SUPERMUX:end terminal-input-pipeline
            // SUPERMUX:begin terminal-stream-grid-viewer
            attachment.update(connected: supermuxLive, connecting: phase == .attaching && !supermuxGridResyncing)
            // SUPERMUX:end terminal-stream-grid-viewer
        }
    }
    // SUPERMUX:begin terminal-stream-grid-viewer
    /// Set while an attached mirror re-anchors because the other Mac's grid
    /// changed: the link is up, so typing keeps going to the terminal.
    private var supermuxGridResyncing = false
    // SUPERMUX:end terminal-stream-grid-viewer
    private(set) var assignedGrid: (columns: Int, rows: Int)?
    var onAttached: (@MainActor () -> Void)?
    /// The reserved pane's early input, held until an attach sticks. Losing
    /// the link discards it, since a restarted Mac can restore a terminal
    /// under the same surface ID with a new shell, and so does stopping the
    /// session, so a replacement owner never inherits it.
    private var adoptedRelay: CloudOptimisticInputRelay?

    private weak var surface: TerminalSurface?
    private var eventTask: Task<Void, Never>?
    private var attachTask: Task<Void, Never>?
    private var expectedSequence: UInt64?
    private var replayNeeded = false
    private var attachingBytes: [(sequence: UInt64?, data: Data)] = []
    private var attachingByteCount = 0
    /// This Mac as a shared-sizing participant of the source Mac, when it has
    /// an identity (the production path; tests may omit it).
    private(set) var viewer: RemoteMacTerminalViewer?
    /// The local surface id this session published sharing state under.
    private var sharingSurfaceID: UUID?
    /// Consecutive `viewport_transition` answers, bounded so a host that never
    /// settles cannot spin the attach loop.
    private var viewportTransitionRetries = 0
    // SUPERMUX:begin device-mirror-replay-timed-out
    /// Consecutive replays that missed their deadline on a live link
    /// (SupermuxDeviceLinkEvents.isMissedDeadline), bounded like the above.
    private var supermuxTimedOutRetries = 0
    // SUPERMUX:end device-mirror-replay-timed-out
    // SUPERMUX:begin device-mirror-hidden-counts
    /// Set while this mirror's pane is off screen here: it then reports
    /// `counts_override: false`, so a pane nobody looks at never sizes the
    /// other Mac's terminal (SupermuxTerminalSizingVisibility).
    private(set) var supermuxHidden = false
    /// Whether the host holds this Mac's automatic `counts_override: false` on
    /// this terminal, so a pane coming on screen must clear it (now, or with
    /// the next replay). Per link and terminal, not per pane: the host keeps
    /// one override per client id, which every pane of the terminal shares.
    private var supermuxHostHoldsHiddenCounts: Bool {
        get { SupermuxDeviceViewportGenerations.shared.holdsHiddenCounts(viewer, surfaceID: remoteSurfaceID) }
        set { SupermuxDeviceViewportGenerations.shared.setHoldsHiddenCounts(newValue, viewer, surfaceID: remoteSurfaceID) }
    }
    // SUPERMUX:end device-mirror-hidden-counts
    // SUPERMUX:begin device-mirror-viewer-colors
    /// Replays carry no color state of their own; each is followed by bytes
    /// that settle every color to this Mac's theme plus the other Mac's
    /// program-authored ones (SupermuxDeviceMirrorColors).
    private(set) var supermuxColors = SupermuxDeviceMirrorColorState()
    // SUPERMUX:end device-mirror-viewer-colors
    // SUPERMUX:begin device-mirror-sizing-claim
    /// Whether this mirror holds its terminal's grid for this Mac and pushed
    /// this Mac's size preference on this connection (SupermuxTerminalSizingDefaults).
    var supermuxSizingClaim = SupermuxTerminalSizingClaim()
    // SUPERMUX:end device-mirror-sizing-claim
    // SUPERMUX:begin terminal-stream-viewer
    /// Lossless streaming when the other Mac's host streams (SupermuxTerminalStream).
    private(set) var supermuxStream: SupermuxTerminalStream?
    // SUPERMUX:end terminal-stream-viewer
    // SUPERMUX:begin sizing-one-setting
    /// Whether the other Mac adopts a mode picked on this mirror as its own
    /// setting (`supermux.terminal_sizing_preference.v1`).
    var supermuxHostTakesSizingPreference: @MainActor () -> Bool = { false }
    // SUPERMUX:end sizing-one-setting

    convenience init(link: DeviceLink, remoteWorkspaceID: String, remoteSurfaceID: UUID) {
        self.init(
            remoteWorkspaceID: remoteWorkspaceID, remoteSurfaceID: remoteSurfaceID,
            events: link.terminalEvents,
            isConnected: { link.isConnected },
            requestData: { method, params in try await link.requestData(method, params: params) },
            // SUPERMUX:begin device-mirror-input-batch (upstream's viewer argument gains a trailing comma)
            viewer: RemoteMacTerminalViewer(
                clientID: link.clientID,
                identity: SupermuxTerminalSizingDefaults.viewerIdentity(for: link.instance)
            ),
            supportsSupermuxInput: { [instance = link.instance] in
                SupermuxDeviceTerminalInput.supportsForwardedInput(on: .device(instance))
            },
            // SUPERMUX:end device-mirror-input-batch
            // SUPERMUX:begin terminal-input-pipeline
            supportsInputPipeline: { [instance = link.instance] in
                SupermuxTerminalInputPipeline.hostSupportsPipeline(on: .device(instance))
            }
            // SUPERMUX:end terminal-input-pipeline
        )
        // SUPERMUX:begin terminal-stream-viewer
        supermuxStream = SupermuxTerminalStream(link: link, surfaceID: remoteSurfaceID)
        // SUPERMUX:end terminal-stream-viewer
        // SUPERMUX:begin sizing-one-setting
        supermuxHostTakesSizingPreference = { [instance = link.instance] in
            SupermuxTerminalSizingDefaults.hostTakesPreference(on: .device(instance))
        }
        // SUPERMUX:end sizing-one-setting
    }

    init(
        remoteWorkspaceID: String,
        remoteSurfaceID: UUID,
        events: DeviceLinkTerminalEvents,
        isConnected: @escaping @MainActor @Sendable () -> Bool,
        requestData: @escaping @MainActor @Sendable (String, [String: Any]) async throws -> Data,
        // SUPERMUX:begin device-mirror-input-batch (upstream's viewer parameter gains a trailing comma)
        viewer: RemoteMacTerminalViewer? = nil,
        supportsSupermuxInput: @escaping @MainActor @Sendable () -> Bool = { false },
        // SUPERMUX:end device-mirror-input-batch
        // SUPERMUX:begin terminal-input-pipeline
        supportsInputPipeline: @escaping @MainActor @Sendable () -> Bool = { false }
        // SUPERMUX:end terminal-input-pipeline
    ) {
        self.remoteWorkspaceID = remoteWorkspaceID
        self.remoteSurfaceID = remoteSurfaceID
        self.events = events
        self.isConnected = isConnected
        self.requestData = requestData
        self.viewer = viewer
        let attachment = DeviceTerminalAttachmentStatus()
        self.attachment = attachment
        let clientID = viewer?.clientID
        // SUPERMUX:begin terminal-input-pipeline
        var pipelineParams: [String: Any] = ["workspace_id": remoteWorkspaceID, "surface_id": remoteSurfaceID.uuidString]
        if let clientID { pipelineParams["client_id"] = clientID }
        let pipeline = SupermuxTerminalInputPipeline.forMirror(
            surfaceID: remoteSurfaceID,
            baseParams: pipelineParams,
            isSupported: supportsInputPipeline,
            canSend: { attachment.isConnected && isConnected() },
            request: { params in
                try Self.responseObject(try await requestData("mobile.terminal.input", params), method: "mobile.terminal.input")
            },
            onFailure: { error in
                deviceMirrorLog.error("device terminal input failed: \(String(describing: error), privacy: .private)")
            }
        )
        supermuxInputPipeline = pipeline
        // SUPERMUX:end terminal-input-pipeline
        inputRouter = DeviceTerminalInputRouter(
            // SUPERMUX:begin device-mirror-input-batch (an ordered batch: forwarded keys and exact bytes when the host takes them, else text)
            sendBatch: { @MainActor batch in
                guard attachment.isConnected, isConnected() else { throw DeviceLinkError.notConnected }
                var input: [String: Any] = [
                    "workspace_id": remoteWorkspaceID,
                    "surface_id": remoteSurfaceID.uuidString,
                ]
                input = try SupermuxDeviceTerminalInput.inputParams(batch, base: input, hostTakesBatches: supportsSupermuxInput())
            // SUPERMUX:end device-mirror-input-batch
                // The client id makes input sizing activity on the host and
                // lets the host refuse it while this Mac is disconnected.
                if let clientID { input["client_id"] = clientID }
                let response = try await requestData("mobile.terminal.input", input)
                _ = try Self.responseObject(response, method: "mobile.terminal.input")
            },
            onFailure: { error in
                deviceMirrorLog.error("device terminal input failed: \(String(describing: error), privacy: .private)")
            },
            // SUPERMUX:begin terminal-input-pipeline
            pipelined: { batch in await pipeline.offer(batch) }
            // SUPERMUX:end terminal-input-pipeline
        )
    }

    private static func responseObject(_ data: Data, method: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceLinkError.malformedResponse(method)
        }
        return object
    }

    private var surfaceParams: [String: Any] {
        ["workspace_id": remoteWorkspaceID, "surface_id": remoteSurfaceID.uuidString]
    }

    /// Applies the source grid to the local renderer. A participant also
    /// reports the pane's own grid whenever it changes.
    func bind(surface: TerminalSurface) {
        self.surface = surface
        if let assigned = assignedGrid {
            surface.setAssignedGrid(columns: assigned.columns, rows: assigned.rows)
        }
        guard viewer != nil else { return }
        sharingSurfaceID = surface.id
        // While the grid is pinned to the source Mac's, a pane resize changes
        // no Ghostty size, so it arrives here.
        surface.onNaturalGridInputsChanged = { [weak self] in
            // Hop out of the in-progress updateSize before re-reporting.
            Task { @MainActor [weak self] in self?.paneGridChanged() }
        }
        measurePaneGrid()
        // SUPERMUX:begin device-mirror-hidden-counts
        SupermuxTerminalSizingVisibility.shared.track(self, surface: surface)
        // SUPERMUX:end device-mirror-hidden-counts
    }

    func start() {
        guard phase == .idle else { return }
        phase = .attaching
        startEventConsumer()
        scheduleAttach()
    }

    func stop() {
        guard phase != .stopped else { return }
        phase = .stopped
        attachingBytes.removeAll()
        attachingByteCount = 0
        attachTask?.cancel()
        attachTask = nil
        eventTask?.cancel()
        eventTask = nil
        // SUPERMUX:begin terminal-stream-viewer
        supermuxStream?.stop()
        // SUPERMUX:end terminal-stream-viewer
        inputRouter.invalidate()
        // SUPERMUX:begin terminal-input-pipeline
        supermuxInputPipeline.invalidate()
        // SUPERMUX:end terminal-input-pipeline
        onAttached = nil
        adoptedRelay?.discard()
        adoptedRelay = nil
        leaveSharing()
        // SUPERMUX:begin device-mirror-hidden-counts
        if let surface { SupermuxTerminalSizingVisibility.shared.untrack(surfaceID: surface.id) }
        // SUPERMUX:end device-mirror-hidden-counts
        surface?.clearAssignedGrid()
        surface = nil
    }

    func retry() {
        guard phase != .stopped else { return }
        scheduleAttach()
    }

    /// Takes over a reserved pane's input. What was typed before an attach
    /// first sticks, including while a replay failed on a live link, belongs
    /// to this remote surface and is delivered in order once one does. If the
    /// link drops first, that input is discarded rather than sent to whatever
    /// shell the Mac has when it comes back. After an attach the router drops
    /// input typed while detached, as it does for panes it created itself, and
    /// stopping the session discards anything still held.
    func adopt(_ relay: CloudOptimisticInputRelay) {
        adoptedRelay = relay
        onAttached = { [weak self] in
            guard let self else { return }
            relay.attach(self.inputRouter)
        }
    }

    // MARK: - Attach and bytes

    private func startEventConsumer() {
        let stream = events.stream(surfaceID: remoteSurfaceID)
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.phase != .stopped else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: DeviceTerminalEvent) {
        switch event {
        case .bytes(let sequence, let data):
            // SUPERMUX:begin terminal-stream-grid-viewer (whether output flows around a replay)
            supermuxStream?.noteBytes(attaching: phase == .attaching)
            // SUPERMUX:end terminal-stream-grid-viewer
            if phase == .attaching {
                // SUPERMUX:begin terminal-stream-viewer (a streaming mirror holds far more while its resume is in flight; upstream: 512 chunks, 256 KB)
                let supermuxStreams = supermuxStream?.isActive == true
                let supermuxChunkLimit = supermuxStreams ? SupermuxTerminalStream.attachBufferChunkLimit : 512
                let supermuxByteLimit = supermuxStreams ? SupermuxTerminalStream.attachBufferByteLimit : 256 * 1_024
                guard sequence != nil, attachingBytes.count < supermuxChunkLimit, attachingByteCount + data.count <= supermuxByteLimit else {
                // SUPERMUX:end terminal-stream-viewer
                    replayNeeded = true
                    attachingBytes.removeAll()
                    attachingByteCount = 0
                    return
                }
                attachingBytes.append((sequence, data))
                attachingByteCount += data.count
                return
            }
            guard phase == .attached, let surface else { return }
            guard let sequence, let expected = expectedSequence else {
                surface.processRemoteOutput(data)
                return
            }
            let end = sequence &+ UInt64(data.count)
            if end <= expected { return }
            if sequence > expected {
                // A dropped chunk: the byte stream is not self-healing, so
                // re-anchor on a fresh replay instead of rendering a hole.
                // SUPERMUX:begin terminal-stream-viewer (a streaming host resumes from `expected` instead)
                supermuxStream?.noteGap()
                // SUPERMUX:end terminal-stream-viewer
                scheduleAttach()
                return
            }
            let offset = Int(expected - sequence)
            surface.processRemoteOutput(offset == 0 ? data : Data(data.dropFirst(offset)))
            expectedSequence = end
        case .updated(let columns, let rows):
            guard let columns, let rows, columns > 0, rows > 0 else { return }
            // SUPERMUX:begin terminal-stream-grid-viewer (a streaming mirror re-anchors on a replay pinned in stream order, never re-pins under bytes)
            if let supermuxStream, supermuxStream.isActive {
                supermuxStream.noteHostGrid(columns: columns, rows: rows)
                guard assignedGrid.map({ $0 != (columns, rows) }) ?? true else { return }
                switch phase {
                case .attached:
                    supermuxStream.gridChanged()
                    supermuxResyncGrid()
                case .detached:
                    // Upstream's way back for a mirror left detached on a live link.
                    supermuxStream.gridChanged()
                    scheduleAttach()
                case .attaching, .idle, .stopped:
                    break // an attach in flight checks the host's grid once its screen is applied
                }
                return
            }
            // SUPERMUX:end terminal-stream-grid-viewer
            if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
            // Repaint at the geometry the source Mac reports.
            pin(columns: columns, rows: rows)
            scheduleAttach()
        // SUPERMUX:begin terminal-stream-grid-viewer
        case .supermuxGridGeneration(let generation):
            guard let supermuxStream,
                  supermuxStream.streamedGridGeneration(generation, attached: phase == .attached) else { return }
            supermuxResyncGrid()
        // SUPERMUX:end terminal-stream-grid-viewer
        case .resyncRequired:
            if isConnected() {
                scheduleAttach()
            } else {
                linkDropped()
            }
        case .linkReconnected:
            scheduleAttach()
        case .linkLost:
            linkDropped()
        case let .sizeState(state, selfParticipantID):
            guard viewer?.receive(state, selfParticipantID: selfParticipantID) == true else { return }
            publishSharing()
        case let .sharingDetached(reason, at):
            guard viewer != nil else { return }
            viewer?.detached(TerminalSharingDetachment(reason: reason, at: at ?? Date()))
            publishSharing()
        }
    }

    /// Detaches and drops the reserved pane's held input: the next attach that
    /// sticks resumes forwarding from what is typed after it.
    private func linkDropped() {
        // SUPERMUX:begin terminal-stream-grid-viewer (the next connection may be another host process)
        supermuxGridResyncing = false
        supermuxStream?.linkLost()
        // SUPERMUX:end terminal-stream-grid-viewer
        adoptedRelay?.discard()
        if phase == .attached || phase == .attaching { phase = .detached }
        // SUPERMUX:begin device-mirror-sizing-claim (the next attach is a reconnect: push the claim again)
        SupermuxTerminalSizingDefaults.shared.connectionDropped(self)
        // SUPERMUX:end device-mirror-sizing-claim
        // SUPERMUX:begin device-mirror-hidden-counts (the other Mac drops this link's counts override with its connection: the re-attach sends it again, judged against the next host's state only; no publish, which would blank the size panel)
        supermuxHostHoldsHiddenCounts = false
        viewer?.connectionEnded()
        // SUPERMUX:end device-mirror-hidden-counts
    }

    // SUPERMUX:begin terminal-stream-grid-viewer
    /// Re-anchors an attached streaming mirror on a full replay because the
    /// other Mac's grid changed: live bytes wait for it (they were written for
    /// a grid this surface does not hold yet), typing keeps flowing.
    private func supermuxResyncGrid() {
        #if DEBUG
        cmuxDebugLog("supermux.terminal.mirror resync surface=\(remoteSurfaceID.uuidString.prefix(8)) phase=\(phase)")
        #endif
        guard phase == .attached else {
            scheduleAttach()
            return
        }
        supermuxGridResyncing = true
        phase = .attaching
        attachingBytes.removeAll(keepingCapacity: true)
        attachingByteCount = 0
        scheduleAttach()
    }

    /// After re-anchors that kept ending behind: look again later, so a mirror
    /// left on a stale grid recovers without waiting for the next resize.
    private func supermuxRecheckGrid(after nanoseconds: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, self.phase == .attached, let stream = self.supermuxStream,
                  stream.isBehind(assigned: self.assignedGrid) else { return }
            stream.gridChanged()
            self.supermuxResyncGrid()
        }
    }
    // SUPERMUX:end terminal-stream-grid-viewer

    /// Single-flight replay of the source screen, followed by sequenced live bytes.
    private func scheduleAttach() {
        guard phase != .stopped, attachTask == nil else {
            replayNeeded = attachTask != nil
            return
        }
        attachTask = Task { [weak self] in
            guard let self else { return }
            await self.attach()
            self.attachTask = nil
            if self.replayNeeded {
                self.replayNeeded = false
                self.scheduleAttach()
            }
        }
    }

    private func attach() async {
        guard phase != .stopped, isConnected() else {
            if phase != .stopped {
                adoptedRelay?.discard()
                phase = .detached
            }
            return
        }
        phase = .attaching
        attachingBytes.removeAll(keepingCapacity: true)
        attachingByteCount = 0
        // SUPERMUX:begin terminal-stream-grid-viewer
        supermuxStream?.attachStarted()
        // SUPERMUX:end terminal-stream-grid-viewer
        guard !Task.isCancelled, phase != .stopped else { return }
        // SUPERMUX:begin terminal-stream-viewer (watch this terminal on the connection before its replay captures)
        if let supermuxStream {
            _ = await supermuxStream.prepare()
            guard !Task.isCancelled, phase == .attaching else { return }
        }
        // SUPERMUX:end terminal-stream-viewer
        // SUPERMUX:begin terminal-stream-grid-viewer (a grid re-anchor waits until the grid holds still: a window dragged on the other Mac replays once it stops, not at every step)
        if supermuxGridResyncing, let supermuxStream, supermuxStream.isActive {
            await supermuxStream.awaitGridQuiet()
            guard !Task.isCancelled, phase == .attaching else { return }
        }
        // SUPERMUX:end terminal-stream-grid-viewer
        do {
            var params = surfaceParams
            // SUPERMUX:begin terminal-stream-viewer
            if let supermuxStream {
                params.merge(supermuxStream.replayParams(expectedSequence: expectedSequence, grid: assignedGrid)) { _, new in new }
            }
            // SUPERMUX:end terminal-stream-viewer
            // SUPERMUX:begin device-mirror-viewport-generations
            // Only the pane that speaks for this Mac on the terminal registers its
            // grid, above the link's floor; another pane follows the host's grid.
            // (upstream: `if let viewer, viewer.detachment == nil {`)
            if viewer?.detachment == nil, supermuxReportsGrid(), let viewer {
            // SUPERMUX:end device-mirror-viewport-generations
                // Register this Mac with its pane grid before the host captures.
                params.merge(viewer.replayParams()) { _, new in new }
                // SUPERMUX:begin device-mirror-hidden-counts
                if params["viewport_columns"] != nil, supermuxHidden != supermuxHostHoldsHiddenCounts {
                    if supermuxHidden, supermuxOwnCountsOverride == nil {
                        params["counts_override"] = false
                        supermuxHostHoldsHiddenCounts = true
                    } else if !supermuxHidden {
                        if supermuxOwnCountsOverride != true { params["counts_override"] = NSNull() }
                        supermuxHostHoldsHiddenCounts = false
                    }
                }
                // SUPERMUX:end device-mirror-hidden-counts
            }
            // SUPERMUX:begin terminal-stream-grid-viewer
            supermuxStream?.replayRequested()
            // SUPERMUX:end terminal-stream-grid-viewer
            let response = try await requestData("mobile.terminal.replay", params)
            // SUPERMUX:begin terminal-stream-viewer (a resumed reply carries the bytes since the mirror's position; upstream: `let replay = try await Self.decodeReplay(response)`)
            let supermuxReply = await SupermuxTerminalStream.decodeReply(response)
            let replay: Replay
            if let resumed = supermuxReply.resumed {
                replay = Replay(bytes: resumed.bytes, columns: resumed.columns, rows: resumed.rows, sequence: resumed.sequence, supermuxResumed: true)
            } else {
                replay = try await Self.decodeReplay(response)
            }
            // SUPERMUX:end terminal-stream-viewer
            guard !Task.isCancelled, phase == .attaching, isConnected() else { return }
            // SUPERMUX:begin terminal-stream-viewer
            supermuxStream?.noteReply(supermuxReply)
            // SUPERMUX:end terminal-stream-viewer
            viewportTransitionRetries = 0
            // SUPERMUX:begin device-mirror-replay-timed-out
            supermuxTimedOutRetries = 0
            // SUPERMUX:end device-mirror-replay-timed-out
            receiveReplaySizing(response)
            // SUPERMUX:begin terminal-stream-grid-viewer (pinned in stream order: output already handed to the surface is parsed at the grid it was written for, and the replay only once the surface holds the replay's grid; upstream: `if let columns = replay.columns, let rows = replay.rows { pin(columns: columns, rows: rows) }`)
            if let columns = replay.columns, let rows = replay.rows {
                if let surface {
                    await surface.supermuxPinInStreamOrder(columns: columns, rows: rows) { pin(columns: columns, rows: rows) }
                    guard !Task.isCancelled, phase == .attaching, isConnected() else { return }
                } else {
                    pin(columns: columns, rows: rows)
                }
            }
            // SUPERMUX:end terminal-stream-grid-viewer
            // SUPERMUX:begin terminal-stream-viewer (resumed bytes continue the screen as they are; a full replay first drops this Mac's history)
            if replay.supermuxResumed {
                surface?.processRemoteOutput(replay.bytes)
            } else {
            if supermuxStream?.isActive == true { surface?.processRemoteOutput(SupermuxTerminalStream.historyReset) }
            // SUPERMUX:end terminal-stream-viewer
            // SUPERMUX:begin device-mirror-viewer-colors (the replay, then every color settled to this Mac's theme plus the authored ones)
            surface?.processRemoteOutput(supermuxColors.bytes(applying: replay.bytes, colors: replay.colors))
            // SUPERMUX:end device-mirror-viewer-colors
            // SUPERMUX:begin terminal-stream-viewer
            }
            // SUPERMUX:end terminal-stream-viewer
            expectedSequence = replay.sequence
            // SUPERMUX:begin terminal-stream-grid-viewer (the screen is applied; if the grid moved during the round trip, the held bytes are for a grid it does not have: re-anchor once more instead of drawing them)
            if let supermuxStream, supermuxStream.isActive {
                let supermuxVerdict = supermuxStream.screenApplied(supermuxReply.gridGeneration, assigned: assignedGrid)
                #if DEBUG
                cmuxDebugLog("supermux.terminal.mirror applied surface=\(remoteSurfaceID.uuidString.prefix(8)) resumed=\(replay.supermuxResumed) seq=\(replay.sequence.map(String.init) ?? "nil") grid=\(assignedGrid.map { "\($0.columns)x\($0.rows)" } ?? "nil") gen=\(supermuxReply.gridGeneration.map(String.init) ?? "nil") verdict=\(supermuxVerdict) buffered=\(attachingBytes.count)")
                #endif
                switch supermuxVerdict {
                case .current:
                    break
                case .behind:
                    supermuxGridResyncing = true
                    phase = .attaching
                    attachingBytes.removeAll(keepingCapacity: true)
                    attachingByteCount = 0
                    replayNeeded = true
                    return
                case .retryLater(let nanoseconds):
                    supermuxRecheckGrid(after: nanoseconds)
                }
            }
            // SUPERMUX:end terminal-stream-grid-viewer
            phase = .attached
            // SUPERMUX:begin device-mirror-hidden-counts (a show or hide during the replay round trip)
            supermuxReconcileHiddenCounts()
            // SUPERMUX:end device-mirror-hidden-counts
            // SUPERMUX:begin device-mirror-sizing-claim (a shown mirror holds the grid, pushed once per connection)
            SupermuxTerminalSizingDefaults.shared.mirrorAttached(self)
            // SUPERMUX:end device-mirror-sizing-claim
            let buffered = attachingBytes
            attachingBytes.removeAll(keepingCapacity: true)
            attachingByteCount = 0
            // Discard bytes already covered by the replay, then apply the
            // remaining contiguous tail through the normal sequence check.
            for chunk in buffered { handle(.bytes(sequence: chunk.sequence, data: chunk.data)) }
            // SUPERMUX:begin terminal-stream-grid-viewer (a full replay taken while output flowed is confirmed by one taken once it is quiet)
            if !replay.supermuxResumed {
                supermuxStream?.fullReplayApplied { [weak self] in
                    guard let self, self.phase == .attached else { return }
                    self.supermuxResyncGrid()
                }
            }
            // SUPERMUX:end terminal-stream-grid-viewer
            // A replay queued meanwhile re-enters `.attaching` at once, which
            // drops input the router has not sent yet. Hand over held input
            // only on the attach that sticks.
            if !replayNeeded { onAttached?() }
        } catch DeviceLinkError.notConnected {
            guard phase != .stopped else { return }
            adoptedRelay?.discard()
            phase = .detached
        } catch {
            guard !Task.isCancelled, phase != .stopped else { return }
            // SUPERMUX:begin device-mirror-replay-timed-out
            // The replay missed its deadline but the link stayed up (a slow Mac is
            // not a lost Mac): ask again, as the reconnect used to, instead of
            // staying detached on a connected link.
            if SupermuxDeviceLinkEvents.isMissedDeadline(error), isConnected(), supermuxTimedOutRetries < 3 {
                supermuxTimedOutRetries += 1
                replayNeeded = true
                try? await Task.sleep(nanoseconds: SupermuxDeviceLinkEvents.missedDeadlineRetryDelayNanoseconds)
                return
            }
            // SUPERMUX:end device-mirror-replay-timed-out
            if Self.isViewportTransition(error), viewportTransitionRetries < 3 {
                // The host is applying this Mac's grid; the next replay
                // captures the settled grid.
                viewportTransitionRetries += 1
                replayNeeded = true
                // SUPERMUX:begin device-mirror-viewport-generations (50/100/200 ms between the retries)
                try? await Task.sleep(nanoseconds: SupermuxDeviceViewportGenerations.transitionRetryDelayNanoseconds(attempt: viewportTransitionRetries))
                // SUPERMUX:end device-mirror-viewport-generations
                return
            }
            deviceMirrorLog.error("device terminal replay failed: \(String(describing: error), privacy: .private)")
            phase = .detached
        }
    }

    private static func isViewportTransition(_ error: Error) -> Bool {
        String(describing: error).contains("viewport_transition")
    }

    private struct Replay: Sendable {
        let bytes: Data
        let columns: Int?
        let rows: Int?
        let sequence: UInt64?
        // SUPERMUX:begin device-mirror-viewer-colors
        /// Program-authored colors beside a render-grid replay; nil for a
        /// legacy replay, whose leading RIS resets every color.
        var colors: CloudTuiRemoteColors?
        // SUPERMUX:end device-mirror-viewer-colors
        // SUPERMUX:begin terminal-stream-viewer
        /// The host resumed from the mirror's byte position: `bytes` continue
        /// the screen as it is.
        var supermuxResumed = false
        // SUPERMUX:end terminal-stream-viewer
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated private static func decodeReplay(_ data: Data) async throws -> Replay {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceLinkError.malformedResponse("mobile.terminal.replay")
        }
        let sequence = (response["seq"] as? NSNumber)?.uint64Value
        if let raw = response["render_grid"] {
            let frame = try MobileTerminalRenderGridFrame.decodeJSONObject(raw)
            return Replay(
                // SUPERMUX:begin device-mirror-viewer-colors (this Mac's theme; only authored colors cross)
                bytes: SupermuxDeviceMirrorColors.themePortableBytes(frame),
                columns: frame.columns > 0 ? frame.columns : nil,
                rows: frame.rows > 0 ? frame.rows : nil,
                sequence: sequence,
                colors: SupermuxDeviceMirrorColors.authored(in: frame)
                // SUPERMUX:end device-mirror-viewer-colors
            )
        } else {
            let columns = (response["columns"] as? NSNumber)?.intValue
            let rows = (response["rows"] as? NSNumber)?.intValue
            var bytes = replayReset
            if let encoded = response["snapshot_data_b64"] as? String, let data = Data(base64Encoded: encoded) {
                bytes.append(data)
            } else if let encoded = response["data_b64"] as? String, let data = Data(base64Encoded: encoded) {
                bytes.append(data)
            }
            return Replay(bytes: bytes, columns: columns.flatMap { $0 > 0 ? $0 : nil }, rows: rows.flatMap { $0 > 0 ? $0 : nil }, sequence: sequence)
        }
    }

    /// `ESC c` (full reset) then `CSI 3 J` (drop scrollback): the replay is a
    /// replacement, so nothing from before it may survive.
    nonisolated private static let replayReset = Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A])

    // MARK: - Shared sizing (this Mac as a participant of the source Mac)

    @discardableResult
    private func measurePaneGrid() -> [String: Any]? {
        guard viewer != nil, let natural = surface?.naturalGridSize() else { return nil }
        // SUPERMUX:begin device-mirror-viewport-generations
        // Report above every generation the host saw from this link for this
        // terminal, an earlier pane's clear included; the host fences lower ones.
        // (upstream: `return viewer?.paneResized(…)`)
        // A pane whose grid changed speaks for this Mac on the terminal from now
        // on, unless it is off screen while another pane of the terminal is on
        // screen here: that one's grid is the one the user looks at.
        SupermuxDeviceViewportGenerations.shared.raise(&viewer, surfaceID: remoteSurfaceID)
        let report = viewer?.paneResized(TerminalGridSize(cols: natural.columns, rows: natural.rows))
        let speaks = report != nil
            && !(supermuxHidden && SupermuxTerminalSizingVisibility.shared.sibling(of: self, shown: true) != nil)
        SupermuxDeviceViewportGenerations.shared.record(
            viewer, surfaceID: remoteSurfaceID, reportedBy: speaks ? sharingSurfaceID : nil
        )
        return speaks ? report : nil
        // SUPERMUX:end device-mirror-viewport-generations
    }
    // SUPERMUX:begin device-mirror-viewport-generations

    /// Whether this pane's replay, re-report or automatic counts change
    /// carries its grid: not while another pane of the terminal on this link
    /// reported after it (this one follows that grid until its own pane
    /// resizes). When it does, the viewer is raised to the link's floor first,
    /// so the host does not fence it.
    private func supermuxReportsGrid() -> Bool {
        let generations = SupermuxDeviceViewportGenerations.shared
        guard !generations.defers(viewer, surfaceID: remoteSurfaceID, pane: sharingSurfaceID) else { return false }
        generations.raise(&viewer, surfaceID: remoteSurfaceID)
        return true
    }

    /// A pane that comes on screen speaks for this Mac from now on: the grid
    /// the user looks at is the one the other Mac should size for. Reported at
    /// once when attached; otherwise the next replay carries it.
    @discardableResult
    private func supermuxTakeOverGrid() -> Bool {
        let generations = SupermuxDeviceViewportGenerations.shared
        guard let pane = sharingSurfaceID, generations.reporter(of: viewer, surfaceID: remoteSurfaceID) != pane,
              viewer?.viewport != nil else { return false }
        generations.bump(&viewer, surfaceID: remoteSurfaceID)
        generations.record(viewer, surfaceID: remoteSurfaceID, reportedBy: pane)
        if phase == .attached, let report = viewer?.viewportParams() { sendSizing("mobile.terminal.viewport", report) }
        return true
    }

    /// Takes over speaking for this Mac from the pane that spoke, which went
    /// off screen or closes, and settles the counts it leaves: lifted when
    /// this pane is on screen, this Mac's automatic false when it is not.
    @discardableResult
    private func supermuxSpeakNow() -> Bool {
        guard supermuxTakeOverGrid() else { return false }
        if phase == .attached { supermuxReconcileHiddenCounts() }
        return true
    }

    /// The pane that speaks for this Mac went off screen: another pane of the
    /// terminal on this link that is on screen speaks now, instead of this one
    /// telling the other Mac that this Mac does not count.
    private func supermuxHandOverToShownPane() {
        guard !SupermuxDeviceViewportGenerations.shared.defers(viewer, surfaceID: remoteSurfaceID, pane: sharingSurfaceID),
              let heir = SupermuxTerminalSizingVisibility.shared.sibling(of: self, shown: true) else { return }
        heir.supermuxSpeakNow()
    }
    // SUPERMUX:end device-mirror-viewport-generations

    private func paneGridChanged() {
        // SUPERMUX:begin device-mirror-hidden-counts (a pane laid out for the first time just came on screen)
        if let surface { SupermuxTerminalSizingVisibility.shared.surfaceGeometryChanged(surface.id) }
        // SUPERMUX:end device-mirror-hidden-counts
        guard phase != .stopped, let report = measurePaneGrid(), phase == .attached else { return }
        sendSizing("mobile.terminal.viewport", report)
    }

    private func receiveReplaySizing(_ response: Data) {
        guard viewer != nil else { return }
        if let sizing = MobileTerminalReplaySizing.decodeIfPresent(response), let state = sizing.sizeState {
            viewer?.receive(state, selfParticipantID: sizing.selfParticipantID)
        }
        publishSharing()
        // The replay's report expires on the host's TTL; the dedicated
        // report keeps this Mac attached for the link's lifetime.
        // SUPERMUX:begin device-mirror-viewport-generations (only the pane that speaks for this Mac, above the floor; upstream: `if let report = viewer?.viewportParams() {`)
        if supermuxReportsGrid(), let report = viewer?.viewportParams() { sendSizing("mobile.terminal.viewport", report) }
        // SUPERMUX:end device-mirror-viewport-generations
    }

    /// Sends one sizing request; failures only log, since the next size
    /// state or replay reconciles.
    private func sendSizing(_ method: String, _ params: [String: Any]) {
        var params = params
        params.merge(surfaceParams) { current, _ in current }
        let requestData = requestData
        Task { @MainActor in
            do {
                _ = try await requestData(method, params)
            } catch {
                deviceMirrorLog.error("device terminal \(method, privacy: .public) failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func publishSharing() {
        guard let viewer, let surfaceID = sharingSurfaceID else { return }
        let controller = TerminalController.shared
        controller.ensureTerminalSharingPresentation()
        controller.terminalSharing.register(self, surfaceID: surfaceID)
        controller.terminalSharing.publish(viewer.snapshot, surfaceID: surfaceID)
    }

    /// Stops counting at once instead of waiting for the link to close.
    private func leaveSharing() {
        guard let viewer else { return }
        if let surfaceID = sharingSurfaceID {
            TerminalController.shared.terminalSharing.unregister(self, surfaceID: surfaceID)
        }
        surface?.onNaturalGridInputsChanged = nil
        // SUPERMUX:begin device-mirror-viewport-generations
        // A following pane sends no clear: it would drop the grid of the pane
        // that speaks for this Mac. The speaking pane hands over to another
        // open pane of the terminal (one on screen first), which reports its
        // grid; only the last one clears. The clear's generation fences this
        // terminal on the host. (upstream: `if viewer.viewport != nil, isConnected() { sendSizing(…clearParams()) }`)
        let supermuxSpeaks = !SupermuxDeviceViewportGenerations.shared.defers(viewer, surfaceID: remoteSurfaceID, pane: sharingSurfaceID)
        let supermuxVisibility = SupermuxTerminalSizingVisibility.shared
        let supermuxHeir = supermuxSpeaks && viewer.viewport != nil
            ? supermuxVisibility.sibling(of: self, shown: true) ?? supermuxVisibility.sibling(of: self, shown: false)
            : nil
        if supermuxSpeaks, viewer.viewport != nil, supermuxHeir?.supermuxSpeakNow() != true {
            if isConnected() { sendSizing("mobile.terminal.viewport", viewer.clearParams()) }
            SupermuxDeviceViewportGenerations.shared.recordClear(viewer, surfaceID: remoteSurfaceID, pane: sharingSurfaceID)
            // The host drops this Mac from the terminal, its counts override with it.
            supermuxHostHoldsHiddenCounts = false
        }
        // SUPERMUX:end device-mirror-viewport-generations
        sharingSurfaceID = nil
    }
    // SUPERMUX:begin device-mirror-hidden-counts

    /// Off screen, this mirror stops counting toward the other Mac's grid;
    /// back on screen, it counts by the automatic rule again. A counts
    /// override the user chose (Don't Resize from This Mac, Reattach as
    /// viewer) is never replaced: the automatic false is only set over no
    /// override and only lifted while it is still the one this set.
    func supermuxSetHidden(_ hidden: Bool) {
        guard hidden != supermuxHidden else { return }
        supermuxHidden = hidden
        // Shown, this pane's grid is the one this Mac reports for the terminal;
        // hidden, a pane of the terminal still on screen here speaks instead.
        if !hidden { supermuxTakeOverGrid() } else { supermuxHandOverToShownPane() }
        // Counts before the claim, as on attach: a claim that lands while this
        // Mac does not count yet falls back to someone else's grid for a round
        // trip. Not attached yet: the replay, or the reconcile after it, carries it.
        // A grid re-anchor keeps the link live, so it goes out now (terminal-stream-grid-viewer).
        if phase == .attached || supermuxGridResyncing { supermuxReconcileHiddenCounts() }
        // Shown, this Mac claims the terminal's grid again; hidden, it gives the claim up.
        SupermuxTerminalSizingDefaults.shared.mirrorVisibilityChanged(self)
    }

    private func supermuxReconcileHiddenCounts() {
        // A following pane leaves the counts to the pane that speaks for this Mac.
        guard supermuxHidden != supermuxHostHoldsHiddenCounts, supermuxReportsGrid() else { return }
        let value: Bool?
        if supermuxHidden {
            guard supermuxOwnCountsOverride == nil else { return }
            value = false
        } else {
            supermuxHostHoldsHiddenCounts = false
            // The false is this Mac's own (a user's choice clears the flag), so
            // lift it unless the other Mac shows a counts override of true.
            guard supermuxOwnCountsOverride != true else { return }
            value = nil
        }
        // Above every earlier report: panes of the terminal send these from
        // separate tasks, and the other Mac must apply them in this order.
        SupermuxDeviceViewportGenerations.shared.bump(&viewer, surfaceID: remoteSurfaceID)
        guard let report = viewer?.countsParams(value) else { return }
        if value == false { supermuxHostHoldsHiddenCounts = true }
        sendSizing("mobile.terminal.viewport", report)
    }

    /// This mirror's counts override as the host last published it.
    private var supermuxOwnCountsOverride: Bool? {
        guard let viewer, let id = viewer.selfParticipantID else { return nil }
        return viewer.state?.participant(id)?.participant.countsOverride
    }

    /// The user chose a counts override for this mirror: it is theirs now.
    private func supermuxUserChoseCounts() {
        supermuxHostHoldsHiddenCounts = false
    }
    // SUPERMUX:end device-mirror-hidden-counts
    // SUPERMUX:begin device-mirror-size-to-me

    /// Whether the other Mac's terminal is sized by this mirror now.
    var supermuxOwnsGrid: Bool {
        guard let viewer, let id = viewer.selfParticipantID else { return false }
        return viewer.state?.owners.contains(id) == true
    }

    /// This Mac's user wants the other Mac's grid here (Size to My Window,
    /// or the app becoming active with this mirror focused): this pane
    /// speaks for this Mac and reports its grid with `view_appeared: true`,
    /// which the other Mac notes as this viewer's activity in every mode
    /// (SupermuxTerminalSizingAuto), so a Fit everyone to Auto change sent
    /// just before it cannot race it. An older Mac ignores the key. Sent
    /// during a replay too (the link is up; the other Mac's grid change
    /// re-anchors this mirror right after the grid moves to someone else);
    /// not while detached, off screen or between connections.
    private func supermuxClaimGrid() {
        guard phase == .attached || phase == .attaching, isConnected(),
              !supermuxHidden, viewer?.detachment == nil else { return }
        let generations = SupermuxDeviceViewportGenerations.shared
        generations.bump(&viewer, surfaceID: remoteSurfaceID)
        if let pane = sharingSurfaceID { generations.record(viewer, surfaceID: remoteSurfaceID, reportedBy: pane) }
        guard var report = viewer?.viewportParams() else { return }
        report["view_appeared"] = true
        sendSizing("mobile.terminal.viewport", report)
    }
    // SUPERMUX:end device-mirror-size-to-me

    /// Pins only the mirror to the source grid; local resizing clips or letterboxes it.
    private func pin(columns: Int, rows: Int) {
        if let assigned = assignedGrid, assigned.columns == columns, assigned.rows == rows { return }
        assignedGrid = (columns, rows)
        surface?.setAssignedGrid(columns: columns, rows: rows)
    }
}

// MARK: - Size panel actions (TerminalSharingSurfaceControlling)

/// The size panel, tab accessory, context menu, palette and socket act on a
/// viewed Mac's terminal through the host's mobile RPC, as a phone does.
extension DeviceTerminalMirrorSession: TerminalSharingSurfaceControlling {
    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        guard viewer != nil else { return false }
        sendSizing("mobile.terminal.size_policy.set", ["policy": TerminalSizingWireCoder().jsonObject(policy)])
        return true
    }

    // SUPERMUX:begin sizing-one-setting
    /// A size mode the user picked on this mirror: `policy` for this
    /// terminal and, when `preference` is set, the setting the other Mac
    /// adopts for all its terminals (`supermux_preference`).
    func supermuxSendSizingChoice(_ policy: TerminalSizingPolicy, preference: [String: Any]?) -> Bool {
        guard viewer != nil else { return false }
        var params: [String: Any] = ["policy": TerminalSizingWireCoder().jsonObject(policy)]
        if let preference { params[SupermuxTerminalSizingDefaults.preferenceParam] = preference }
        sendSizing("mobile.terminal.size_policy.set", params)
        return true
    }
    // SUPERMUX:end sizing-one-setting

    /// The host's mobile RPC sets the counts override of this viewer only.
    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool {
        // SUPERMUX:begin device-mirror-viewport-generations (above the link's floor, or the host drops it)
        SupermuxDeviceViewportGenerations.shared.raise(&viewer, surfaceID: remoteSurfaceID)
        // SUPERMUX:end device-mirror-viewport-generations
        guard let viewer, participantID == viewer.selfParticipantID,
              let report = viewer.countsParams(value) else { return false }
        // SUPERMUX:begin device-mirror-hidden-counts
        supermuxUserChoseCounts()
        // SUPERMUX:end device-mirror-hidden-counts
        sendSizing("mobile.terminal.viewport", report)
        return true
    }

    /// The host names this Mac as the actor from its authenticated account
    /// and this client's reported device name.
    func sharingDisconnect(participantID: String, by: TerminalDetachActor?) -> Bool {
        guard let viewer else { return false }
        sendSizing("mobile.terminal.participant.disconnect", ["participant_id": participantID, "client_id": viewer.clientID])
        return true
    }

    /// Input already carries the client id, which the host records as
    /// activity; an explicit focus has no mobile RPC.
    func sharingNoteSelfActivity() {
        // SUPERMUX:begin device-mirror-size-to-me (Size to My Window, or switching to the app with this mirror focused, takes the other Mac's grid; upstream: an empty body)
        supermuxClaimGrid()
        // SUPERMUX:end device-mirror-size-to-me
    }

    func sharingReattach(asViewer: Bool) -> Bool {
        // SUPERMUX:begin device-mirror-viewport-generations (above the link's floor, or the host drops it)
        SupermuxDeviceViewportGenerations.shared.raise(&viewer, surfaceID: remoteSurfaceID)
        // SUPERMUX:end device-mirror-viewport-generations
        guard let viewer, viewer.detachment != nil else { return false }
        // SUPERMUX:begin device-mirror-hidden-counts
        supermuxUserChoseCounts()
        // SUPERMUX:end device-mirror-hidden-counts
        var params = viewer.reattachParams(asViewer: asViewer)
        params.merge(surfaceParams) { current, _ in current }
        let requestData = requestData
        Task { @MainActor [weak self] in
            do {
                _ = try await requestData("mobile.terminal.reattach", params)
                guard let self else { return }
                self.viewer?.reattached()
                self.publishSharing()
                // Re-anchor on a fresh replay: the host dropped this Mac's
                // viewport and input while it was disconnected.
                self.scheduleAttach()
            } catch {
                deviceMirrorLog.error("device terminal reattach failed: \(String(describing: error), privacy: .private)")
            }
        }
        return true
    }
}

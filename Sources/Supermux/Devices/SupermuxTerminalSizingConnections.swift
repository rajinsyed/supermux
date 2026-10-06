import CmuxMobileHost
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// The phone connection behind the sizing work running now.
///
/// A phone's connection id is known where its requests arrive, not where
/// sizing decides. This task-local carries it there:
///
/// - **An RPC** (`mobileHostHandleRPC` with an execution context) runs with
///   its connection's id, so a viewport report it writes is stamped with the
///   connection that wrote it, and a connection closing clears only the
///   reports it wrote (SUPERMUX-TOUCHPOINTS.md #957). Without the stamp a
///   phone that reconnected lost the report it had just sent on its new
///   connection when the old one's close arrived.
/// - **An IRX lane** (the runtime's lane loop, and the legacy dialect's lane
///   router for old phone builds, #1002) runs with the id of the control
///   connection of the same session, so a keystroke on the phone's input
///   lane is that phone's sizing activity and passes the detach gate (#960).
///
/// `nil` on the control socket: its reports stay unstamped and keep
/// upstream's behavior.
enum SupermuxMobileConnectionContext {
    @TaskLocal static var controlConnectionID: UUID?

    /// Whether the phone connection behind the running work is still open
    /// (true off a phone connection). A request handler that waited for the
    /// main actor can run after its connection closed: a report it wrote
    /// would carry the stamp of a connection whose close already ran, so no
    /// close would ever clear it (#1001).
    @MainActor
    static var isLive: Bool {
        guard let connectionID = controlConnectionID else { return true }
        return isOpen(connectionID)
    }

    /// Whether `connectionID` is an open phone connection. A connection
    /// leaves the registry before its close clears its reports.
    @MainActor
    static func isOpen(_ connectionID: UUID) -> Bool {
        if MobileHostConnectionRegistry.shared.connection(id: connectionID) != nil { return true }
        #if DEBUG
        // The sizing E2E's synthetic phone connections.
        return SupermuxTerminalSizingRecoveryDrivers.isOpenConnection(connectionID)
        #else
        return false
        #endif
    }
}

/// The phone connection whose generation-carrying viewport clear wrote a
/// generation fence (#1000).
///
/// A clear removes the phone's report and keeps its generation as a fence,
/// so a report the phone sent before the clear that arrives late is refused.
/// With the report gone, nothing named the connection that wrote the fence,
/// so another connection of the same phone closing (an older one, after a
/// reconnect) dropped it and the late report pinned the phone again. A close
/// reads the clear's connection as it reads a report's stamp, as long as the
/// fence still holds the clear's generation (a later report stamps itself).
@MainActor
enum SupermuxViewportFenceWriters {
    private struct Writer {
        let connectionID: UUID
        let generation: UInt64
    }

    private static var writers: [String: Writer] = [:]

    /// A viewport clear of `clientID` on `surfaceID` ran. `generation`: the
    /// fence a generation-carrying clear wrote, written by the running
    /// connection; nil when the clear left no fence of its own.
    static func noteClear(surfaceID: UUID, clientID: String, generation: UInt64?) {
        let entry = Self.key(surfaceID: surfaceID, clientID: clientID)
        guard let generation,
              let connectionID = SupermuxMobileConnectionContext.controlConnectionID,
              SupermuxMobileConnectionContext.isOpen(connectionID) else {
            writers[entry] = nil
            return
        }
        writers[entry] = Writer(connectionID: connectionID, generation: generation)
    }

    /// The connection whose clear wrote `fence`, the client's current
    /// generation fence on `surfaceID`; nil when no clear wrote it.
    static func writer(surfaceID: UUID, clientID: String, fence: UInt64?) -> UUID? {
        guard let writer = writers[Self.key(surfaceID: surfaceID, clientID: clientID)],
              writer.generation == fence else { return nil }
        return writer.connectionID
    }

    private static func key(surfaceID: UUID, clientID: String) -> String {
        "\(surfaceID.uuidString)/\(clientID)"
    }
}

/// A viewing Mac keeps its grid through a brief disconnect.
///
/// A connection that closes clears the viewport reports it wrote last
/// (#957). A viewing Mac's link redials within seconds of a relay drop and
/// each of its mirrors re-attaches with the grid it had, but clearing at
/// once resized every terminal it showed to its own pane, and back on the
/// re-attach. That moved each terminal's grid generation, so even an idle
/// terminal could not resume and came back as a multi-MB full replay
/// (2026-10-05 red run, D3). A Mac's report (`device_kind: mac`) is now
/// cleared ``grace`` after its connection closed, by the same
/// connection-scoped clear, so a report its reconnect wrote again by then
/// stays (it carries the new connection's stamp). A phone's report still
/// goes at once: the phone's sizing contract (and its E2E) times that clear.
///
/// The grace counts awake time only (the suspending clock) and starts over
/// at a full wake (``restartAfterWake()``): a connection closed before this
/// Mac slept would otherwise have its grace end the moment it woke, before
/// the viewer could redial, and every terminal it showed resized and came
/// back as a full replay (review S1).
@MainActor
enum SupermuxMacViewerCloseGrace {
    static let grace: Duration = .seconds(15)

    /// A closed connection's reports waiting for their clear.
    private struct Deferred {
        var clientIDs: Set<String> = []
        let reason: String
        var timer: Task<Void, Never>?
    }

    private static var deferred: [UUID: Deferred] = [:]
    /// The connection whose deferred clear runs now (it clears, not defers).
    private static var clearing: UUID?

    /// Whether the close of `connectionID` leaves this report (of
    /// `deviceKind`) for now; its clear then runs after ``grace``.
    static func defers(deviceKind: TerminalDeviceKind?, clientID: String, connectionID: UUID, reason: String) -> Bool {
        guard deviceKind == .mac, clearing != connectionID else { return false }
        if deferred[connectionID] == nil {
            deferred[connectionID] = Deferred(reason: reason)
            startGrace(connectionID)
        }
        deferred[connectionID]?.clientIDs.insert(clientID)
        return true
    }

    /// A full wake: every deferred clear waits a whole ``grace`` from now.
    /// The viewers' links redial after the wake, so their reports come back
    /// first.
    static func restartAfterWake() {
        for connectionID in deferred.keys { startGrace(connectionID) }
    }

    #if DEBUG
    /// The closed connections whose clear waits now (`power.close_grace`).
    static var deferredConnections: [UUID] { Array(deferred.keys) }
    #endif

    private static func startGrace(_ connectionID: UUID) {
        deferred[connectionID]?.timer?.cancel()
        deferred[connectionID]?.timer = Task { @MainActor in
            guard (try? await Task.sleep(for: grace, tolerance: nil, clock: .suspending)) != nil else { return }
            clear(connectionID: connectionID)
        }
    }

    private static func clear(connectionID: UUID) {
        guard let entry = deferred.removeValue(forKey: connectionID) else { return }
        #if DEBUG
        cmuxDebugLog("supermux.sizing mac close grace over connection=\(connectionID.uuidString.prefix(8)) clients=\(entry.clientIDs.count)")
        #endif
        clearing = connectionID
        defer { clearing = nil }
        TerminalController.shared.clearMobileViewportReports(
            clientIDs: entry.clientIDs, connectionID: connectionID, reason: entry.reason
        )
    }
}

/// A Cloud terminal's host hears a phone's lane typing at most once a second.
///
/// Each keystroke on the phone's input lane is its sizing activity (#960).
/// On a Cloud terminal that activity is a request to the cmux-tui host,
/// which the relay skips only while the phone alone owns the grid. In any
/// other case (Priority with this Mac first, Fit everyone) every keystroke
/// sent one.
@MainActor
enum SupermuxPhoneActivityThrottle {
    static let interval: Duration = .seconds(1)

    private static var lastRelay: [String: ContinuousClock.Instant] = [:]

    /// True when the phone's activity on `surfaceID` was last relayed at
    /// least `interval` ago (or never); records now when it was.
    static func admits(surfaceID: UUID, clientID: String) -> Bool {
        let now = ContinuousClock.now
        let key = "\(surfaceID.uuidString)/\(clientID)"
        if let last = lastRelay[key], now - last < interval { return false }
        if lastRelay.count >= 256 { lastRelay = lastRelay.filter { now - $0.value < interval } }
        lastRelay[key] = now
        return true
    }
}

/// A phone someone disconnected, told so again on each connection.
///
/// The Mac keeps a Disconnect for the terminal's life, while the phone keeps
/// it in memory only. A relaunched phone sent reports and replays that were
/// refused, with no Detached card to explain it. The first refusal on a
/// connection now pushes `mobile.terminal.detached` to the phone again, once
/// the connection subscribes to it: a refusal that arrives while its
/// `mobile.events.subscribe` is still in flight would drop the push, so it
/// leaves the next refusal to tell it.
@MainActor
enum SupermuxMobileDetachAnnouncements {
    /// Terminal and client pairs announced, by connection.
    private static var announced: [UUID: Set<String>] = [:]

    /// True the first time `clientID` is refused on `surfaceID` over
    /// `connectionID` while that connection subscribes to the push.
    static func firstRefusal(connectionID: UUID, surfaceID: UUID, clientID: String) -> Bool {
        guard MobileHostConnectionRegistry.shared.connection(id: connectionID)?.eventQueue
            .isSubscribed(topic: TerminalController.mobileDetachedTopic) == true else { return false }
        return announced[connectionID, default: []].insert("\(surfaceID.uuidString)/\(clientID)").inserted
    }

    static func connectionClosed(_ connectionID: UUID) {
        announced[connectionID] = nil
    }
}

extension TerminalController {
    /// One input frame on a phone's IRX input lane: refused (false) when
    /// someone disconnected that phone from the terminal, otherwise the
    /// phone's sizing activity, as `mobile.terminal.input` is
    /// (`mobileDetachedGateError`). The lane's control connection names the
    /// phone. Runs on every keystroke, so it stops at a few emptiness checks
    /// while no terminal is shared. A Cloud terminal's host hears it at most
    /// once a second per phone (`SupermuxPhoneActivityThrottle`).
    func supermuxAdmitLaneInput(surfaceID: UUID) -> Bool {
        guard let connectionID = SupermuxMobileConnectionContext.controlConnectionID,
              !localSizingHostsBySurfaceID.isEmpty || !cloudSizingRelaysBySurfaceID.isEmpty
                || !cloudDetachedPhonesBySurfaceID.isEmpty else { return true }
        let clientIDs = MobileHostService.shared.clientIDs(forConnectionID: connectionID)
        if clientIDs.contains(where: { isMobileClientDetached(surfaceID: surfaceID, clientID: $0) }) {
            return false
        }
        let relayed = cloudSizingRelaysBySurfaceID[surfaceID]?.value?.relaysPhones == true
        for clientID in clientIDs
        where !relayed || SupermuxPhoneActivityThrottle.admits(surfaceID: surfaceID, clientID: clientID) {
            noteMobileSizingActivity(surfaceID: surfaceID, clientID: clientID)
        }
        return true
    }

    /// The `detached` error's data: the detachment (`reason`, `by`, `at`)
    /// with `surface_id`. The first refusal on a phone connection also pushes
    /// `mobile.terminal.detached` to that phone again, so a phone that forgot
    /// it (a relaunch) shows the Detached card and Reattach.
    func supermuxDetachedErrorData(surfaceID: UUID, clientID: String) -> [String: Any] {
        let participantID = LocalTerminalSizingHost.phoneParticipantID(clientID: clientID)
        guard let detachment = cloudDetachedPhonesBySurfaceID[surfaceID]?[clientID]
            ?? localSizingHostsBySurfaceID[surfaceID]?.detachedPhones[participantID] else {
            return ["surface_id": surfaceID.uuidString]
        }
        if let connectionID = SupermuxMobileConnectionContext.controlConnectionID,
           SupermuxMobileDetachAnnouncements.firstRefusal(
               connectionID: connectionID, surfaceID: surfaceID, clientID: clientID
           ) {
            emitMobileDetached(surfaceID: surfaceID, clientID: clientID, detachment: detachment)
        }
        return TerminalSizingWireCoder().detachedPayload(surfaceID: surfaceID.uuidString, detachment: detachment)
    }
}

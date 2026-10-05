import CmuxTerminalSharing
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
/// - **An IRX lane** (the runtime's lane loop) runs with the id of the
///   control connection of the same session, so a keystroke on the phone's
///   input lane is that phone's sizing activity and passes the detach gate
///   (#960).
///
/// `nil` on the control socket and the legacy dialect: their reports stay
/// unstamped and keep upstream's behavior.
enum SupermuxMobileConnectionContext {
    @TaskLocal static var controlConnectionID: UUID?
}

/// A phone someone disconnected, told so again on each connection.
///
/// The Mac keeps a Disconnect for the terminal's life, while the phone keeps
/// it in memory only. A relaunched phone sent reports and replays that were
/// refused, with no Detached card to explain it. The first refusal on a
/// connection now pushes `mobile.terminal.detached` to the phone again.
@MainActor
enum SupermuxMobileDetachAnnouncements {
    /// Terminal and client pairs announced, by connection.
    private static var announced: [UUID: Set<String>] = [:]

    /// True the first time `clientID` is refused on `surfaceID` over `connectionID`.
    static func firstRefusal(connectionID: UUID, surfaceID: UUID, clientID: String) -> Bool {
        announced[connectionID, default: []].insert("\(surfaceID.uuidString)/\(clientID)").inserted
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
    /// while no terminal is shared.
    func supermuxAdmitLaneInput(surfaceID: UUID) -> Bool {
        guard let connectionID = SupermuxMobileConnectionContext.controlConnectionID,
              !localSizingHostsBySurfaceID.isEmpty || !cloudSizingRelaysBySurfaceID.isEmpty
                || !cloudDetachedPhonesBySurfaceID.isEmpty else { return true }
        let clientIDs = MobileHostService.shared.clientIDs(forConnectionID: connectionID)
        if clientIDs.contains(where: { isMobileClientDetached(surfaceID: surfaceID, clientID: $0) }) {
            return false
        }
        for clientID in clientIDs {
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

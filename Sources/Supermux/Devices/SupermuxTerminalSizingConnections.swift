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
}

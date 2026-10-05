import CmuxTerminalSharing
import Foundation

/// The phone connection behind the sizing work running now.
///
/// A phone's connection id is known where its requests arrive, not where
/// sizing decides. This task-local carries it there.
///
/// - **An RPC** (`mobileHostHandleRPC` with an execution context) runs with
///   its connection's id, so a viewport report it writes is stamped with the
///   connection that wrote it, and a connection closing clears only the
///   reports it wrote (SUPERMUX-TOUCHPOINTS.md #957). Without the stamp a
///   phone that reconnected lost the report it had just sent on its new
///   connection when the old one's close arrived.
///
/// `nil` on the control socket: its reports stay unstamped and keep
/// upstream's behavior.
enum SupermuxMobileConnectionContext {
    @TaskLocal static var controlConnectionID: UUID?
}

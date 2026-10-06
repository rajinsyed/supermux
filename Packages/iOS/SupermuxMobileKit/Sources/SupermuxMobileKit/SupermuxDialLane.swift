/// Which of the phone's two local endpoints a dial to a Mac went out on.
///
/// Both endpoints carry the same enrolled identity. They are separate because
/// iroh's relay policy is endpoint-wide.
public enum SupermuxDialLane: String, Sendable, Equatable {
    /// The direct-only endpoint (relay disabled), dialing the Mac's LAN or
    /// Tailscale addresses.
    case direct
    /// The automatic endpoint: the Mac's relay, plus any Private Addresses
    /// the user added for it.
    case automatic
}

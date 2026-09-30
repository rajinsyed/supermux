public import SwiftUI

/// Which Mac a row lives on, drawn as the small ``SupermuxRemoteMacIcon``
/// sized for a sidebar row (the Mac's name is in its tooltip). It replaced the
/// old name capsule; the type keeps its name and initializers so existing
/// rows (remote-only project headers among them) draw the icon unchanged.
/// New code uses ``SupermuxRemoteMacIcon`` directly.
public struct SupermuxDeviceChip: View {
    private let name: String
    private let state: SupermuxDeviceChipState
    private let fontScale: CGFloat

    /// Creates the icon.
    /// - Parameters:
    ///   - name: The Mac's name.
    ///   - isOnline: Whether its link is live.
    ///   - fontScale: Sidebar font scale (`1` at the default size).
    public init(name: String, isOnline: Bool, fontScale: CGFloat = 1) {
        self.init(name: name, state: isOnline ? .online : .offline, fontScale: fontScale)
    }

    /// Creates the icon for a Mac whose link may be dialing.
    /// - Parameters:
    ///   - name: The Mac's name.
    ///   - state: Its link state (dimmed unless ``SupermuxDeviceChipState/online``).
    ///   - fontScale: Sidebar font scale (`1` at the default size).
    public init(name: String, state: SupermuxDeviceChipState, fontScale: CGFloat = 1) {
        self.name = name
        self.state = state
        self.fontScale = fontScale
    }

    /// Creates the icon for a project device.
    public init(device: SupermuxProjectDevice, fontScale: CGFloat = 1) {
        self.init(name: device.name, state: SupermuxRemoteMacIcon.state(of: device), fontScale: fontScale)
    }

    public var body: some View {
        SupermuxRemoteMacIcon(name: name, state: state, pointSize: 9 * fontScale)
    }
}

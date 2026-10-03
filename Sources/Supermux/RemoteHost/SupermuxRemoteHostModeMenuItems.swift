import AppKit

/// SUPERMUX — Remote Host Mode's items in the menu bar item
/// (``MenuBarExtraController``, `remote-host-mode` touchpoint #831): Show
/// Supermux / Hide Supermux and Turn Off Remote Host Mode. They replace
/// upstream's Show cmux item while the mode is on and are hidden otherwise.
@MainActor
final class SupermuxRemoteHostModeMenuItems: NSObject {
    /// What an item does; also its id in the DEBUG socket snapshot.
    enum Action: String {
        case show, hide, turnOff = "turn_off"
    }

    private let mode: SupermuxRemoteHostMode
    private let toggleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let turnOffItem = NSMenuItem(
        title: String(localized: "supermux.remoteHost.menu.turnOff", defaultValue: "Turn Off Remote Host Mode"),
        action: nil,
        keyEquivalent: ""
    )

    override init() {
        mode = .shared
        super.init()
        toggleItem.target = self
        toggleItem.action = #selector(toggleAction)
        turnOffItem.target = self
        turnOffItem.action = #selector(turnOffAction)
    }

    /// Adds the items to `menu` right after `anchor` (upstream's Show cmux).
    func install(in menu: NSMenu, after anchor: NSMenuItem) {
        let index = menu.index(of: anchor)
        guard index >= 0 else { return }
        menu.insertItem(toggleItem, at: index + 1)
        menu.insertItem(turnOffItem, at: index + 2)
        refresh(upstreamShowItem: anchor)
    }

    /// Updates visibility and the Show/Hide title; hides upstream's Show
    /// item while the mode is on (the toggle replaces it).
    func refresh(upstreamShowItem: NSMenuItem?) {
        let enabled = SupermuxRemoteHostMode.isEnabled()
        toggleItem.isHidden = !enabled
        turnOffItem.isHidden = !enabled
        toggleItem.title = Self.title(for: currentToggle)
        if enabled {
            upstreamShowItem?.isHidden = true
        }
    }

    /// The visible items, in menu order (DEBUG socket snapshot).
    func visibleActions() -> [Action] {
        guard SupermuxRemoteHostMode.isEnabled() else { return [] }
        return [currentToggle, .turnOff]
    }

    /// Runs `action` as a click on its item would; `activate` false keeps the
    /// app in the background (E2E drivers).
    func perform(_ action: Action, activate: Bool = true) {
        switch action {
        case .show: mode.showAllWindows(activate: activate)
        case .hide: mode.hideAllWindows()
        case .turnOff: mode.turnOff(activate: activate)
        }
    }

    static func title(for action: Action) -> String {
        switch action {
        case .show: return String(localized: "supermux.remoteHost.menu.show", defaultValue: "Show Supermux")
        case .hide: return String(localized: "supermux.remoteHost.menu.hide", defaultValue: "Hide Supermux")
        case .turnOff: return String(localized: "supermux.remoteHost.menu.turnOff", defaultValue: "Turn Off Remote Host Mode")
        }
    }

    /// Show while no main window is on screen, Hide otherwise.
    private var currentToggle: Action {
        mode.isHeadless ? .show : .hide
    }

    @objc private func toggleAction() {
        perform(currentToggle)
    }

    @objc private func turnOffAction() {
        perform(.turnOff)
    }
}

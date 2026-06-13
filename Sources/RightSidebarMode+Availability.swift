import Foundation

extension RightSidebarMode {
    static func from(cliArgument rawValue: String) -> RightSidebarMode? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "files":
            return .files
        case "find":
            return .find
        case "vault", "sessions":
            return .sessions
        case "feed":
            return .feed
        case "dock":
            return .dock
        // SUPERMUX:begin right-sidebar-changes-mode-cli
        case "changes":
            return .changes
        // SUPERMUX:end right-sidebar-changes-mode-cli
        default:
            return nil
        }
    }

    static func availableModes(defaults: UserDefaults = .standard) -> [RightSidebarMode] {
        availableModes(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    static func availableModes(feedEnabled: Bool, dockEnabled: Bool) -> [RightSidebarMode] {
        allCases.filter { $0.isAvailable(feedEnabled: feedEnabled, dockEnabled: dockEnabled) }
    }

    func isAvailable(defaults: UserDefaults = .standard) -> Bool {
        isAvailable(
            feedEnabled: RightSidebarBetaFeatureSettings.isFeedEnabled(defaults: defaults),
            dockEnabled: RightSidebarBetaFeatureSettings.isDockEnabled(defaults: defaults)
        )
    }

    func isAvailable(feedEnabled: Bool, dockEnabled: Bool) -> Bool {
        switch self {
        // SUPERMUX:begin right-sidebar-changes-mode-available
        case .files, .find, .sessions, .changes:
        // SUPERMUX:end right-sidebar-changes-mode-available
            return true
        case .feed:
            return feedEnabled
        case .dock:
            return dockEnabled
        }
    }
}

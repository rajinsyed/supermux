public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// Pure presentation logic for the Claude harness session list.
///
/// Kept off the views so grouping, dot colours, and subtitle composition are
/// package-unit-testable without SwiftUI, and so no view under a lazy/list
/// boundary needs a store reference to decide what to draw (the SwiftUI
/// list-boundary rule in CLAUDE.md).
///
/// lint:allow namespace-enum — stateless projection helpers.
public enum SupermuxClaudeSessionPresentation {
    /// The colour of a session row's status dot.
    ///
    /// Ported from remodex's `SidebarThreadRunBadgeView` palette, minus its
    /// yellow "waiting on you" state: harness sessions never wait on a
    /// permission prompt, so a yellow dot would be a state that cannot occur.
    ///
    /// - Parameter indicator: The row's folded indicator.
    public static func dotColor(for indicator: SupermuxClaudeSessionIndicator) -> Color {
        switch indicator {
        case .working: .teal
        case .finishedUnopened: .blue
        case .failed: .red
        case .idle, .finished: .secondary
        }
    }

    /// Whether the row draws a dot at all. An idle session the user has
    /// already read carries no news, and a dot that is always present stops
    /// meaning anything.
    /// - Parameter indicator: The row's folded indicator.
    public static func showsDot(for indicator: SupermuxClaudeSessionIndicator) -> Bool {
        switch indicator {
        case .working, .finishedUnopened, .failed: true
        case .idle, .finished: false
        }
    }

    /// The VoiceOver label for a status dot. Each colour is a distinct state
    /// that no other part of the row repeats, so the dot has to speak.
    /// - Parameter indicator: The row's folded indicator.
    public static func dotAccessibilityLabel(
        for indicator: SupermuxClaudeSessionIndicator
    ) -> String {
        switch indicator {
        case .working:
            String(
                localized: "supermux.claude.state.working",
                defaultValue: "Working",
                bundle: .module
            )
        case .finishedUnopened:
            String(
                localized: "supermux.claude.state.finishedUnopened",
                defaultValue: "Finished, not opened yet",
                bundle: .module
            )
        case .failed:
            String(
                localized: "supermux.claude.state.failed",
                defaultValue: "Failed",
                bundle: .module
            )
        case .idle:
            String(localized: "supermux.claude.state.idle", defaultValue: "Ready", bundle: .module)
        case .finished:
            String(
                localized: "supermux.claude.state.finished",
                defaultValue: "Finished",
                bundle: .module
            )
        }
    }

    /// One group of sessions sharing a working directory.
    public struct Group: Identifiable, Equatable, Sendable {
        /// The group's working directory (also its identity).
        public let cwd: String
        /// The last path component, shown as the section header.
        public let title: String
        /// The group's sessions, in the order the store supplied them.
        public let sessions: [SupermuxClaudeSessionDTO]

        /// The stable identifier used by the list.
        public var id: String { cwd }

        /// Creates a group.
        /// - Parameters:
        ///   - cwd: The shared working directory.
        ///   - title: The header title.
        ///   - sessions: The group's sessions.
        public init(cwd: String, title: String, sessions: [SupermuxClaudeSessionDTO]) {
            self.cwd = cwd
            self.title = title
            self.sessions = sessions
        }
    }

    /// Groups sessions by working directory, preserving the store's ordering
    /// both inside each group and between groups.
    ///
    /// Order is preserved rather than re-sorted alphabetically so the most
    /// recently active project stays at the top: the store already sorted by
    /// activity, and re-sorting here would throw that away.
    ///
    /// - Parameter sessions: The store's sessions, most recent first.
    public static func groups(for sessions: [SupermuxClaudeSessionDTO]) -> [Group] {
        var order: [String] = []
        var byCWD: [String: [SupermuxClaudeSessionDTO]] = [:]
        for session in sessions {
            if byCWD[session.cwd] == nil {
                order.append(session.cwd)
                byCWD[session.cwd] = []
            }
            byCWD[session.cwd]?.append(session)
        }
        return order.map { cwd in
            Group(cwd: cwd, title: displayName(forPath: cwd), sessions: byCWD[cwd] ?? [])
        }
    }

    /// The display name for a directory: its last path component, falling
    /// back to the whole path (which is what "/" and a bare name both need).
    /// - Parameter path: An absolute Mac path.
    public static func displayName(forPath path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let last = trimmed.split(separator: "/").last else { return trimmed }
        return String(last)
    }

    /// The row's secondary line: the model, then the launcher when it is not
    /// plain Claude (naming the default on every row would be noise), then a
    /// queue count when the Mac is holding prompts.
    /// - Parameter session: The session snapshot.
    public static func subtitle(for session: SupermuxClaudeSessionDTO) -> String {
        var parts: [String] = []
        if let model = session.model, !model.isEmpty {
            parts.append(model)
        }
        if let launcher = launcherLabel(session.launcher) {
            parts.append(launcher)
        }
        if session.queuedCount > 0 {
            parts.append(String(
                localized: "supermux.claude.queued.count",
                defaultValue: "\(session.queuedCount) queued",
                bundle: .module
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// The launcher's row label, or `nil` for plain Claude.
    /// - Parameter launcher: The session's persisted launcher.
    public static func launcherLabel(_ launcher: SupermuxClaudeLauncher) -> String? {
        switch launcher {
        case .claude: nil
        case .ccx: "ccx"
        case .custom(let path): displayName(forPath: path)
        }
    }

    /// The formatted cost line, or `nil` before any turn has completed.
    /// - Parameter cost: The session's cumulative totals.
    public static func costLabel(_ cost: SupermuxClaudeCostDTO) -> String? {
        guard cost.turns > 0 else { return nil }
        return String(format: "$%.2f", cost.totalUSD)
    }
}

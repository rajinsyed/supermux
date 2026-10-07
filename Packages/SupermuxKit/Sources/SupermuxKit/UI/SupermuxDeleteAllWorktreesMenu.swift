import SwiftUI

/// Which Macs a project row's "Delete All Worktrees" offers: every Mac whose
/// copy of the project has a worktree, wherever on disk it lives (open
/// worktrees included: they are deleted too). An offline Mac stays listed and
/// is drawn disabled. The rows and the DEBUG `projects_presentation` socket
/// payload both build it here, so a test reads exactly what the menu offers.
public struct SupermuxDeleteAllWorktreesMenu: Equatable, Sendable {
    /// One Mac the menu offers.
    public enum Target: Hashable, Sendable {
        /// This Mac (the projects model).
        case thisMac
        /// Another Mac's copy, over its device link.
        case device(SupermuxProjectLocation)

        /// Whether the Mac can be asked now.
        public var isOnline: Bool {
            if case .device(let location) = self { return location.isOnline }
            return true
        }
    }

    /// The Macs offered, This Mac first.
    public let targets: [Target]

    /// A local project's row: this Mac when it has a worktree of the project,
    /// then each other Mac's copy that has one.
    /// - Parameters:
    ///   - worktrees: This Mac's worktrees of the project (main checkout excluded).
    ///   - extras: The project's other-Mac parts, if it has any.
    public init(worktrees: [SupermuxProjectWorktree], extras: SupermuxProjectRemoteExtras?) {
        let devices = (extras?.worktreeLocations ?? []).map(Target.device)
        targets = (worktrees.isEmpty ? [] : [.thisMac]) + devices
    }

    /// A project that exists only on another Mac: that Mac, when it has a
    /// worktree of the project.
    public init(remoteOnly row: SupermuxRemoteProjectRow) {
        targets = row.hasWorktrees ? [.device(row.location)] : []
    }
}

/// A project row's "Delete All Worktrees" context-menu item: one item when
/// only one Mac has worktrees and it is the one the row stands for (This Mac
/// for a local row, the row's Mac for a remote-only one), otherwise
/// "Delete All Worktrees on ▸" listing each Mac. Nothing when no Mac has one.
struct SupermuxDeleteAllWorktreesMenuItems: View {
    let menu: SupermuxDeleteAllWorktreesMenu
    /// The Mac a plain item stands for without naming it.
    let rowTarget: SupermuxDeleteAllWorktreesMenu.Target?
    let delete: (SupermuxDeleteAllWorktreesMenu.Target) -> Void

    var body: some View {
        if menu.targets.count == 1, let target = menu.targets.first, target == rowTarget {
            Button(
                String(localized: "supermux.project.deleteAllWorktrees", defaultValue: "Delete All Worktrees…"),
                role: .destructive
            ) { delete(target) }
            .disabled(!target.isOnline)
        } else if !menu.targets.isEmpty {
            Menu(String(localized: "supermux.project.deleteAllWorktreesOnMenu", defaultValue: "Delete All Worktrees on")) {
                ForEach(menu.targets, id: \.self) { target in
                    Button(Self.name(of: target), role: .destructive) { delete(target) }
                        .disabled(!target.isOnline)
                }
            }
        }
    }

    private static func name(of target: SupermuxDeleteAllWorktreesMenu.Target) -> String {
        switch target {
        case .thisMac: String(localized: "supermux.devices.thisMac", defaultValue: "This Mac")
        case .device(let location): location.device?.name ?? ""
        }
    }
}

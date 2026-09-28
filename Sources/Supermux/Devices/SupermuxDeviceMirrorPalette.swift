import AppKit
import CmuxCommandPalette
import Foundation

/// Command palette entry "Show Hidden Remote Workspaces": brings back every
/// remote workspace hidden with "Hide Here" (auto-mirror reopens them).
/// Registered by the `device-mirror-unhide-palette` touchpoints in
/// `ContentView.swift`; `supermux.devices.unhide` is the socket twin.
extension CommandPaletteCommandContribution {
    static let supermuxUnhideRemoteWorkspacesID = "palette.supermux.unhideRemoteWorkspaces"

    static var supermuxUnhideRemoteWorkspaces: Self {
        Self(
            commandId: supermuxUnhideRemoteWorkspacesID,
            title: { _ in
                String(localized: "supermux.devices.command.unhide.title", defaultValue: "Show Hidden Remote Workspaces")
            },
            subtitle: { _ in
                String(localized: "supermux.devices.command.unhide.subtitle", defaultValue: "Other Macs")
            },
            keywords: ["hidden", "hide", "unhide", "show", "remote", "mac", "device", "mirror", "workspace"]
        )
    }
}

extension CommandPaletteHandlerRegistry {
    @MainActor
    mutating func registerSupermuxDeviceMirrorCommands() {
        register(commandId: CommandPaletteCommandContribution.supermuxUnhideRemoteWorkspacesID) {
            MainActor.assumeIsolated {
                if SupermuxDeviceMirrorsGlue.unhide().isEmpty { NSSound.beep() }
            }
        }
    }
}

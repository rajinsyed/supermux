import CmuxSurfaceCatalogModel
import CmuxTerminal
import CmuxTerminalCore
import Foundation
import GhosttyKit

/// Which clipboard writes from a terminal reach this Mac's pasteboard.
///
/// Upstream drops every write from a remote terminal projection (SSH, tmux,
/// another Mac's terminal) unless the pane was made with remote clipboard
/// writes, which only Cloud panes were. Two kinds of write are the user's
/// own, and land here:
///
/// - **A program's copy in another of the user's Macs' terminals.** Claude
///   Code, tmux and nvim copy with OSC 52; in a device mirror that copy must
///   reach the clipboard of the Mac you are looking at. The other Mac is the
///   user's own (same account), so its panes are trusted like Cloud panes:
///   ``allowsProgramWrites(on:)``, read by the `device-mirror-clipboard`
///   touchpoints where device panes are built.
/// - **A copy this Mac's user makes**, in any terminal: a copy key, keyboard
///   copy mode's `y`, the mouse release that copies a selection
///   (copy-on-select). Those writes run inside this Mac's own input dispatch
///   on the surface (``GhosttySurfaceCallbackContext/isDispatchingRuntimeInput``),
///   where a program's OSC 52 never does: it arrives with the terminal's
///   output, outside any input call.
enum SupermuxTerminalClipboardWrites {
    /// Whether a terminal pane on `machine` may set this Mac's clipboard from
    /// its program (OSC 52): Cloud machines and the user's other Macs.
    static func allowsProgramWrites(on machine: SurfaceMachineID) -> Bool {
        machine.cloudMachineID != nil || machine.isDevice
    }

    /// Whether one `write_clipboard_cb` write from `surface` lands.
    static func allows(
        _ surface: TerminalSurface,
        context: GhosttySurfaceCallbackContext,
        location: ghostty_clipboard_e
    ) -> Bool {
        let allowed = surface.allowsAutomaticClipboardWrite || context.isDispatchingRuntimeInput
        #if DEBUG
        SupermuxTerminalClipboardSocketCommands.recordWrite(
            surfaceID: surface.id,
            location: location == GHOSTTY_CLIPBOARD_SELECTION ? "selection" : "standard",
            accepted: allowed
        )
        #endif
        return allowed
    }
}

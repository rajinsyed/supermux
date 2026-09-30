import GhosttyKit

extension GhosttyApp {
    /// Removes host-action defaults before loading user files. Otherwise clearing
    /// a cmux shortcut would revive Ghostty's fallback through the runtime callback.
    func loadGhosttyHostKeybindDefaults(_ config: ghostty_config_t) {
        let triggers = [
            "super+n", "super+t", "super+q", "super+,", "super+enter",
            "super+shift+p", "super+shift+[", "super+shift+]",
            "ctrl+tab", "ctrl+shift+tab", "super+alt+w", "super+shift+w",
            "super+alt+shift+w"
        ]
        loadInlineGhosttyConfig(
            triggers.map { "keybind = \($0)=unbind" }.joined(separator: "\n")
                + "\n" + Self.numberedWorkspaceGhosttyUnbinds,
            into: config,
            prefix: "cmux-host-keybind-defaults",
            logLabel: "host keybind defaults"
        )
    }

    func loadCmuxOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        // cmux owns these split, close, and workspace font-size shortcuts through
        // KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of running actions outside the
        // remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            keybind = super+ctrl+==unbind
            \(Self.numberedWorkspaceGhosttyUnbinds)
            """,
            into: config,
            prefix: "cmux-owned-keybind-overrides",
            logLabel: "cmux-owned keybind overrides"
        )
        // SUPERMUX:begin ghostty-unbind-split-zoom-return
        // supermux owns both Changes-panel commit chords (SupermuxChangesPanelView):
        // ⌘↩ (supermuxCommit) and ⇧⌘↩ (the accelerator, freed by rebinding Toggle
        // Pane Zoom to ⌃⌘Z). Ghostty's built-in defaults would otherwise consume
        // both in a focused terminal before the SwiftUI buttons can fire — the
        // same "rebind looks hardcoded because Ghostty keeps its fallback"
        // failure as the numbered-workspace unbinds above (cf. issue #5189):
        // `super+shift+enter = toggle_split_zoom` eats ⇧⌘↩, and
        // `super+enter = toggle_fullscreen` eats ⌘↩ (a dead no-op here: cmux has
        // no GHOSTTY_ACTION_TOGGLE_FULLSCREEN handler and binds fullscreen to
        // ⌃⌘F). Both defaults bind the physical Enter key, which these match.
        loadInlineGhosttyConfig(
            """
            keybind = super+shift+enter=unbind
            keybind = super+enter=unbind
            """,
            into: config,
            prefix: "supermux-owned-keybind-overrides",
            logLabel: "supermux-owned keybind overrides"
        )
        // SUPERMUX:end ghostty-unbind-split-zoom-return
    }

    /// Unbinds Ghostty's built-in `super+1…8 = goto_tab` / `super+9 = last_tab`
    /// fallbacks so the numbered "Select Workspace 1…9" shortcut is owned solely
    /// by `KeyboardShortcutSettings`.
    ///
    /// Without this, a `⌘1–9` remapped away in Settings still falls through to the
    /// focused terminal and Ghostty performs `goto_tab`, so the rebind looks
    /// hardcoded (https://github.com/manaflow-ai/cmux/issues/5189). Ghostty registers
    /// each digit under both its Unicode form (`super+1`) and its physical-key form
    /// (`super+digit_1`), so both are unbound here.
    private static let numberedWorkspaceGhosttyUnbinds: String = {
        (1...9).flatMap { digit in
            ["keybind = super+\(digit)=unbind", "keybind = super+digit_\(digit)=unbind"]
        }.joined(separator: "\n")
    }()

}

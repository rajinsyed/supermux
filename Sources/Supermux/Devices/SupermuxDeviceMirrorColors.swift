import AppKit
import CMUXMobileCore
import CmuxCloudTui
import Foundation

/// Device mirrors use this Mac's terminal appearance.
///
/// The other Mac's replay used to restore that Mac's default colors (OSC
/// 10/11/12) and palette, so every mirror pane got a pane-local background
/// override: the other Mac's color, painted by the pane itself instead of the
/// window's shared backdrop a local pane uses. With a translucent background
/// that looked opaque. Like upstream's Cloud mirror, the replay now carries no
/// color state (`replay-theme-portable`), and only the colors a program on the
/// other Mac set itself (OSC 4/10/11/12) travel beside it, as a sparse
/// ``CloudTuiRemoteColors`` set the mirror applies as a delta
/// (`device-mirror-viewer-colors`, ``SupermuxDeviceMirrorColorState``).
/// Live PTY bytes still carry a program's color sequences unchanged, as they
/// would to a local pane.
enum SupermuxDeviceMirrorColors {
    /// The replay's VT bytes without default colors or palette.
    nonisolated static func themePortableBytes(_ frame: MobileTerminalRenderGridFrame) -> Data {
        MobileTerminalRenderGridReplay(frame, includesColorState: false).patchBytes()
    }

    /// The colors a program on the other Mac set: its effective colors that
    /// differ from that Mac's configured ones. A Mac too old to export its
    /// configured colors yields none, so this Mac's theme wins.
    ///
    /// The frame's default foreground and background are raw (the producer
    /// undoes DEC reverse video, which the replay restores as a mode), so they
    /// compare directly with the configured defaults.
    nonisolated static func authored(in frame: MobileTerminalRenderGridFrame) -> CloudTuiRemoteColors {
        guard let config = frame.terminalConfigTheme else { return CloudTuiRemoteColors() }
        var colors = CloudTuiRemoteColors()
        colors.foreground = authored(frame.terminalForeground, configured: config.foreground)
        colors.background = authored(frame.terminalBackground, configured: config.background)
        colors.cursor = authored(
            frame.terminalCursorColor,
            configured: config.cursorColorSemantic == nil ? config.cursor : nil
        )
        if let palette = frame.terminalTheme?.palette {
            for index in palette.indices where config.palette.indices.contains(index) {
                colors.palette[index] = authored(palette[index], configured: config.palette[index])
            }
        }
        return colors
    }

    /// `value` as lowercase `#rrggbb` when it parses and differs from `configured`.
    nonisolated private static func authored(_ value: String?, configured: String?) -> String? {
        guard let rgb = TerminalTheme.rgbComponents(value) else { return nil }
        if let configuredRGB = TerminalTheme.rgbComponents(configured),
           configuredRGB.red == rgb.red, configuredRGB.green == rgb.green, configuredRGB.blue == rgb.blue {
            return nil
        }
        return String(format: "#%02x%02x%02x", rgb.red, rgb.green, rgb.blue)
    }

    /// The pane-local background override for an OSC background change.
    ///
    /// Ghostty reports a reset (OSC 111) as a change to the default color, and
    /// a stored override, even one equal to the default, makes the pane paint
    /// its own fill instead of sharing the window's backdrop. On a mirror pane
    /// (manual-mirror IO: device mirrors, and upstream's Cloud and remote
    /// mirrors), a change back to this Mac's default clears the override, so
    /// a program's reset (live, or a replay's authored-color delta) gives the
    /// pane its translucency back. Local panes keep upstream's behavior.
    static func surfaceBackgroundOverride(for color: NSColor, defaultColor: NSColor, isMirror: Bool) -> NSColor? {
        guard isMirror,
              let changed = color.usingColorSpace(.sRGB),
              let fallback = defaultColor.usingColorSpace(.sRGB) else { return color }
        let tolerance: CGFloat = 1.5 / 255
        let isDefault = abs(changed.redComponent - fallback.redComponent) <= tolerance
            && abs(changed.greenComponent - fallback.greenComponent) <= tolerance
            && abs(changed.blueComponent - fallback.blueComponent) <= tolerance
        return isDefault ? nil : color
    }
}

/// The program-authored colors a device mirror's surface holds, so each
/// replay sends only what changed. The theme-portable replay never resets
/// colors (it avoids RIS), so an entry that vanished must be reset here.
struct SupermuxDeviceMirrorColorState {
    private(set) var applied = CloudTuiRemoteColors()
    private var surfaceID: UUID?
    #if DEBUG
    /// Replays applied so far, and whether the last one's own bytes carried
    /// any color state (for `supermux.devices.mirror.terminal_background`).
    private(set) var replays = 0
    private(set) var lastReplayCarriedColorOSC = false
    #endif

    /// The bytes that apply one replay to `surfaceID`: its screen, then the
    /// authored-color delta. `colors` is nil for a legacy replay, which starts
    /// with a full reset (RIS) and so clears every color itself.
    mutating func bytes(applying replay: Data, colors: CloudTuiRemoteColors?, to surfaceID: UUID?) -> Data {
        // A surface this state never fed holds no authored colors.
        let previous = surfaceID == self.surfaceID ? applied : CloudTuiRemoteColors()
        self.surfaceID = surfaceID
        #if DEBUG
        replays += 1
        lastReplayCarriedColorOSC = Self.colorSequences.contains { replay.range(of: $0) != nil }
        #endif
        guard let colors else {
            applied = CloudTuiRemoteColors()
            return replay
        }
        applied = colors
        return replay + colors.oscDelta(from: previous)
    }

    #if DEBUG
    /// OSC 4/10/11/12 sets and OSC 104/110/111/112 resets.
    private static let colorSequences = ["4;", "10;", "11;", "12;", "104", "110", "111", "112"]
        .map { Data("\u{1B}]\($0)".utf8) }
    #endif
}

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
/// ``CloudTuiRemoteColors`` set every replay settles in full
/// (`device-mirror-viewer-colors`, ``settlingBytes(_:)``).
/// Live PTY bytes still carry a program's color sequences unchanged, as they
/// would to a local pane.
enum SupermuxDeviceMirrorColors {
    /// The replay's VT bytes without default colors or palette.
    static func themePortableBytes(_ frame: MobileTerminalRenderGridFrame) -> Data {
        MobileTerminalRenderGridReplay(frame, includesColorState: false).patchBytes()
    }

    /// The bytes that leave a mirror holding exactly `colors` over this Mac's
    /// theme, whatever it held before.
    ///
    /// Live PTY bytes can set or reset any color between replays, and a
    /// replay can follow a gap whose bytes never arrived (a lost link, a
    /// dropped chunk), so nothing this Mac recorded says what the surface
    /// holds. Each special color the program did not set is reset (OSC
    /// 110/111/112) and each one it did is set, never reset first, so an
    /// authored background does not flicker through the default. The palette
    /// is reset whole (OSC 104), then the authored entries set (OSC 4). A
    /// reset to this Mac's default is harmless on a mirror:
    /// ``surfaceBackgroundOverride(for:defaultColor:isMirror:)`` clears the
    /// pane override, so the pane keeps the shared backdrop.
    static func settlingBytes(_ colors: CloudTuiRemoteColors) -> Data {
        var resets = ""
        if colors.foreground == nil { resets += "\u{1B}]110\u{1B}\\" }
        if colors.background == nil { resets += "\u{1B}]111\u{1B}\\" }
        if colors.cursor == nil { resets += "\u{1B}]112\u{1B}\\" }
        resets += "\u{1B}]104\u{1B}\\"
        return Data(resets.utf8) + colors.oscBytes
    }

    /// The colors a program on the other Mac set: its effective colors that
    /// differ from that Mac's configured ones. A Mac too old to export its
    /// configured colors yields none, so this Mac's theme wins.
    ///
    /// The frame's default foreground and background are raw (the producer
    /// undoes DEC reverse video, which the replay restores as a mode), so they
    /// compare directly with the configured defaults.
    static func authored(in frame: MobileTerminalRenderGridFrame) -> CloudTuiRemoteColors {
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
    private static func authored(_ value: String?, configured: String?) -> String? {
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

/// Applies a device mirror's replays. The theme-portable replay never resets
/// colors (it avoids RIS), so each one is followed by
/// ``SupermuxDeviceMirrorColors/settlingBytes(_:)``. Nothing outside DEBUG is
/// stored: a replay settles every color, so none depends on an earlier one.
struct SupermuxDeviceMirrorColorState {
    #if DEBUG
    /// For `supermux.devices.mirror.terminal_background`: the program-authored
    /// colors the last replay set, how many replays were applied, and whether
    /// the last one's own screen bytes (before the settling sequences)
    /// carried any color state.
    private(set) var applied = CloudTuiRemoteColors()
    private(set) var replays = 0
    private(set) var lastReplayCarriedColorOSC = false
    #endif

    /// The bytes that apply one replay: its screen, then the sequences that
    /// settle every color to this Mac's theme plus `colors`. `colors` is nil
    /// for a legacy replay, which starts with a full reset (RIS) and so clears
    /// every color itself.
    mutating func bytes(applying replay: Data, colors: CloudTuiRemoteColors?) -> Data {
        #if DEBUG
        replays += 1
        lastReplayCarriedColorOSC = Self.colorSequences.contains { replay.range(of: $0) != nil }
        applied = colors ?? CloudTuiRemoteColors()
        #endif
        guard let colors else { return replay }
        return replay + SupermuxDeviceMirrorColors.settlingBytes(colors)
    }

    #if DEBUG
    /// OSC 4/10/11/12 sets and OSC 104/110/111/112 resets.
    private static let colorSequences = ["4;", "10;", "11;", "12;", "104", "110", "111", "112"]
        .map { Data("\u{1B}]\($0)".utf8) }
    #endif
}

#if DEBUG
import AppKit
import CmuxAppKitSupportUI
import CmuxCloudTui
import CmuxFoundation
import CmuxTerminal
import Foundation

/// `supermux.devices.mirror.terminal_background {surface_id}`: how a terminal
/// pane paints its background, for the mirror appearance E2E
/// (`tests/supermux/loopback_mirror_appearance_e2e.py`).
///
/// A device mirror must look like a local pane with this Mac's own
/// appearance. The payload reads the same inputs `applySurfaceBackground`
/// uses, plus what the pane's views actually hold, so a local terminal and a
/// mirror can be compared field by field:
/// - `background_override`: the pane-local OSC 11 color (`#RRGGBB`), or null.
/// - `fill_owner`: who paints the background (`shared` window backdrop,
///   `terminal` host layer, `bonsplit-pane`, `ghostty-native`).
/// - `host_layer_hex` / `host_layer_alpha`: the pane background view's fill.
/// - `backdrop_cutout_present`: whether the pane cut itself out of the shared backdrop.
/// - `app_background_hex` / `app_background_opacity`: this Mac's Ghostty defaults.
/// - for a device mirror: `mirror_phase`, and the colors its replays applied
///   (`applied_remote_colors`, `last_replay_color_osc`, `replays`).
@MainActor
enum SupermuxMirrorAppearanceSocket {
    static func terminalBackground(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["surface_id"] as? String, let surfaceID = UUID(uuidString: raw),
              let surface = TerminalController.shared.terminalSocketTarget(surfaceID: surfaceID)?.surface else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must name a terminal")
        }
        let hostedView = surface.hostedView
        let surfaceOverride = hostedView.surfaceView.backgroundColor
        let app = GhosttyApp.shared
        var payload: [String: Any] = [
            "surface_id": surfaceID.uuidString,
            "is_mirror": surface.ioMode == .manualMirror,
            "background_override": surfaceOverride?.hexString() ?? NSNull(),
            "fill_owner": fillPlan(surfaceOverride: surfaceOverride).logBackdropLabel,
            "backdrop_cutout_present": hostedView.subviews.contains { $0.compositingFilter != nil },
            "has_presented_frame": surface.hasPresentedFrame,
            "in_window": hostedView.window != nil,
            "app_background_hex": app.defaultBackgroundColor.hexString(),
            "app_background_opacity": app.defaultBackgroundOpacity,
        ]
        let hostLayer = hostedView.subviews.first { $0 is TerminalPaneBackgroundView }?.layer?.backgroundColor
        let hostLayerHex: Any = hostLayer.flatMap { NSColor(cgColor: $0)?.hexString() } ?? NSNull()
        payload["host_layer_hex"] = hostLayerHex
        payload["host_layer_alpha"] = hostLayer.map { Double($0.alpha) } ?? 0
        payload.merge(mirrorState(surfaceID)) { _, new in new }
        return payload
    }

    /// The fill plan `applySurfaceBackground` resolves for this override.
    private static func fillPlan(surfaceOverride: NSColor?) -> TerminalSurfaceBackgroundFillPlan {
        let app = GhosttyApp.shared
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: app.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        return TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: surfaceOverride,
            defaultBackgroundColor: app.defaultBackgroundColor,
            backgroundOpacity: app.defaultBackgroundOpacity,
            sharesWindowBackdrop: sharesWindowBackdrop,
            usesBonsplitPaneBackdrop: Workspace.usesBonsplitPaneTerminalBackdrop(
                renderingMode: renderingMode,
                sharesWindowBackdrop: sharesWindowBackdrop
            )
        )
    }

    /// The device-mirror session that feeds this pane, if it is one.
    private static func mirrorState(_ surfaceID: UUID) -> [String: Any] {
        let devices = SupermuxComposition.devices
        var found: DeviceTerminalMirrorSession?
        for device in devices.devices where found == nil {
            found = devices.provider(for: device.machine)?.sessions[surfaceID]
        }
        guard let session = found else {
            return ["mirror_phase": NSNull(), "applied_remote_colors": NSNull(), "last_replay_color_osc": NSNull(), "replays": NSNull()]
        }
        let colors = session.supermuxColors
        let lastReplayColorOSC: Any = colors.replays > 0 ? colors.lastReplayCarriedColorOSC : NSNull()
        return [
            "mirror_phase": String(describing: session.phase),
            "applied_remote_colors": sparse(colors.applied),
            "last_replay_color_osc": lastReplayColorOSC,
            "replays": colors.replays,
        ]
    }

    /// `{fg?, bg?, cursor?, palette?: {"<index>": "#rrggbb"}}`, only the entries a program set.
    private static func sparse(_ colors: CloudTuiRemoteColors) -> [String: Any] {
        var payload: [String: Any] = [:]
        if let foreground = colors.foreground { payload["fg"] = foreground }
        if let background = colors.background { payload["bg"] = background }
        if let cursor = colors.cursor { payload["cursor"] = cursor }
        if !colors.palette.isEmpty {
            payload["palette"] = Dictionary(uniqueKeysWithValues: colors.palette.map { (String($0.key), $0.value) })
        }
        return payload
    }
}
#endif

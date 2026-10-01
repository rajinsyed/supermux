#if DEBUG
import AppKit
import CmuxAppKitSupportUI
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
        let override = hostedView.surfaceView.backgroundColor
        let app = GhosttyApp.shared
        var payload: [String: Any] = [
            "surface_id": surfaceID.uuidString,
            "is_mirror": surface.ioMode == .manualMirror,
            "background_override": override?.hexString() ?? NSNull(),
            "fill_owner": fillPlan(override: override).logBackdropLabel,
            "backdrop_cutout_present": hostedView.subviews.contains { $0.compositingFilter != nil },
            "has_presented_frame": surface.hasPresentedFrame,
            "in_window": hostedView.window != nil,
            "app_background_hex": app.defaultBackgroundColor.hexString(),
            "app_background_opacity": app.defaultBackgroundOpacity,
        ]
        let hostLayer = hostedView.subviews.first { $0 is TerminalPaneBackgroundView }?.layer?.backgroundColor
        payload["host_layer_hex"] = hostLayer.flatMap { NSColor(cgColor: $0)?.hexString() } ?? NSNull()
        payload["host_layer_alpha"] = hostLayer.map { Double($0.alpha) } ?? 0
        payload.merge(mirrorState(surfaceID)) { _, new in new }
        return payload
    }

    /// The fill plan `applySurfaceBackground` resolves for this override.
    private static func fillPlan(override: NSColor?) -> TerminalSurfaceBackgroundFillPlan {
        let app = GhosttyApp.shared
        let renderingMode = WindowAppearanceSnapshot.terminalRenderingMode(
            usesHostLayerBackground: app.usesHostLayerBackground
        )
        let sharesWindowBackdrop = Workspace.usesWindowRootTerminalBackdrop()
        return TerminalSurfaceBackgroundFillPlan.resolve(
            renderingMode: renderingMode,
            surfaceBackgroundColor: override,
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
        let session = devices.devices.lazy
            .compactMap { devices.provider(for: $0.machine)?.sessions[surfaceID] }
            .first
        guard let session else {
            return ["mirror_phase": NSNull(), "applied_remote_colors": NSNull(), "last_replay_color_osc": NSNull(), "replays": NSNull()]
        }
        return [
            "mirror_phase": String(describing: session.phase),
            // Replays carry no colors of their own until the viewer-colors fix.
            "applied_remote_colors": NSNull(),
            "last_replay_color_osc": NSNull(),
            "replays": NSNull(),
        ]
    }
}
#endif

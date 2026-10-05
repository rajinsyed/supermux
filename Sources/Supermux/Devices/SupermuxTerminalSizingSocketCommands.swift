#if DEBUG
import AppKit
import CmuxBrowser
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// `supermux.devices.terminal_sizing.*` socket methods (DEBUG builds only):
/// E2E drivers for this Mac's terminal size preference
/// (`tests/supermux/loopback_terminal_sizing_policy_e2e.py`). Each runs the
/// same code path as its UI entry point. Routed from
/// ``SupermuxDevicesSocketCommands``.
///
/// - `state {}` — the stored preference and each device mirror's claim
///   (`null` where this build has none), with `pending_choice` while a pick
///   made on a detached mirror waits for its next attach, and
///   `adopted_remote_choices`: picks made on another Mac's mirror that this
///   Mac adopted as its setting.
/// - `reset {}` — forgets the stored preference and applies the default to
///   this Mac's terminals.
/// - `select_mode {surface_id, mode, fixed_cols?, fixed_rows?}` — the size
///   panel's mode picker; with `fixed_cols`/`fixed_rows`, its fixed-size editor.
/// - `set_priority {surface_id, keys}` — the size panel's priority drag.
/// - `portal_flicker {surface_id, hidden_ms, silent_reveal?}` — hides a shown
///   terminal pane the way the portal does during layout churn, rechecks every
///   pane's visibility as any window's occlusion change does, then lets the
///   portal reveal the pane `hidden_ms` later through its own synchronize pass;
///   with `silent_reveal`, un-hides it directly instead (a reveal path nothing
///   hears about).
/// - `local_key {surface_id, text?}` — this Mac's user typing into a shown
///   terminal: makes its window key and the terminal first responder
///   (activating the app when it is not active), then posts a key-down for
///   each character of `text` (default one space) to the app's event queue.
///   The run loop dequeues it and dispatches it through
///   `NSApplication.sendEvent`, as a key press: a socket handler calling
///   `sendEvent` itself is programmatic input, never the Mac's activity.
///
/// The sizing recovery drivers (`governor`, `reset_hosts`, `local_scroll`,
/// `activate`, `local_select`, `connection_request`, `connection_close`,
/// `lane_input`) live in ``SupermuxTerminalSizingRecoveryDrivers``.
@MainActor
enum SupermuxTerminalSizingSocketCommands {
    static let methodPrefix = "terminal_sizing."

    static func handles(_ name: String) -> Bool {
        name.hasPrefix(methodPrefix)
    }

    static func handle(_ name: String, params: [String: Any]) async throws -> [String: Any] {
        let method = String(name.dropFirst(methodPrefix.count))
        if SupermuxTerminalSizingRecoveryDrivers.methods.contains(method) {
            return try await SupermuxTerminalSizingRecoveryDrivers.handle(method, params: params)
        }
        switch method {
        case "state":
            return state()
        case "reset":
            SupermuxTerminalSizingDefaults.shared.reset()
            return ["reset": true, "preference": preferencePayload()]
        case "select_mode":
            return try selectMode(params)
        case "set_priority":
            return try setPriority(params)
        case "portal_flicker":
            return try portalFlicker(params)
        case "local_key":
            return try localKey(params)
        default:
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "unknown terminal_sizing method \(name)")
        }
    }

    // MARK: - Preference and claims

    private static func state() -> [String: Any] {
        let defaults = SupermuxTerminalSizingDefaults.shared
        let mirrors = SupermuxTerminalSizingVisibility.shared.trackedMirrorSessions()
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { entry -> [String: Any] in
                let session = entry.value
                return [
                    "surface_id": entry.key.uuidString,
                    "remote_surface_id": session.remoteSurfaceID.uuidString,
                    "hidden": session.supermuxHidden,
                    "attached": session.phase == .attached,
                    "self_key": session.viewer.map { SupermuxTerminalSizingDefaults.selfKey(of: $0) as Any } ?? NSNull(),
                    "claimed": session.supermuxSizingClaim.claimed,
                    "pushed": session.supermuxSizingClaim.pushed,
                    "pending_choice": session.supermuxSizingClaim.pendingChoice != nil,
                ]
            }
        return [
            "preference": preferencePayload(),
            "stored": defaults.isStored,
            "mirrors": mirrors,
            "adopted_remote_choices": defaults.adoptedRemoteChoices,
            "mac_activations": SupermuxTerminalSizingAuto.shared.macActivations,
        ]
    }

    private static func preferencePayload() -> [String: Any] {
        let preference = SupermuxTerminalSizingDefaults.shared.preference
        return [
            "mode": preference.mode.rawValue,
            "priority": preference.priority,
            "fixed": preference.fixed.map { ["cols": $0.cols, "rows": $0.rows] as Any } ?? NSNull(),
        ]
    }

    // MARK: - Panel actions

    private static func selectMode(_ params: [String: Any]) throws -> [String: Any] {
        let surfaceID = try surfaceID(params)
        guard let mode = (params["mode"] as? String).flatMap(TerminalSizingMode.init(rawValue:)) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "mode must be one of latest, smallest, largest, priority, fixed")
        }
        let store = TerminalController.shared.terminalSharing
        let defaults = SupermuxTerminalSizingDefaults.shared
        let accepted: Bool
        if let cols = (params["fixed_cols"] as? NSNumber)?.intValue, let rows = (params["fixed_rows"] as? NSNumber)?.intValue {
            accepted = defaults.userChoseFixedSize(TerminalGridSize(cols: cols, rows: rows), surfaceID: surfaceID, store: store)
        } else {
            accepted = defaults.userChoseMode(mode, surfaceID: surfaceID, store: store)
        }
        return payload(surfaceID, accepted: accepted)
    }

    private static func setPriority(_ params: [String: Any]) throws -> [String: Any] {
        let surfaceID = try surfaceID(params)
        guard let keys = params["keys"] as? [String], !keys.isEmpty else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "keys must be a non-empty list of priority keys")
        }
        let accepted = SupermuxTerminalSizingDefaults.shared.userChosePriority(
            keys, surfaceID: surfaceID, store: TerminalController.shared.terminalSharing
        )
        return payload(surfaceID, accepted: accepted)
    }

    // MARK: - Visibility

    private static func portalFlicker(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["surface_id"] as? String, let id = UUID(uuidString: raw),
              let surface = TerminalController.shared.terminalSocketTarget(surfaceID: id)?.surface else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must be a terminal id")
        }
        let pane = surface.hostedView
        guard let window = pane.window, !pane.isHidden else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the terminal's pane is not shown")
        }
        let hiddenMilliseconds = max(0, (params["hidden_ms"] as? NSNumber)?.intValue ?? 500)
        let silentReveal = (params["silent_reveal"] as? Bool) ?? false
        pane.isHidden = true
        SupermuxTerminalSizingVisibility.shared.recheckAll()
        Task { @MainActor in
            // Hold the pane hidden for the whole window: a pinned grid's own
            // layout pass may resynchronize the portal and reveal it early,
            // which would end the hide before the visibility rule settles.
            let deadline = ContinuousClock.now + .milliseconds(hiddenMilliseconds)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if !pane.isHidden {
                    pane.isHidden = true
                    SupermuxTerminalSizingVisibility.shared.recheckAll()
                }
            }
            if silentReveal {
                pane.isHidden = false
            } else {
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window, forceImmediate: true)
            }
        }
        return ["surface_id": id.uuidString, "hidden_ms": hiddenMilliseconds, "silent_reveal": silentReveal]
    }

    // MARK: - This Mac's user

    private static func localKey(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["surface_id"] as? String, let id = UUID(uuidString: raw),
              let surface = TerminalController.shared.terminalSocketTarget(surfaceID: id)?.surface else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must be a terminal id")
        }
        let view = surface.hostedView.surfaceView
        guard let window = view.window, !surface.hostedView.isHidden else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "the terminal's pane is not shown")
        }
        let text = (params["text"] as? String) ?? " "
        let keys = text.compactMap(SyntheticKeyEventFactory.specification(forASCIICharacter:))
        guard !text.isEmpty, keys.count == text.count else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "text must be plain ASCII characters")
        }
        let activated = !NSApp.isActive
        if activated { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        let focused = !surface.hostedView.isSurfaceViewFirstResponder()
        if focused { window.makeFirstResponder(view) }
        for key in keys {
            guard let event = SyntheticKeyEventFactory.keyEvent(
                specification: key, keyDown: true, timestamp: ProcessInfo.processInfo.systemUptime
            ) else {
                throw SupermuxMirrorSocketCommands.InvalidParams(message: "could not create a key event")
            }
            // No key-up, as `simulate_shortcut` sends none: a synthetic key-up
            // can stop the main run loop from draining the main queue.
            NSApp.postEvent(event, atStart: false)
        }
        return ["surface_id": id.uuidString, "posted": keys.count, "activated": activated, "focused": focused]
    }

    // MARK: - Helpers

    /// A local terminal gets its sizing host first, as opening its size panel does.
    private static func surfaceID(_ params: [String: Any]) throws -> UUID {
        let controller = TerminalController.shared
        guard let raw = params["surface_id"] as? String, let id = UUID(uuidString: raw) else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must be a terminal id")
        }
        if controller.terminalSharing.snapshot(for: id) == nil {
            _ = controller.localSizingHost(surfaceID: id, create: true)
        }
        guard controller.terminalSharing.snapshot(for: id) != nil else {
            throw SupermuxMirrorSocketCommands.InvalidParams(message: "surface_id must name a terminal with a size state")
        }
        return id
    }

    private static func payload(_ surfaceID: UUID, accepted: Bool) -> [String: Any] {
        var payload = TerminalController.shared.sizeStatePayload(surfaceID: surfaceID)
        payload["accepted"] = accepted
        return payload
    }
}
#endif

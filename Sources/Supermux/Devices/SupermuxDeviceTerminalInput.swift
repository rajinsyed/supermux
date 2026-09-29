import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation
import GhosttyKit
import SupermuxKit
import SupermuxMobileCore

/// Typing into another Mac's terminal through a device mirror behaves as
/// typing on that Mac.
///
/// A mirror pane is a local Ghostty surface fed with the other Mac's output.
/// Upstream sent that surface's own encoding of each key as text, and the
/// other Mac re-parsed it as typed text, so under the kitty keyboard protocol
/// (Claude Code) Esc became Escape plus a literal "[27u" and a mouse drag
/// became Esc presses. When the other Mac advertises
/// `supermux.terminal_input.v1`:
///
/// - Viewer: the pane's key-name resolver forwards every key press as a
///   ``SupermuxForwardedKeyEvent``, which travels in order with the pane's
///   other input (paste, mouse reports, binding text). The router drops the
///   mirror's own replies to terminal queries, since the other Mac answered
///   them. One `mobile.terminal.input` carries the ordered batch as
///   `supermux_input`.
/// - Host: bytes go to the PTY exactly (a Ghostty `text:` binding), and keys
///   go through Ghostty's key path, encoded with this Mac's terminal state,
///   exactly as a key pressed here. A key bound on this Mac never runs its
///   binding for the other Mac's keyboard.
///
/// Older Macs keep upstream's text path on both sides.
enum SupermuxDeviceTerminalInput {
    static let paramKey = "supermux_input"

    // MARK: - Viewer

    /// The key-name resolver for a device-mirror pane on `machine` (nil for
    /// other machines). It checks the other Mac's support on every key, so a
    /// pane made before the link connected starts forwarding once it does.
    static func keyResolver(for machine: SurfaceMachineID) -> (@MainActor @Sendable (ghostty_input_key_s) -> String?)? {
        guard machine.isDevice else { return nil }
        return { event in
            guard SupermuxForwardedKeyEvent.shouldForward(action: event.action.rawValue, composing: event.composing),
                  supportsForwardedInput(on: machine) else { return nil }
            return forwardedKey(event).keyName
        }
    }

    /// Whether the other Mac takes ordered input batches.
    @MainActor
    static func supportsForwardedInput(on machine: SurfaceMachineID) -> Bool {
        SupermuxComposition.devices.cachedHostCapabilities(on: machine)?
            .contains(SupermuxMobileCapability.terminalInputV1.rawValue) == true
    }

    static func forwardedKey(_ event: ghostty_input_key_s) -> SupermuxForwardedKeyEvent {
        let text = event.text.map { String(cString: $0) }
        return SupermuxForwardedKeyEvent(
            action: event.action.rawValue,
            mods: event.mods.rawValue,
            consumedMods: event.consumed_mods.rawValue,
            keycode: event.keycode,
            text: text?.isEmpty == false ? text : nil,
            unshiftedCodepoint: event.unshifted_codepoint
        )
    }

    /// What the input router queues for one manual-I/O event: bytes without
    /// the mirror's own terminal replies, or a forwarded key. Safe from
    /// Ghostty's I/O thread.
    static func batchItem(for input: TerminalManualInput) -> SupermuxTerminalInputBatch.Item? {
        switch input {
        case .bytes(let data):
            let kept = SupermuxTerminalReplyFilter.removingReplies(from: data)
            return kept.isEmpty ? nil : .bytes(kept)
        case .namedKey(let name):
            return SupermuxForwardedKeyEvent(keyName: name).map { .key($0) }
        }
    }

    /// A batch's bytes, for a sender that takes bytes only.
    static func bytes(of batch: SupermuxTerminalInputBatch) -> Data {
        batch.items.reduce(into: Data()) { bytes, item in
            if case .bytes(let data) = item { bytes.append(data) }
        }
    }

    /// The `mobile.terminal.input` params for one batch: the ordered batch
    /// (plus a text fallback) when the host takes batches, else upstream's text.
    static func inputParams(
        _ batch: SupermuxTerminalInputBatch,
        base: [String: Any],
        hostTakesBatches: Bool
    ) throws -> [String: Any] {
        var params = base
        if hostTakesBatches || batch.containsKeys {
            params[paramKey] = batch.wireEvents
            params["text"] = batch.fallbackText
        } else {
            guard let text = String(data: bytes(of: batch), encoding: .utf8) else {
                throw DeviceTerminalInputRouter.InputError.invalidEncoding
            }
            params["text"] = text
        }
        return params
    }

    // MARK: - Host

    /// The batch a `mobile.terminal.input` request carries, if any.
    static func batch(in params: [String: Any]) -> SupermuxTerminalInputBatch? {
        (params[paramKey] as? [Any]).flatMap(SupermuxTerminalInputBatch.init(wireEvents:))
    }

    /// Delivers a batch to this Mac's terminal, in order: bytes exactly,
    /// keys through Ghostty's key path. A terminal that has not started takes
    /// the batch's plain text, which queues it and starts the terminal.
    @MainActor
    static func deliver(_ batch: SupermuxTerminalInputBatch, to target: ControlTerminalSocketTarget) -> TerminalSurface.InputSendResult {
        target.resumeAgentHibernationForRemoteAttach()
        let surface = target.surface
        guard let live = surface.liveSurfaceForGhosttyAccess(reason: "supermux.deviceMirrorInput") else {
            return target.sendInputResult(batch.fallbackText)
        }
        guard !ghostty_surface_process_exited(live) else { return .processExited }
        surface.didReceiveExplicitInput()
        for item in batch.items {
            switch item {
            case .bytes(let data):
                _ = surface.performBindingAction(SupermuxTerminalInputBatch.ghosttyTextBinding(for: data))
            case .key(let key):
                press(key, on: live, surface: surface)
            }
        }
        surface.didAcceptExplicitInput()
        return .sent
    }

    @MainActor
    private static func press(_ key: SupermuxForwardedKeyEvent, on live: ghostty_surface_t, surface: TerminalSurface) {
        var event = ghostty_input_key_s()
        event.action = ghostty_input_action_e(rawValue: key.action)
        event.mods = ghostty_input_mods_e(rawValue: key.mods)
        event.consumed_mods = ghostty_input_mods_e(rawValue: key.consumedMods)
        event.keycode = key.keycode
        event.unshifted_codepoint = key.unshiftedCodepoint
        event.composing = false
        guard let text = key.text else {
            event.text = nil
            send(event, to: live, surface: surface)
            return
        }
        text.withCString { pointer in
            event.text = pointer
            send(event, to: live, surface: surface)
        }
    }

    @MainActor
    private static func send(_ event: ghostty_input_key_s, to live: ghostty_surface_t, surface: TerminalSurface) {
        var flags = ghostty_binding_flags_e(0)
        guard !ghostty_surface_key_is_binding(live, event, &flags) else { return }
        _ = surface.withRuntimeClipboardPasteIntent { ghostty_surface_key(live, event) }
    }
}

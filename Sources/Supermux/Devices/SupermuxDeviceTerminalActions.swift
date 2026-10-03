import AppKit
import CmuxSurfaceCatalogModel
import CmuxTerminal
import Foundation
import os
import SupermuxMobileCore

/// Terminal actions in another Mac's terminal (a device mirror pane) that
/// must change that terminal, not only this Mac's view of it.
///
/// A mirror is a local Ghostty surface fed with the other Mac's output, so a
/// key binding that acts on the terminal's own state ran only here: Cmd+K
/// (`clear_screen`) cleared this view while the other Mac kept its
/// scrollback, and the next replay (a re-attach, a resize) brought it all
/// back. When that Mac serves `supermux.terminal_actions.v1`, each
/// ``forwardedActions`` binding runs here AND there
/// (`mobile.supermux.terminal.action`), whichever way it was invoked (the key
/// binding, the `surface.clear_history` socket command). An older Mac keeps
/// today's local-only behavior.
///
/// `clear_screen` at a shell prompt also sends the shell a form feed so it
/// repaints. The other Mac's own clear sends that one; the form feed this
/// view's clear would send is dropped (``inputFilter(_:panelID:)``), so the
/// shell is asked to repaint once, as with Cmd+K there.
///
/// Focus reporting works the same way. A mirror's Ghostty never writes the
/// program's focus reports (mode 1004, which Claude Code and vim turn on):
/// it only mirrors the terminal, so it drops every report its terminal makes.
/// The mirror pane gaining or losing focus is sent as `focus_in` /
/// `focus_out` instead, and that Mac focuses or unfocuses its terminal, whose
/// Ghostty reports it to the program once, when the program asked for it.
///
/// Every other binding acts on this view only (select all, scrolling, copy,
/// font size, …) or already reaches the other Mac as input (Ctrl+L "Clear
/// Screen (Keep Scrollback)", `text:` bindings, pastes).
enum SupermuxDeviceTerminalActions {
    /// The key bindings that also run on the owning Mac.
    nonisolated static let forwardedBindings: Set<String> = ["clear_screen", "reset"]
    /// The focus changes the owning Mac applies to its terminal.
    nonisolated static let focusActions: Set<String> = ["focus_in", "focus_out"]
    /// Every action `terminal.action` takes.
    nonisolated static var forwardedActions: Set<String> { forwardedBindings.union(focusActions) }

    // MARK: - Forwarding

    /// Runs binding `action` on `surface`. For a device mirror pane whose Mac
    /// serves terminal actions, `locally` runs (with its form feed dropped)
    /// and the action is sent to that Mac; the result is `locally`'s. `nil`
    /// when this is not such an action or pane: the caller runs its own path.
    @MainActor
    static func perform(_ action: String, on surface: TerminalSurface, locally: () -> Bool) -> Bool? {
        guard forwardedBindings.contains(action), let target = forwardingTarget(for: surface) else { return nil }
        if action == "clear_screen" { armFormFeedDrop(panelID: surface.id) }
        let performed = locally()
        // The alternate screen is never cleared, so no form feed comes.
        if !performed { disarmFormFeedDrop(panelID: surface.id) }
        send(action, to: target)
        return performed
    }

    /// How long a pane's focus must hold before it is sent: switching
    /// workspaces or tabs can take focus away and give it back within one
    /// turn, which the program must not see as two focus changes.
    private static let focusSettleDelay: Duration = .milliseconds(120)
    /// The focus last sent for each pane, and the pending settle per pane.
    @MainActor private static var sentFocus: [UUID: Bool] = [:]
    @MainActor private static var focusSettles: [UUID: Task<Void, Never>] = [:]

    /// The mirror pane's focus changed (the `device-terminal-focus` hook on
    /// the pane's surface): once it settles, the owning Mac focuses or
    /// unfocuses its terminal. A focus equal to the one last sent is not sent.
    @MainActor
    static func focusChanged(_ surface: TerminalSurface, focused: Bool) {
        let panelID = surface.id
        focusSettles[panelID]?.cancel()
        focusSettles[panelID] = Task { @MainActor [weak surface] in
            try? await Task.sleep(for: focusSettleDelay)
            guard !Task.isCancelled else { return }
            focusSettles[panelID] = nil
            guard let surface, sentFocus[panelID] != focused,
                  let target = forwardingTarget(for: surface) else { return }
            sentFocus[panelID] = focused
            send(focused ? "focus_in" : "focus_out", to: target)
        }
    }

    @MainActor
    private static func send(_ action: String, to target: Target) {
        Task { @MainActor in
            do {
                _ = try await SupermuxComposition.devices.request(
                    .terminalAction,
                    params: [
                        "workspace_id": target.remoteWorkspaceID,
                        "terminal_id": target.remoteTerminalID,
                        "action": action,
                    ],
                    on: target.machine
                )
            } catch {
                #if DEBUG
                cmuxDebugLog("supermux.terminalAction failed action=\(action) error=\(error)")
                #endif
            }
        }
    }

    /// Whether `surface` is a device mirror pane whose Mac runs forwarded
    /// actions. Cheap for a local terminal (no catalog lookup).
    @MainActor
    static func forwardsActions(for surface: TerminalSurface) -> Bool {
        forwardingTarget(for: surface) != nil
    }

    private struct Target {
        let machine: SurfaceMachineID
        let remoteWorkspaceID: String
        let remoteTerminalID: String
    }

    @MainActor
    private static func forwardingTarget(for surface: TerminalSurface) -> Target? {
        guard surface.ioMode == .manualMirror,
              let device = deviceTerminal(for: surface),
              SupermuxComposition.devices.cachedHostCapabilities(on: device.machine)?
                .contains(SupermuxMobileCapability.terminalActionsV1.rawValue) == true else { return nil }
        return device
    }

    /// The other Mac's ids for a device mirror pane.
    @MainActor
    private static func deviceTerminal(for surface: TerminalSurface) -> Target? {
        guard let projection = SurfaceCatalog.shared.projection(forPanel: surface.id),
              projection.resource.machine.isDevice else { return nil }
        let machine = projection.resource.machine
        let mirror = surface.owningWorkspace().flatMap { SupermuxComposition.mirrorResolver.target(for: $0) }
        guard let workspaceID = projection.remoteWorkspaceID
                ?? (mirror?.machine == machine ? mirror?.remoteWorkspaceID : nil) else { return nil }
        return Target(machine: machine, remoteWorkspaceID: workspaceID, remoteTerminalID: projection.resource.key)
    }

    // MARK: - Ctrl+V of an image

    /// Whether Ctrl+V in `surface` pastes this Mac's clipboard image instead
    /// of reaching the program: a device mirror pane whose Mac stores pasted
    /// files, with an image and no text on the clipboard. There a program
    /// that reads the clipboard on Ctrl+V (Claude Code, Codex) would read the
    /// other Mac's clipboard, so the image is uploaded and its path pasted,
    /// as Cmd+V does. With text on the clipboard Ctrl+V goes through.
    @MainActor
    static func pastesImageOnControlV(in surface: TerminalSurface) -> Bool {
        guard surface.ioMode == .manualMirror, let device = deviceTerminal(for: surface),
              SupermuxComposition.devices.cachedHostCapabilities(on: device.machine)?
                .contains(SupermuxMobileCapability.terminalAttachmentsV1.rawValue) == true else { return false }
        let board = NSPasteboard.general
        guard board.string(forType: .string) == nil else { return false }
        return board.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    // MARK: - The local clear's form feed

    nonisolated private static let formFeed = Data([0x0C])
    /// How long an armed drop waits for the local clear's form feed.
    nonisolated private static let formFeedWindow: Duration = .seconds(1)
    nonisolated private static let armedDrops = OSAllocatedUnfairLock(initialState: [UUID: ContinuousClock.Instant]())

    /// Wraps a mirror pane's input handler (the `device-terminal-actions`
    /// touchpoint where manual-mirror panes are built) so the form feed of a
    /// forwarded clear is dropped. Only a lone form feed is ever looked at;
    /// every other input passes straight through.
    nonisolated static func inputFilter(
        _ onInput: @escaping @Sendable (TerminalManualInput) -> Void,
        panelID: UUID
    ) -> @Sendable (TerminalManualInput) -> Void {
        { input in
            if case .bytes(let data) = input, data == formFeed, consumeFormFeedDrop(panelID: panelID) { return }
            onInput(input)
        }
    }

    nonisolated private static func armFormFeedDrop(panelID: UUID) {
        let deadline = ContinuousClock.now + formFeedWindow
        armedDrops.withLock { $0[panelID] = deadline }
    }

    nonisolated private static func disarmFormFeedDrop(panelID: UUID) {
        armedDrops.withLock { _ = $0.removeValue(forKey: panelID) }
    }

    nonisolated private static func consumeFormFeedDrop(panelID: UUID) -> Bool {
        armedDrops.withLock { drops in
            guard let deadline = drops.removeValue(forKey: panelID) else { return false }
            return ContinuousClock.now <= deadline
        }
    }
}

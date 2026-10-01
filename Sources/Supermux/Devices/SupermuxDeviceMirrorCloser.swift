import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import OSLog
import SupermuxKit

private let mirrorCloseLog = Logger(subsystem: "dev.cmux", category: "supermux-mirror-close")

/// Close semantics for device mirrors (DESIGN.md decision 3).
///
/// - **User closes** (sidebar ×, context menu Close / Close Others / Below /
///   Above, ⌘⇧W, closing the last tab, a multi-close): exactly this Mac's own
///   confirmations, as for a local workspace (pinned, running process,
///   settings, the batch "Close workspaces?"), and no prompt of the fork's.
///   Once they pass, the mirror closes here at once and its workspace closes
///   on its Mac (`workspace.close` with `force`: the user already confirmed
///   here). A workspace pinned there is unpinned there, then closed. While
///   that Mac is offline the close waits in a persisted pending set, which
///   auto-mirror never reopens, and is sent once that Mac is back (even after
///   a relaunch). A refusal beeps and auto-mirror shows the workspace again.
///   A close not sent yet is cancelled when a local workspace shows that
///   remote workspace again (Reopen Closed Workspace, a manual open).
/// - **Hide Here** (the row menus): remembers the ref in the hidden set so
///   auto-mirror never reopens it, then closes the mirror here only.
/// - **Programmatic closes** of a mirror (socket, AppleScript, scripts):
///   treated as Hide Here.
/// - **Coordinator closes** (remote gone, orphan): nothing hidden, nothing
///   closed remotely.
/// - Internal closes (window close, app quit, session restore, bootstrap
///   cleanup — every `closeWorkspace(recordHistory: false)` caller) only drop
///   the binding.
///
/// Reached from the `device-mirror-close` touchpoints in `TabManager.swift`
/// through ``SupermuxDeviceMirrorCloseGate``.
@MainActor
final class SupermuxDeviceMirrorCloser {
    /// How long a sent close waits for its remote workspace to disappear (or
    /// a failed send waits) before it is sent again.
    static let resendDelay: TimeInterval = 10

    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private let hidden: SupermuxHiddenRemoteWorkspaces
    /// Remote workspaces closed here whose close their Mac has not done yet.
    private let pending: SupermuxHiddenRemoteWorkspaces
    /// Closes being sent, by ref.
    private var sends: [SupermuxRemoteWorkspaceRef: Task<Void, Never>] = [:]
    private var lastSent: [SupermuxRemoteWorkspaceRef: Date] = [:]
    /// Called when a remote close settles or the hidden set changed.
    var onChange: @MainActor () -> Void = {}
    /// Local closes whose bookkeeping (hide / unbind) is already done.
    private var decided: Set<UUID> = []
    #if DEBUG
    /// E2E hook (`supermux.devices.hold_remote_closes`): while true, pending
    /// closes are kept but not sent, so a test can check that auto-mirror
    /// leaves a pending ref alone while its record is still there.
    var debugHoldSends = false
    #endif

    init(
        devices: SupermuxDevices,
        index: SupermuxDeviceWorkspaceIndex,
        hidden: SupermuxHiddenRemoteWorkspaces,
        pending: SupermuxHiddenRemoteWorkspaces
    ) {
        self.devices = devices
        self.index = index
        self.hidden = hidden
        self.pending = pending
    }

    /// Remote workspaces closed here whose close is not done on their Mac yet
    /// (auto-mirror treats them as busy, so it never reopens them).
    var pendingRemoteCloses: Set<SupermuxRemoteWorkspaceRef> { pending.refs }

    // MARK: - Upstream hooks

    /// A user close that passed this Mac's close confirmations. False when the
    /// workspace is not a mirror (upstream closes it); otherwise closes the
    /// mirror here and its workspace on its Mac.
    func closeOnItsMac(_ workspace: Workspace, in manager: TabManager) -> Bool {
        guard let ref = mirrorRef(workspace) else { return false }
        pending.hide(ref)
        index.unbind(workspace)
        closeLocally(workspace, in: manager, recordHistory: true)
        mirrorCloseLog.info("closing \(ref.description, privacy: .public) on its Mac")
        sendPendingCloses()
        onChange()
        return true
    }

    /// Every `TabManager.closeWorkspace` passes here before teardown.
    func workspaceWillClose(_ workspace: Workspace, recordHistory: Bool) {
        if decided.contains(workspace.id) { return }
        guard let ref = mirrorRef(workspace) else { return }
        if let app = AppDelegate.shared, app.isTerminatingApp || app.isApplyingSessionRestore { return }
        if recordHistory {
            hidden.hide(ref)
            mirrorCloseLog.info("programmatic close hides \(ref.description, privacy: .public)")
            onChange()
        }
        index.unbind(workspace)
    }

    // MARK: - Pending remote closes

    /// Sends each pending close whose Mac is connected with fresh records, and
    /// forgets those whose remote workspace is gone. Runs on every auto-mirror
    /// pass, so a close made offline goes out once that Mac is back.
    func sendPendingCloses() {
        #if DEBUG
        if debugHoldSends { return }
        #endif
        let unsent = pending.refs.filter { sends[$0] == nil }
        guard !unsent.isEmpty else { return }
        // Mirrors only: a local workspace that merely borrows one of that
        // workspace's terminals does not bring it back.
        let shown = Set(index.mirrors().map(\.ref))
        let now = Date()
        for ref in unsent {
            // The user brought the mirror back (Reopen Closed Workspace, a
            // manual open): cancel the close instead of killing what they
            // reopened. The mirror just closed is no longer live, so it never
            // matches here.
            if shown.contains(ref) {
                mirrorCloseLog.info("\(ref.description, privacy: .public) is shown again; its close is cancelled")
                forget(ref)
                continue
            }
            guard let device = devices.device(for: ref.machine), device.isConnected, device.hasFetchedRecords else { continue }
            guard let remoteID = devices.record(for: ref)?.id else {
                forget(ref)
                continue
            }
            if let sent = lastSent[ref], now.timeIntervalSince(sent) < Self.resendDelay { continue }
            lastSent[ref] = now
            sends[ref] = Task { @MainActor [weak self] in
                await self?.send(ref, remoteID: remoteID)
            }
        }
    }

    private func send(_ ref: SupermuxRemoteWorkspaceRef, remoteID: String) async {
        defer {
            sends[ref] = nil
            onChange()
        }
        do {
            try await closeRemote(remoteID, on: ref)
            // Stays pending until the record is gone, so auto-mirror cannot
            // reopen it from a record that is about to disappear.
            mirrorCloseLog.info("closed \(ref.description, privacy: .public) on its Mac")
        } catch SupermuxDeviceError.notConnected {
            // Sent again as soon as that Mac is back.
            lastSent[ref] = nil
        } catch SupermuxDeviceError.hostRejected(let code, let message) {
            mirrorCloseLog.error("\(ref.description, privacy: .public) refused its close: \(message, privacy: .public)")
            forget(ref)
            if code != "not_found" { NSSound.beep() }
        } catch {
            mirrorCloseLog.error("close of \(ref.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.resendDelay * 1_000_000_000))
                self?.onChange()
            }
        }
    }

    /// `workspace.close` with force; a workspace pinned there answers
    /// `protected`, so it is unpinned there and closed again.
    private func closeRemote(_ remoteID: String, on ref: SupermuxRemoteWorkspaceRef) async throws {
        let params: [String: Any] = ["workspace_id": remoteID, "force": true]
        do {
            _ = try await devices.request("workspace.close", params: params, on: ref.machine)
        } catch SupermuxDeviceError.hostRejected(let code, _) where code == "protected" {
            _ = try await devices.request(
                "workspace.action", params: ["workspace_id": remoteID, "action": "unpin"], on: ref.machine
            )
            _ = try await devices.request("workspace.close", params: params, on: ref.machine)
        }
    }

    private func forget(_ ref: SupermuxRemoteWorkspaceRef) {
        pending.unhide(ref)
        lastSent[ref] = nil
    }

    // MARK: - Programmatic decisions (socket, row menus, coordinator)

    /// A user close of a mirror without this Mac's confirmations (the
    /// `close_mirror close_on_mac` socket method). Returns once the close was
    /// sent to its Mac, or at once while that Mac is offline.
    func closeOnMac(_ workspace: Workspace) async throws {
        guard let ref = mirrorRef(workspace), let manager = workspace.owningTabManager else {
            throw SupermuxDeviceError.hostRejected(code: "not_a_mirror", message: "The workspace is not a device mirror.")
        }
        _ = closeOnItsMac(workspace, in: manager)
        await sends[ref]?.value
    }

    /// Hides the mirror's remote workspace here and closes the mirror (no prompt).
    func hideHere(_ workspace: Workspace) -> Bool {
        guard let ref = mirrorRef(workspace), let manager = workspace.owningTabManager else { return false }
        hidden.hide(ref)
        index.unbind(workspace)
        closeLocally(workspace, in: manager, recordHistory: true)
        onChange()
        return true
    }

    /// "Hide Here" from a sidebar row's menu (by local workspace id): hides
    /// and closes that mirror, no prompt. False when it is not an open mirror.
    @discardableResult
    func hideHere(workspaceID: UUID) -> Bool {
        guard let workspace = Workspace.liveWorkspace(id: workspaceID) else { return false }
        return hideHere(workspace)
    }

    /// A coordinator close: local only, nothing hidden, nothing closed remotely.
    func closeForCoordinator(_ workspace: Workspace) {
        guard let manager = workspace.owningTabManager else { return }
        index.unbind(workspace)
        closeLocally(workspace, in: manager, recordHistory: false)
    }

    // MARK: - Internals

    private func mirrorRef(_ workspace: Workspace) -> SupermuxRemoteWorkspaceRef? {
        guard index.isDeviceMirror(workspace) else { return nil }
        return index.ref(forLocal: workspace)
    }

    private func closeLocally(_ workspace: Workspace, in manager: TabManager, recordHistory: Bool) {
        decided.insert(workspace.id)
        defer { decided.remove(workspace.id) }
        manager.closeWorkspace(workspace, recordHistory: recordHistory, allowEmptyingWindow: true)
    }
}

/// The static entry points the `device-mirror-close` touchpoints in
/// `TabManager.swift` call; they forward to the app's
/// ``SupermuxDeviceMirrorCloser``.
@MainActor
enum SupermuxDeviceMirrorCloseGate {
    static func closeOnItsMac(_ workspace: Workspace, in manager: TabManager) -> Bool {
        SupermuxComposition.deviceMirrorCloser.closeOnItsMac(workspace, in: manager)
    }

    static func workspaceWillClose(_ workspace: Workspace, recordHistory: Bool) {
        SupermuxComposition.deviceMirrorCloser.workspaceWillClose(workspace, recordHistory: recordHistory)
    }
}

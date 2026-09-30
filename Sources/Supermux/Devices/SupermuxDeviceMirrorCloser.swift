import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import OSLog
import SupermuxKit

private let mirrorCloseLog = Logger(subsystem: "dev.cmux", category: "supermux-mirror-close")

/// Close semantics for device mirrors (DESIGN.md decision 3).
///
/// - **User closes** (sidebar ×, context menu Close / Close Others / Below /
///   Above, ⌘⇧W, closing the last tab): one prompt — "Close “X” on <Mac>?" with
///   **Close on <Mac>** (closes the remote workspace over the device link, then
///   the mirror), **Hide Here** (remembers the ref in the hidden set so
///   auto-mirror never reopens it, then closes the mirror locally) and
///   **Cancel**. A multi-close holding several mirrors asks once for all of them.
/// - **Programmatic closes** of a mirror (socket, AppleScript, scripts): no
///   prompt, treated as Hide Here.
/// - **Coordinator closes** (remote gone, orphan): no prompt, nothing hidden,
///   nothing closed remotely.
/// - Internal closes (window close, app quit, session restore, bootstrap
///   cleanup — every `closeWorkspace(recordHistory: false)` caller) only drop
///   the binding.
///
/// Reached from the `device-mirror-close` touchpoints in `TabManager.swift`
/// through ``SupermuxDeviceMirrorCloseGate``.
@MainActor
final class SupermuxDeviceMirrorCloser {
    enum Decision: Equatable {
        case closeOnMac
        case hideHere
        case cancel
    }

    private let devices: SupermuxDevices
    private let index: SupermuxDeviceWorkspaceIndex
    private let hidden: SupermuxHiddenRemoteWorkspaces
    private let ask: @MainActor ([SupermuxDeviceMirrorClosePrompt.Item], TabManager) -> Decision

    /// Refs whose remote close is in flight, or finished moments ago while the
    /// closed record may still be in the synced state (auto-mirror must not
    /// reopen them).
    var pendingRemoteCloses: Set<SupermuxRemoteWorkspaceRef> {
        let now = Date()
        return inFlightRemoteCloses.union(heldAfterRemoteClose.filter { $0.value > now }.keys)
    }
    private var inFlightRemoteCloses: Set<SupermuxRemoteWorkspaceRef> = []
    private var heldAfterRemoteClose: [SupermuxRemoteWorkspaceRef: Date] = [:]
    /// How long a successfully closed remote workspace stays off auto-mirror
    /// while its removal delta arrives.
    static let remoteCloseHold: TimeInterval = 10
    /// Called when a remote close settles or the hidden set changed.
    var onChange: @MainActor () -> Void = {}
    /// Local closes whose bookkeeping (hide / unbind) is already done.
    private var decided: Set<UUID> = []
    /// Answers a batch prompt gave for its mirrors, until the batch ends.
    private var batchDecisions: [UUID: Decision] = [:]

    init(
        devices: SupermuxDevices,
        index: SupermuxDeviceWorkspaceIndex,
        hidden: SupermuxHiddenRemoteWorkspaces,
        ask: @escaping @MainActor ([SupermuxDeviceMirrorClosePrompt.Item], TabManager) -> Decision = SupermuxDeviceMirrorClosePrompt.ask
    ) {
        self.devices = devices
        self.index = index
        self.hidden = hidden
        self.ask = ask
    }

    // MARK: - Upstream hooks

    /// A user close of one workspace. Nil when it is not a mirror (upstream's
    /// close runs); otherwise whether the workspace was closed.
    func interceptUserClose(_ workspace: Workspace, in manager: TabManager) -> Bool? {
        guard let ref = mirrorRef(workspace) else { return nil }
        let decision = batchDecisions[workspace.id] ?? prompt([workspace], in: manager)
        return perform(decision, on: workspace, ref: ref, in: manager)
    }

    /// A user multi-close. Asks once for every mirror in it; when the batch is
    /// only mirrors it closes them itself (`handledAll`), otherwise the answer
    /// rides along until upstream's loop reaches each mirror.
    func beginBatch(_ workspaces: [Workspace], in manager: TabManager) -> SupermuxDeviceMirrorCloseBatch {
        let mirrors = workspaces.compactMap { workspace in mirrorRef(workspace).map { (workspace, $0) } }
        guard !mirrors.isEmpty else { return SupermuxDeviceMirrorCloseBatch(handledAll: false) }
        let decision = prompt(mirrors.map(\.0), in: manager)
        if decision == .cancel { return SupermuxDeviceMirrorCloseBatch(handledAll: true) }
        if mirrors.count == workspaces.count {
            for (workspace, ref) in mirrors where manager.tabs.contains(where: { $0.id == workspace.id }) {
                _ = perform(decision, on: workspace, ref: ref, in: manager)
            }
            return SupermuxDeviceMirrorCloseBatch(handledAll: true)
        }
        for (workspace, _) in mirrors { batchDecisions[workspace.id] = decision }
        let ids = mirrors.map(\.0.id)
        return SupermuxDeviceMirrorCloseBatch(handledAll: false) { [weak self] in
            for id in ids { self?.batchDecisions[id] = nil }
        }
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

    // MARK: - Programmatic decisions (socket, coordinator)

    /// Closes the remote workspace on its Mac, then the mirror (no prompt).
    /// Returns once the remote close settled.
    func closeOnMac(_ workspace: Workspace) async throws {
        guard let ref = mirrorRef(workspace), let manager = workspace.owningTabManager else {
            throw SupermuxDeviceError.hostRejected(code: "not_a_mirror", message: "The workspace is not a device mirror.")
        }
        try await closeRemotely(ref, closingLocal: workspace, in: manager)
    }

    /// Hides the mirror's remote workspace here and closes the mirror (no prompt).
    func hideHere(_ workspace: Workspace) -> Bool {
        guard let ref = mirrorRef(workspace), let manager = workspace.owningTabManager else { return false }
        return perform(.hideHere, on: workspace, ref: ref, in: manager)
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

    private func prompt(_ workspaces: [Workspace], in manager: TabManager) -> Decision {
        ask(promptItems(for: workspaces), manager)
    }

    /// The close prompt's rows for `workspaces` (also what the
    /// `supermux.devices.close_prompt` socket method describes).
    func promptItems(for workspaces: [Workspace]) -> [SupermuxDeviceMirrorClosePrompt.Item] {
        workspaces.compactMap { workspace -> SupermuxDeviceMirrorClosePrompt.Item? in
            guard let ref = index.ref(forLocal: workspace) else { return nil }
            let device = devices.device(for: ref.machine)
            return SupermuxDeviceMirrorClosePrompt.Item(
                title: workspace.customTitle ?? workspace.title,
                deviceName: device?.displayName ?? ref.machineID,
                isConnected: device?.isConnected ?? false
            )
        }
    }

    private func perform(_ decision: Decision, on workspace: Workspace, ref: SupermuxRemoteWorkspaceRef, in manager: TabManager) -> Bool {
        switch decision {
        case .cancel:
            return false
        case .hideHere:
            hidden.hide(ref)
            index.unbind(workspace)
            closeLocally(workspace, in: manager, recordHistory: true)
            onChange()
            return true
        case .closeOnMac:
            let remoteID = beginRemoteClose(ref, closingLocal: workspace, in: manager)
            Task { @MainActor [weak self] in
                do {
                    try await self?.finishRemoteClose(ref, remoteID: remoteID)
                } catch {
                    NSSound.beep()
                }
            }
            return true
        }
    }

    private func closeRemotely(
        _ ref: SupermuxRemoteWorkspaceRef,
        closingLocal workspace: Workspace,
        in manager: TabManager
    ) async throws {
        let remoteID = beginRemoteClose(ref, closingLocal: workspace, in: manager)
        try await finishRemoteClose(ref, remoteID: remoteID)
    }

    /// Closes the mirror locally at once, so the UI answers immediately, and
    /// holds auto-mirror off the ref until ``finishRemoteClose(_:remoteID:)``
    /// settles. Returns the host's spelling of the remote workspace id.
    private func beginRemoteClose(
        _ ref: SupermuxRemoteWorkspaceRef,
        closingLocal workspace: Workspace,
        in manager: TabManager
    ) -> String {
        let remoteID = devices.record(for: ref)?.id ?? ref.workspaceID
        inFlightRemoteCloses.insert(ref)
        index.unbind(workspace)
        closeLocally(workspace, in: manager, recordHistory: true)
        return remoteID
    }

    /// Closes the remote workspace on its Mac. If that fails the remote
    /// workspace still exists, so auto-mirror reopens its mirror.
    private func finishRemoteClose(_ ref: SupermuxRemoteWorkspaceRef, remoteID: String) async throws {
        defer {
            inFlightRemoteCloses.remove(ref)
            heldAfterRemoteClose = heldAfterRemoteClose.filter { $0.value > Date() }
            onChange()
        }
        do {
            _ = try await devices.request("workspace.close", params: ["workspace_id": remoteID], on: ref.machine)
            heldAfterRemoteClose[ref] = Date().addingTimeInterval(Self.remoteCloseHold)
            mirrorCloseLog.info("closed \(ref.description, privacy: .public) on its Mac")
        } catch {
            mirrorCloseLog.error("close on Mac failed for \(ref.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func closeLocally(_ workspace: Workspace, in manager: TabManager, recordHistory: Bool) {
        decided.insert(workspace.id)
        defer { decided.remove(workspace.id) }
        manager.closeWorkspace(workspace, recordHistory: recordHistory, allowEmptyingWindow: true)
    }
}

/// A multi-close's mirror answer, alive for the duration of
/// `TabManager.closeWorkspacesWithConfirmation`.
@MainActor
struct SupermuxDeviceMirrorCloseBatch {
    /// The fork handled the whole batch (cancelled, or closed every mirror).
    let handledAll: Bool
    fileprivate var onEnd: @MainActor () -> Void = {}

    fileprivate init(handledAll: Bool, onEnd: @escaping @MainActor () -> Void = {}) {
        self.handledAll = handledAll
        self.onEnd = onEnd
    }

    /// Forgets the batch's answers (called from a `defer` in the batch close).
    func end() { onEnd() }
}

/// The static entry points the `device-mirror-close` touchpoints in
/// `TabManager.swift` call; they forward to the app's
/// ``SupermuxDeviceMirrorCloser``.
@MainActor
enum SupermuxDeviceMirrorCloseGate {
    static func interceptUserClose(_ workspace: Workspace, in manager: TabManager) -> Bool? {
        SupermuxComposition.deviceMirrorCloser.interceptUserClose(workspace, in: manager)
    }

    static func beginBatch(_ workspaces: [Workspace], in manager: TabManager) -> SupermuxDeviceMirrorCloseBatch {
        SupermuxComposition.deviceMirrorCloser.beginBatch(workspaces, in: manager)
    }

    static func workspaceWillClose(_ workspace: Workspace, recordHistory: Bool) {
        SupermuxComposition.deviceMirrorCloser.workspaceWillClose(workspace, recordHistory: recordHistory)
    }
}

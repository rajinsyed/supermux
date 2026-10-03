#if DEBUG
import Foundation

/// DEBUG-only `supermux.devices.user_close` driver for
/// `tests/supermux/loopback_mirror_workspace_close_e2e.py`, routed from
/// ``SupermuxDevicesSocketCommands``:
///
/// - `user_close {workspace_id | workspace_ids, answer?: "close" | "cancel"}`:
///   closes the workspace the way the sidebar's × does
///   (`TabManager.closeWorkspaceWithConfirmation`), or several the way the
///   context menu's Close does (`closeWorkspacesWithConfirmation`). Every
///   upstream close confirmation it meets takes `answer` (default `close`)
///   without showing itself, and "Don't ask again" stays unticked. Returns
///   `result` (whether every workspace closed here), `prompts` (each
///   confirmation it met, in order: `{kind: "upstream", title}`; builds from
///   before mirrors closed like local workspaces also logged their own close
///   prompt as `kind: "mirror"`) and `still_open` (the ids still open here).
///   The workspaces must be in one window.
/// - `reopen_closed_workspace {}`: Reopen Closed Workspace (⌘⇧T) without
///   activating the window. Returns `reopened` and `workspace_ids` (the
///   workspaces it added).
/// - `hold_remote_closes {enabled}`: while enabled, closes waiting for their
///   Mac are kept but not sent (``SupermuxDeviceMirrorCloser/debugHoldSends``);
///   disabling runs an auto-mirror pass, which sends them. Returns `held`.
@MainActor
enum SupermuxDeviceMirrorCloseSocketCommands {
    static let methods: Set<String> = ["user_close", "reopen_closed_workspace", "hold_remote_closes"]

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether `name` (the part after `supermux.devices.`) is this driver.
    static func handles(_ name: String) -> Bool {
        methods.contains(name)
    }

    static func handle(_ name: String, _ params: [String: Any]) throws -> [String: Any] {
        switch name {
        case "reopen_closed_workspace": return reopenClosedWorkspace()
        case "hold_remote_closes": return try holdRemoteCloses(params)
        default: return try userClose(params)
        }
    }

    private static func reopenClosedWorkspace() -> [String: Any] {
        let before = Set(SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces().map(\.id))
        let reopened = AppDelegate.shared?.reopenMostRecentlyClosedWorkspace(shouldActivate: false) ?? false
        let added = SupermuxDeviceWorkspaceIndex.allMainWindowWorkspaces().map(\.id).filter { !before.contains($0) }
        return ["reopened": reopened, "workspace_ids": added.map(\.uuidString)]
    }

    private static func holdRemoteCloses(_ params: [String: Any]) throws -> [String: Any] {
        guard let enabled = params["enabled"] as? Bool else { throw HookError(message: "enabled (bool) is required") }
        SupermuxComposition.deviceMirrorCloser.debugHoldSends = enabled
        if !enabled { SupermuxComposition.deviceMirrorCoordinator.reconcileNow() }
        return ["held": enabled]
    }

    private static func userClose(_ params: [String: Any]) throws -> [String: Any] {
        let ids = try workspaceIDs(params)
        let accepts: Bool
        switch params["answer"] as? String ?? "close" {
        case "close": accepts = true
        case "cancel": accepts = false
        default: throw HookError(message: "answer must be close or cancel")
        }
        let workspaces = ids.compactMap { Workspace.liveWorkspace(id: $0) }
        guard workspaces.count == ids.count, let manager = workspaces.first?.owningTabManager,
              workspaces.allSatisfy({ $0.owningTabManager === manager }) else {
            throw HookError(message: "every workspace must be open, in one window")
        }

        let savedHandler = manager.confirmCloseHandler
        let savedDontAskAgain = manager.confirmCloseDontAskAgainHandler
        SupermuxDeviceMirrorCloseDebug.begin()
        manager.confirmCloseHandler = { title, _, _ in
            SupermuxDeviceMirrorCloseDebug.record(kind: "upstream", title: title)
            return accepts
        }
        manager.confirmCloseDontAskAgainHandler = { _ in false }
        defer {
            manager.confirmCloseHandler = savedHandler
            manager.confirmCloseDontAskAgainHandler = savedDontAskAgain
        }

        if workspaces.count == 1 {
            manager.closeWorkspaceWithConfirmation(workspaces[0])
        } else {
            manager.closeWorkspacesWithConfirmation(ids, allowPinned: true)
        }
        let stillOpen = ids.filter { Workspace.liveWorkspace(id: $0) != nil }
        return [
            "result": stillOpen.isEmpty,
            "prompts": SupermuxDeviceMirrorCloseDebug.prompts,
            "still_open": stillOpen.map(\.uuidString),
        ]
    }

    private static func workspaceIDs(_ params: [String: Any]) throws -> [UUID] {
        let raw: [String]
        if let many = params["workspace_ids"] as? [String] {
            raw = many
        } else if let one = params["workspace_id"] as? String {
            raw = [one]
        } else {
            throw HookError(message: "workspace_id or workspace_ids is required")
        }
        let ids = raw.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty, ids.count == raw.count else {
            throw HookError(message: "workspace ids must be UUIDs")
        }
        return ids
    }
}

/// The close confirmations the last `user_close` met.
@MainActor
enum SupermuxDeviceMirrorCloseDebug {
    private(set) static var prompts: [[String: Any]] = []

    static func begin() {
        prompts = []
    }

    static func record(kind: String, title: String) {
        prompts.append(["kind": kind, "title": title])
    }
}
#endif

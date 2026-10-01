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
///   confirmation it met, in order: `{kind: "upstream" | "mirror", title}`)
///   and `still_open` (the ids still open here). The workspaces must be in one
///   window.
@MainActor
enum SupermuxDeviceMirrorCloseSocketCommands {
    static let method = "user_close"

    struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Whether `name` (the part after `supermux.devices.`) is this driver.
    static func handles(_ name: String) -> Bool {
        name == method
    }

    static func handle(_ params: [String: Any]) throws -> [String: Any] {
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
            SupermuxDeviceMirrorCloseDebug.end()
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

/// The close confirmations one `user_close` met, while it runs.
@MainActor
enum SupermuxDeviceMirrorCloseDebug {
    /// Whether a `user_close` is running (a fork close prompt then records
    /// itself and answers Cancel without showing).
    private(set) static var isRecording = false
    private(set) static var prompts: [[String: Any]] = []

    static func begin() {
        isRecording = true
        prompts = []
    }

    static func end() {
        isRecording = false
    }

    static func record(kind: String, title: String) {
        prompts.append(["kind": kind, "title": title])
    }
}
#endif

import Foundation
import SupermuxKit
import SupermuxMobileCore

/// The owner's side of `mobile.supermux.workspace.set_order`: another Mac (a
/// dragged mirror) or the phone (a nested drag) asks this Mac to give one of
/// its workspaces a new order key. The row moves as a normal reorder of its
/// own tab, clamped by its pin tier and group, and the reply carries the key
/// it holds afterwards, which every device then shows.
///
/// Requests are served in arrival order on the main actor; the last one wins.
///
/// ```
/// → {"workspace_id": "<this Mac's Workspace.id>", "order_key": "a0V", "is_pinned": false}
/// ← {"workspace_id": "...", "order_key": "<the key it holds now>"}
/// ```
@MainActor
final class SupermuxWorkspaceOrderHost {
    /// A request answered with an error.
    struct Refusal: Error {
        /// The wire error code: `invalid_params`, `not_found`, `not_owned`,
        /// `conflict`, `unavailable` or `method_not_found`.
        let code: String
        let message: String
    }

    private let reconciler: SupermuxWorkspaceOrderReconciler
    private let index: SupermuxDeviceWorkspaceIndex
    private let tabManagers: @MainActor () -> [TabManager]
    private let isReady: @MainActor () -> Bool
    private let orderKey = SupermuxOrderKey()

    init(
        reconciler: SupermuxWorkspaceOrderReconciler,
        index: SupermuxDeviceWorkspaceIndex,
        tabManagers: @escaping @MainActor () -> [TabManager] = SupermuxMobileSidebarStatusObserver.allTabManagers,
        isReady: @escaping @MainActor () -> Bool = SupermuxDeviceMirrorCoordinator.appIsReady
    ) {
        self.reconciler = reconciler
        self.index = index
        self.tabManagers = tabManagers
        self.isReady = isReady
    }

    /// Serves one `set_order` request.
    /// - Parameter params: `{workspace_id, order_key, is_pinned}`.
    /// - Returns: `{workspace_id, order_key}`, or the refusal.
    func setOrder(_ params: [String: Any]) -> Result<[String: Any], Refusal> {
        guard SupermuxOrderDebugMode.current.servesOrderSync else {
            // An older Mac (DEBUG old_host) does not know the method.
            return .failure(Refusal(code: "method_not_found", message: "Unknown mobile method"))
        }
        let result = serve(params)
        var refused = false
        if case .failure = result { refused = true }
        reconciler.countSetOrder(refused: refused)
        return result
    }

    private func serve(_ params: [String: Any]) -> Result<[String: Any], Refusal> {
        guard let rawID = params["workspace_id"] as? String,
              let workspaceID = UUID(uuidString: rawID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(Refusal(code: "invalid_params", message: "workspace_id must be a workspace UUID"))
        }
        guard let key = params["order_key"] as? String, orderKey.isValid(key) else {
            return .failure(Refusal(code: "invalid_params", message: "order_key must be a valid order key"))
        }
        guard let isPinned = params["is_pinned"] as? Bool else {
            return .failure(Refusal(code: "invalid_params", message: "is_pinned must be a boolean"))
        }
        guard isReady() else {
            return .failure(Refusal(code: "unavailable", message: "This Mac is still restoring its windows"))
        }
        let managers = tabManagers()
        guard let manager = managers.first(where: { $0.tabs.contains { $0.id == workspaceID } }),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return .failure(Refusal(code: "not_found", message: "No workspace \(workspaceID.uuidString) on this Mac"))
        }
        guard !index.isDeviceMirror(workspace) else {
            return .failure(Refusal(code: "not_owned", message: "That workspace belongs to another Mac"))
        }
        guard workspace.isPinned == isPinned else {
            return .failure(Refusal(code: "conflict", message: "The workspace's pin changed"))
        }
        let held = reconciler.moveOwnRow(workspace, toKey: key, in: manager) ?? key
        return .success(["workspace_id": workspace.id.uuidString, "order_key": held])
    }
}

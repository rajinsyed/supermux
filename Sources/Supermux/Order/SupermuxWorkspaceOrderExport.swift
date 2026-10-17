import Foundation

/// The shared order key this Mac exports for one of its workspaces, as
/// `supermux_order_key` on both transports: the legacy `mobile.workspace.list`
/// row (`mobile-supermux-workspace-fields` fence in
/// `Sources/TerminalController+MobileWorkspaceList.swift`) and the v2
/// `WorkspaceSyncRecord` (`supermux-mobile-workspace-fields` fence in
/// `Sources/Mobile/MobileStateSync.swift`). Both read this one function, so
/// the two transports can never disagree on a key.
@MainActor
enum SupermuxWorkspaceOrderExport {
    /// The workspace's order key, or `nil` when none travels: for a mirror of
    /// another Mac's workspace (only its owner writes its key), before the app
    /// is ready, and while this Mac does not serve `supermux.order_sync.v1`
    /// (DEBUG `order_debug old_host`). Otherwise the key the
    /// ``SupermuxWorkspaceOrderReconciler`` stored for it, if it has one yet.
    ///
    /// - Parameter workspace: The workspace being serialized.
    /// - Returns: The key to send, or `nil` to omit the field.
    static func key(for workspace: Workspace) -> String? {
        guard SupermuxOrderDebugMode.current.servesOrderSync,
              SupermuxDeviceMirrorCoordinator.appIsReady(),
              !SupermuxDeviceWorkspaceIndex.isDeviceMirror(workspace) else { return nil }
        return SupermuxComposition.workspaceOrderStore.key(forStableID: workspace.stableId)
    }
}

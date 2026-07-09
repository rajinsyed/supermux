public import CmuxMobileRPC
import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Mounts the fork's workspace tools into the workspace detail view: a
    /// capability-gated Changes toolbar entry that presents
    /// ``SupermuxChangesScreen`` as a sheet. This is the single fork-owned
    /// call behind the `supermux-mobile-workspace-tools` fence in
    /// `CmuxMobileShellUI/WorkspaceDetailView.swift`.
    ///
    /// The entry is hidden unless the host advertises `supermux.changes.v1`
    /// — against an upstream Mac the detail view renders exactly today's UI.
    ///
    /// - Parameters:
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (entry hides).
    ///   - workspaceID: The detail view's workspace id (the Mac's workspace
    ///     UUID string).
    ///   - workspaceName: The workspace's display name (sheet title).
    @MainActor
    public func supermuxWorkspaceTools(
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
        workspaceID: String,
        workspaceName: String
    ) -> some View {
        modifier(SupermuxWorkspaceToolsModifier(
            connection: connection,
            workspaceID: workspaceID,
            workspaceName: workspaceName
        ))
    }
}

/// Pure visibility logic for the workspace-tools entries, kept off the view
/// so the capability gate is package-unit-testable (UI-02 for this mount).
enum SupermuxWorkspaceTools {
    /// Whether the Changes toolbar entry shows: a live connection whose host
    /// advertises `supermux.changes.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    static func showsChangesEntry(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsChanges
    }
}

/// The mount behind ``SwiftUICore/View/supermuxWorkspaceTools(connection:workspaceID:workspaceName:)``:
/// owns the sheet presentation state and builds one changes store per
/// presentation against the connection it was shown with.
struct SupermuxWorkspaceToolsModifier: ViewModifier {
    let connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    let workspaceID: String
    let workspaceName: String

    @State private var showingChanges = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if SupermuxWorkspaceTools.showsChangesEntry(hostCapabilities: connection?.hostCapabilities) {
                    ToolbarItem(placement: toolbarPlacement) {
                        Button {
                            showingChanges = true
                        } label: {
                            Label {
                                Text(String(
                                    localized: "supermux.changes.toolbarLabel",
                                    defaultValue: "Changes",
                                    bundle: .module
                                ))
                            } icon: {
                                Image(systemName: "plus.forwardslash.minus")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel(String(
                            localized: "supermux.changes.toolbarLabel",
                            defaultValue: "Changes",
                            bundle: .module
                        ))
                        .accessibilityIdentifier("SupermuxChangesToolbarButton")
                    }
                }
            }
            .sheet(isPresented: $showingChanges) {
                SupermuxChangesScreen(
                    workspaceName: workspaceName,
                    makeStore: makeStore
                )
            }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    /// Builds the presentation's changes session against the CURRENT
    /// connection, or `nil` while disconnected (the sheet shows its
    /// not-connected placeholder).
    @MainActor
    private func makeStore() -> SupermuxMobileChangesStore? {
        guard let connection else { return nil }
        return SupermuxMobileChangesStore(
            client: SupermuxMacClient(client: connection.rpcClient),
            capabilities: SupermuxMobileCapabilities(hostCapabilities: connection.hostCapabilities),
            workspaceID: workspaceID
        )
    }
}

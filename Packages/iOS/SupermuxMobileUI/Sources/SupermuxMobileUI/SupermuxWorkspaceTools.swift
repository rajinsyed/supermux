public import CmuxMobileRPC
import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Mounts the fork's workspace tools into the workspace detail view:
    /// capability-gated Changes and Files toolbar entries that present
    /// ``SupermuxChangesScreen`` / ``SupermuxFileBrowserScreen`` as sheets.
    /// This is the single fork-owned call behind the
    /// `supermux-mobile-workspace-tools` fence in
    /// `CmuxMobileShellUI/WorkspaceDetailView.swift`.
    ///
    /// Each entry is hidden unless the host advertises its capability
    /// (`supermux.changes.v1` / `supermux.files.v1`) — against an upstream
    /// Mac the detail view renders exactly today's UI.
    ///
    /// - Parameters:
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (entries hide).
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
/// so the capability gates are package-unit-testable (UI-02 for this mount).
/// lint:allow namespace-enum — stateless capability-gate predicates kept off the view so the mount's visibility rules are package-unit-testable.
enum SupermuxWorkspaceTools {
    /// Whether the Changes toolbar entry shows: a live connection whose host
    /// advertises `supermux.changes.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    static func showsChangesEntry(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsChanges
    }

    /// Whether the Files toolbar entry shows: a live connection whose host
    /// advertises `supermux.files.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    static func showsFilesEntry(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsFiles
    }
}

/// The mount behind ``SwiftUICore/View/supermuxWorkspaceTools(connection:workspaceID:workspaceName:)``:
/// owns the sheet presentation state and builds one store per presentation
/// against the connection it was shown with.
struct SupermuxWorkspaceToolsModifier: ViewModifier {
    let connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    let workspaceID: String
    let workspaceName: String

    @State private var showingChanges = false
    @State private var showingFiles = false

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
                if SupermuxWorkspaceTools.showsFilesEntry(hostCapabilities: connection?.hostCapabilities) {
                    ToolbarItem(placement: toolbarPlacement) {
                        Button {
                            showingFiles = true
                        } label: {
                            Label {
                                Text(String(
                                    localized: "supermux.files.toolbarLabel",
                                    defaultValue: "Files",
                                    bundle: .module
                                ))
                            } icon: {
                                Image(systemName: "folder")
                            }
                            .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel(String(
                            localized: "supermux.files.toolbarLabel",
                            defaultValue: "Files",
                            bundle: .module
                        ))
                        .accessibilityIdentifier("SupermuxFilesToolbarButton")
                    }
                }
            }
            .sheet(isPresented: $showingChanges) {
                SupermuxChangesScreen(
                    workspaceName: workspaceName,
                    makeStore: makeStore
                )
            }
            .sheet(isPresented: $showingFiles) {
                SupermuxFileBrowserScreen(
                    title: workspaceName,
                    makeStore: makeFilesStore
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

    /// Builds the presentation's file-browser session against the CURRENT
    /// connection (workspace-cwd root), or `nil` while disconnected (the
    /// sheet shows its not-connected placeholder).
    @MainActor
    private func makeFilesStore() -> SupermuxMobileFileBrowserStore? {
        guard let connection else { return nil }
        return SupermuxMobileFileBrowserStore(
            client: SupermuxMacClient(client: connection.rpcClient),
            capabilities: SupermuxMobileCapabilities(hostCapabilities: connection.hostCapabilities),
            root: .workspace(id: workspaceID)
        )
    }
}

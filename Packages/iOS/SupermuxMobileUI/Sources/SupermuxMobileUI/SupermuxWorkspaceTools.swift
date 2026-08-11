public import CmuxMobileRPC
import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Mounts the fork's workspace tools into the workspace detail view:
    /// the sheets behind the capability-gated Changes and Files entries that
    /// present ``SupermuxChangesScreen`` / ``SupermuxFileBrowserScreen``.
    /// This is the single fork-owned call behind the
    /// `supermux-mobile-workspace-tools` fence in
    /// `CmuxMobileShellUI/WorkspaceDetailView.swift`.
    ///
    /// The entries themselves render inside the detail view's explicit
    /// trailing overflow menu via ``SupermuxWorkspaceToolsMenuEntries``; the
    /// menu buttons flip the bindings passed here and this modifier presents
    /// the matching sheet. Each entry is hidden unless the host advertises
    /// its capability (`supermux.changes.v1` / `supermux.files.v1`) — against
    /// an upstream Mac the detail view renders exactly today's UI.
    ///
    /// - Parameters:
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (entries hide).
    ///   - workspaceID: The detail view's workspace id (the Mac's workspace
    ///     UUID string).
    ///   - workspaceName: The workspace's display name (sheet title).
    ///   - showingChanges: Presents the Changes sheet while `true`; flipped
    ///     by the overflow menu's Changes entry.
    ///   - showingFiles: Presents the Files sheet while `true`; flipped by
    ///     the overflow menu's Files entry.
    @MainActor
    public func supermuxWorkspaceTools(
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
        workspaceID: String,
        workspaceName: String,
        showingChanges: Binding<Bool>,
        showingFiles: Binding<Bool>
    ) -> some View {
        modifier(SupermuxWorkspaceToolsModifier(
            connection: connection,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            showingChanges: showingChanges,
            showingFiles: showingFiles
        ))
    }
}

/// Pure visibility logic for the workspace-tools entries, kept off the view
/// so the capability gates are package-unit-testable (UI-02 for this mount).
/// Public so the detail view's overflow menu can decide whether it has any
/// entries to show before mounting the menu button.
/// lint:allow namespace-enum — stateless capability-gate predicates kept off the view so the mount's visibility rules are package-unit-testable.
public enum SupermuxWorkspaceTools {
    /// Whether the Changes entry shows: a live connection whose host
    /// advertises `supermux.changes.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    public static func showsChangesEntry(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsChanges
    }

    /// Whether the Files entry shows: a live connection whose host
    /// advertises `supermux.files.v1`.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    public static func showsFilesEntry(hostCapabilities: Set<String>?) -> Bool {
        guard let hostCapabilities else { return false }
        return SupermuxMobileCapabilities(hostCapabilities: hostCapabilities).supportsFiles
    }

    /// Whether any fork workspace-tools entry would render for this host.
    /// - Parameter hostCapabilities: The connected host's raw capability
    ///   strings, or `nil` while disconnected.
    public static func showsAnyEntry(hostCapabilities: Set<String>?) -> Bool {
        showsChangesEntry(hostCapabilities: hostCapabilities)
            || showsFilesEntry(hostCapabilities: hostCapabilities)
    }
}

/// The fork's rows inside the workspace detail's trailing overflow menu:
/// capability-gated Changes and Files buttons that flip the bindings driving
/// the ``SwiftUICore/View/supermuxWorkspaceTools(connection:workspaceID:workspaceName:showingChanges:showingFiles:)``
/// sheets. Renders nothing without the matching capabilities, so an upstream
/// Mac's menu carries no fork entries.
public struct SupermuxWorkspaceToolsMenuEntries: View {
    let hostCapabilities: Set<String>?
    @Binding var showingChanges: Bool
    @Binding var showingFiles: Bool

    /// Creates the menu entries for one host snapshot.
    /// - Parameters:
    ///   - hostCapabilities: The connected host's raw capability strings, or
    ///     `nil` while disconnected (both entries hide).
    ///   - showingChanges: The Changes sheet's presentation binding.
    ///   - showingFiles: The Files sheet's presentation binding.
    public init(
        hostCapabilities: Set<String>?,
        showingChanges: Binding<Bool>,
        showingFiles: Binding<Bool>
    ) {
        self.hostCapabilities = hostCapabilities
        self._showingChanges = showingChanges
        self._showingFiles = showingFiles
    }

    public var body: some View {
        if SupermuxWorkspaceTools.showsChangesEntry(hostCapabilities: hostCapabilities) {
            Button {
                Task { @MainActor in
                    showingChanges = true
                }
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
            }
            .accessibilityIdentifier("SupermuxChangesToolbarButton")
        }
        if SupermuxWorkspaceTools.showsFilesEntry(hostCapabilities: hostCapabilities) {
            Button {
                Task { @MainActor in
                    showingFiles = true
                }
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
            }
            .accessibilityIdentifier("SupermuxFilesToolbarButton")
        }
    }
}

/// The mount behind ``SwiftUICore/View/supermuxWorkspaceTools(connection:workspaceID:workspaceName:showingChanges:showingFiles:)``:
/// presents the sheets driven by the detail view's overflow-menu bindings and
/// builds one store per presentation against the connection it was shown with.
struct SupermuxWorkspaceToolsModifier: ViewModifier {
    let connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    let workspaceID: String
    let workspaceName: String
    @Binding var showingChanges: Bool
    @Binding var showingFiles: Bool

    func body(content: Content) -> some View {
        content
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

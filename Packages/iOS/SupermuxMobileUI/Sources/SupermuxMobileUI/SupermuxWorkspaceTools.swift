public import CmuxMobileRPC
import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Mounts the fork's workspace tools into the workspace detail view:
    /// the run session plus the sheets behind the capability-gated Changes and
    /// Files entries that present ``SupermuxChangesScreen`` / ``SupermuxFileBrowserScreen``.
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
    ///   - projectID: The workspace's owning Supermux project, when associated.
    ///   - runSession: Stable state for the title menu's project run action.
    ///   - showingChanges: Presents the Changes sheet while `true`; flipped
    ///     by the overflow menu's Changes entry.
    ///   - showingFiles: Presents the Files sheet while `true`; flipped by
    ///     the overflow menu's Files entry.
    @MainActor
    public func supermuxWorkspaceTools(
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
        workspaceID: String,
        workspaceName: String,
        projectID: String?,
        runSession: SupermuxWorkspaceRunSession,
        showingChanges: Binding<Bool>,
        showingFiles: Binding<Bool>
    ) -> some View {
        modifier(SupermuxWorkspaceToolsModifier(
            connection: connection,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            projectID: projectID,
            runSession: runSession,
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

/// The fork's rows inside the workspace title menu: the associated project's
/// shared run action, capability-gated Changes and Files buttons, and the
/// destructive Close Pane action. Against an upstream Mac, only the phone-local
/// browser close can appear.
public struct SupermuxWorkspaceToolsMenuEntries: View {
    let hostCapabilities: Set<String>?
    let projectID: String?
    let runSession: SupermuxWorkspaceRunSession
    let canClosePane: Bool
    let closePane: () -> Void
    @Binding var showingChanges: Bool
    @Binding var showingFiles: Bool

    /// Creates the menu entries for one workspace snapshot.
    /// - Parameters:
    ///   - hostCapabilities: The connected host's raw capability strings, or
    ///     `nil` while disconnected.
    ///   - projectID: The workspace's owning Supermux project, when associated.
    ///   - runSession: Stable state and actions for the project run command.
    ///   - canClosePane: Whether the currently visible pane can be closed.
    ///   - closePane: Requests confirmation for the current pane close.
    ///   - showingChanges: The Changes sheet's presentation binding.
    ///   - showingFiles: The Files sheet's presentation binding.
    public init(
        hostCapabilities: Set<String>?,
        projectID: String?,
        runSession: SupermuxWorkspaceRunSession,
        canClosePane: Bool,
        closePane: @escaping () -> Void,
        showingChanges: Binding<Bool>,
        showingFiles: Binding<Bool>
    ) {
        self.hostCapabilities = hostCapabilities
        self.projectID = projectID
        self.runSession = runSession
        self.canClosePane = canClosePane
        self.closePane = closePane
        self._showingChanges = showingChanges
        self._showingFiles = showingFiles
    }

    public var body: some View {
        let showsRun = runSession.showsEntry(forProjectID: projectID)
        let showsChanges = SupermuxWorkspaceTools.showsChangesEntry(
            hostCapabilities: hostCapabilities
        )
        let showsFiles = SupermuxWorkspaceTools.showsFilesEntry(
            hostCapabilities: hostCapabilities
        )

        if showsRun || showsChanges || showsFiles {
            Section {
                if showsRun, let projectID {
                    SupermuxWorkspaceRunMenuEntry(
                        session: runSession,
                        projectID: projectID
                    )
                }
                if showsChanges {
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
                if showsFiles {
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

        if canClosePane {
            Section {
                Button(role: .destructive, action: closePane) {
                    Label(
                        String(
                            localized: "supermux.panes.close",
                            defaultValue: "Close Pane",
                            bundle: .module
                        ),
                        systemImage: "xmark.rectangle"
                    )
                }
                .accessibilityIdentifier("MobileClosePaneMenuItem")
            }
        }
    }
}

/// The mount behind ``SwiftUICore/View/supermuxWorkspaceTools(connection:workspaceID:workspaceName:projectID:runSession:showingChanges:showingFiles:)``:
/// drives the title menu's run session, presents its shared error alert, and
/// builds the Changes/Files stores against the connection each sheet was shown with.
struct SupermuxWorkspaceToolsModifier: ViewModifier {
    let connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?
    let workspaceID: String
    let workspaceName: String
    let projectID: String?
    let runSession: SupermuxWorkspaceRunSession
    @Binding var showingChanges: Bool
    @Binding var showingFiles: Bool

    func body(content: Content) -> some View {
        let runSessionKey = RunSessionKey(
            connection: connection,
            isActive: runsTitleMenuSession
        )
        return content
            .task(id: runSessionKey) {
                guard runsTitleMenuSession, let connection else {
                    runSession.endSession()
                    return
                }
                await runSession.runSession(
                    client: SupermuxMacClient(client: connection.rpcClient),
                    hostCapabilities: connection.hostCapabilities,
                    connectionID: runSessionKey
                )
            }
            .alert(
                String(
                    localized: "supermux.run.failed.title",
                    defaultValue: "Couldn’t Update Run",
                    bundle: .module
                ),
                isPresented: Binding(
                    get: { runSession.actionErrorDescription != nil },
                    set: { if !$0 { runSession.dismissActionError() } }
                ),
                presenting: runSession.actionErrorDescription
            ) { _ in
                Button(role: .cancel) {
                    runSession.dismissActionError()
                } label: {
                    Text(String(
                        localized: "supermux.common.ok",
                        defaultValue: "OK",
                        bundle: .module
                    ))
                }
            } message: { message in
                Text(message)
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

    private var runsTitleMenuSession: Bool {
        #if os(iOS)
        projectID != nil
        #else
        false
        #endif
    }

    private struct RunSessionKey: Hashable {
        let clientID: ObjectIdentifier?
        let hostCapabilities: Set<String>?
        let isActive: Bool

        init(
            connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
            isActive: Bool
        ) {
            self.clientID = connection.map { ObjectIdentifier($0.rpcClient) }
            self.hostCapabilities = connection?.hostCapabilities
            self.isActive = isActive
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

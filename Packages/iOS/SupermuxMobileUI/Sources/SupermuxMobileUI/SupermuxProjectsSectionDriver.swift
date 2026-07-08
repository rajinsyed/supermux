public import CmuxMobileRPC
public import CmuxMobileShellModel
import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Drives a ``SupermuxProjectsSectionModel`` from the shell's connection
    /// seam. Attach OUTSIDE the `List` (on the list itself), so the session's
    /// structured `.task` is owned by a stable view, not a lazily recycled
    /// row.
    ///
    /// One session runs per `(connection identity, capability snapshot)`
    /// pair: a reconnect — or the capability set arriving after the
    /// `mobile.host.status` round-trip — changes the task id, which cancels
    /// the old session and builds a fresh ``SupermuxMacClient`` + store, so
    /// capabilities are re-snapshotted per connection instead of mutated.
    ///
    /// An `.onChange(of:initial:)` keyed on the projected workspace rows
    /// feeds the §6 join into the model (open-workspace counts, the detail
    /// screen's nested rows, and the shell's open-workspace closure) — state
    /// flows into the model from an event handler, never from a view body,
    /// and everything stays MainActor-isolated (no `@Sendable` requirement on
    /// the shell's navigation closure).
    ///
    /// - Parameters:
    ///   - model: The section model the fence's `@State` owns.
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (section hides).
    ///   - workspaces: The shell's current workspace previews (carrying the
    ///     additive `supermux_*` fields). Defaults to none.
    ///   - selectWorkspace: Opens a workspace row — the same closure the
    ///     shell's flat workspace rows navigate through. Defaults to a no-op.
    @MainActor
    public func supermuxProjectsSectionDriver(
        model: SupermuxProjectsSectionModel,
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
        workspaces: [MobileWorkspacePreview] = [],
        selectWorkspace: @escaping @MainActor (MobileWorkspacePreview.ID) -> Void = { _ in }
    ) -> some View {
        task(id: SupermuxProjectsConnectionKey(connection: connection)) {
            guard let connection else {
                model.endSession()
                return
            }
            await model.runSession(
                client: SupermuxMacClient(client: connection.rpcClient),
                hostCapabilities: connection.hostCapabilities
            )
        }
        .onChange(of: SupermuxProjectWorkspaceRowSnapshot.rows(from: workspaces), initial: true) { _, rows in
            model.updateWorkspaces(
                rows,
                selectWorkspace: { workspaceID in
                    selectWorkspace(MobileWorkspacePreview.ID(rawValue: workspaceID))
                }
            )
        }
    }
}

/// Equatable identity for one connection session: the RPC client's object
/// identity plus the capability snapshot it arrived with.
struct SupermuxProjectsConnectionKey: Equatable {
    let clientID: ObjectIdentifier?
    let hostCapabilities: Set<String>?

    init(connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?) {
        self.clientID = connection.map { ObjectIdentifier($0.rpcClient) }
        self.hostCapabilities = connection?.hostCapabilities
    }
}

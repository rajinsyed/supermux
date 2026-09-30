public import CmuxMobileRPC
public import CmuxMobileShellModel
public import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Drives a ``SupermuxProjectsSectionModel`` from the shell's per-Mac
    /// seams. Attach OUTSIDE the `List` (on the list itself), so the
    /// sessions' structured `.task` is owned by a stable view, not a lazily
    /// recycled row.
    ///
    /// - Every seam except an unavailable one runs its own session: the
    ///   section shows every connected Mac's projects, and it stays visible
    ///   while ANY Mac is connected — not only the foreground one.
    /// - The task restarts whenever a Mac's connection identity (client or
    ///   capability snapshot) changes. Unchanged Macs resume their retained
    ///   sessions (m6-f3 stale-while-revalidate); a changed Mac rebuilds; a
    ///   Mac that left is ended by ``SupermuxProjectsSectionModel/updateMacs(_:)``.
    /// - Every Mac advertising `supermux.phone_push.v1` gets the phone's APNs
    ///   token, so a Mac that is never the foreground can still push.
    /// - Mac-local workspace ids from Supermux RPCs are resolved through
    ///   `resolveWorkspace` to the owning Mac's row before navigating.
    ///
    /// - Parameters:
    ///   - model: The section model the fence's `@State` owns.
    ///   - seams: One seam per live Mac pairing, foreground first.
    ///   - workspaces: The shell's current workspace previews.
    ///   - selectWorkspace: Opens a workspace row by its row id.
    ///   - resolveWorkspace: The shell's Mac-local id → row id resolver
    ///     (`store.workspaceID(matchingRemoteWorkspaceID:macDeviceID:instanceTag:)`).
    ///   - closeWorkspace: Closes a workspace row through the shell's own
    ///     confirmation, or `nil` when unsupported.
    @MainActor
    public func supermuxProjectsSectionDriver(
        model: SupermuxProjectsSectionModel,
        seams: [SupermuxMacSeam],
        workspaces: [MobileWorkspacePreview] = [],
        selectWorkspace: @escaping @MainActor (MobileWorkspacePreview.ID) -> Void = { _ in },
        resolveWorkspace: SupermuxWorkspaceResolver? = nil,
        closeWorkspace: (@MainActor (MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> some View {
        let macs = seams.map(SupermuxMacInfo.init(seam:))
        let runnable = seams.filter { $0.status != .unavailable }
        let pushing = seams.filter {
            $0.status == .connected
                && SupermuxMobileCapabilities(hostCapabilities: $0.hostCapabilities).supportsPhonePush
        }
        // Bound outside the `.onChange` closure, with both closure types
        // spelled out, so the type checker has an anchor.
        var closeByRowID: (@MainActor (String) -> Void)?
        if let closeWorkspace {
            let close: @MainActor (String) -> Void = { rowID in
                closeWorkspace(MobileWorkspacePreview.ID(rawValue: rowID))
            }
            closeByRowID = close
        }
        return task(id: Set(runnable.map(SupermuxProjectsConnectionKey.init(seam:)))) {
            model.updateMacs(macs)
            await model.runSessions(runnable)
        }
        // Names, colors, status and order change without restarting sessions.
        .onChange(of: macs, initial: true) { _, macs in
            model.updateMacs(macs)
        }
        .task(id: Set(pushing.map(SupermuxProjectsConnectionKey.init(seam:)))) {
            await SupermuxPhonePushRegistrations.run(pushing)
        }
        .onChange(of: SupermuxProjectWorkspaceRowSnapshot.rows(from: workspaces), initial: true) { _, rows in
            model.updateWorkspaces(
                rows,
                selectWorkspace: { workspaceID in
                    selectWorkspace(MobileWorkspacePreview.ID(rawValue: workspaceID))
                },
                closeWorkspace: closeByRowID,
                resolveWorkspace: resolveWorkspace
            )
        }
        // A freshly created workspace's row lands with the owning Mac's next
        // list refresh: retry any navigation parked waiting for it.
        .onChange(of: workspaces.map(\.id)) { _, _ in
            model.workspaceListDidChange()
        }
        // Detail-route destination, New Worktree sheet and error alerts: on
        // the stable wrapper above the `List`, never inside a lazy row.
        .modifier(SupermuxProjectsSectionNavigation(model: model))
    }

    /// Drives the section from a single connection (the pre-multi-Mac API):
    /// the one Mac is treated as an unidentified foreground Mac.
    /// - Parameters:
    ///   - model: The section model the fence's `@State` owns.
    ///   - connection: The live RPC client + host-capability snapshot, or
    ///     `nil` while disconnected (section hides).
    ///   - workspaces: The shell's current workspace previews.
    ///   - selectWorkspace: Opens a workspace row by its row id.
    ///   - closeWorkspace: Closes a workspace row, or `nil` when unsupported.
    @MainActor
    public func supermuxProjectsSectionDriver(
        model: SupermuxProjectsSectionModel,
        connection: (rpcClient: MobileCoreRPCClient, hostCapabilities: Set<String>)?,
        workspaces: [MobileWorkspacePreview] = [],
        selectWorkspace: @escaping @MainActor (MobileWorkspacePreview.ID) -> Void = { _ in },
        closeWorkspace: (@MainActor (MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> some View {
        supermuxProjectsSectionDriver(
            model: model,
            seams: connection.map { connection in
                [SupermuxMacSeam(
                    macDeviceID: nil,
                    instanceTag: nil,
                    displayName: "",
                    client: connection.rpcClient,
                    hostCapabilities: connection.hostCapabilities,
                    status: .connected,
                    isForeground: true
                )]
            } ?? [],
            workspaces: workspaces,
            selectWorkspace: selectWorkspace,
            closeWorkspace: closeWorkspace
        )
    }
}

/// Hashable identity for one Mac's connection session: the pairing, the RPC
/// client's object identity, and the capability snapshot it arrived with.
/// Used both in the driver's `.task(id:)` key and as the session's resume
/// identity.
struct SupermuxProjectsConnectionKey: Hashable, Sendable {
    let pairingID: String
    let clientID: ObjectIdentifier?
    let hostCapabilities: Set<String>?

    init(seam: SupermuxMacSeam) {
        self.pairingID = seam.pairingID
        self.clientID = ObjectIdentifier(seam.client)
        self.hostCapabilities = seam.hostCapabilities
    }
}

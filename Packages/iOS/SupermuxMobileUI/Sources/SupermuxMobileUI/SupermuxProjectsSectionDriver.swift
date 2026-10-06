public import CmuxMobileShellModel
import SupermuxMobileCore
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
    ///   - selectedWorkspaceID: The shell's selected workspace row, so a
    ///     choice made outside the Projects section drops a parked navigation.
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
        selectedWorkspaceID: MobileWorkspacePreview.ID? = nil,
        selectWorkspace: @escaping @MainActor (MobileWorkspacePreview.ID) -> Void = { _ in },
        resolveWorkspace: SupermuxWorkspaceResolver? = nil,
        closeWorkspace: (@MainActor (MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> some View {
        modifier(SupermuxProjectsSectionDriver(
            model: model,
            seams: seams,
            workspaces: workspaces,
            selectedWorkspaceID: selectedWorkspaceID,
            selectWorkspace: selectWorkspace,
            resolveWorkspace: resolveWorkspace,
            closeWorkspace: closeWorkspace
        ))
    }
}

/// The driver itself: a modifier, so the DEBUG layout preview can hand it
/// in-memory Macs through the environment instead of the shell's seams.
private struct SupermuxProjectsSectionDriver: ViewModifier {
    let model: SupermuxProjectsSectionModel
    let seams: [SupermuxMacSeam]
    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let selectWorkspace: @MainActor (MobileWorkspacePreview.ID) -> Void
    let resolveWorkspace: SupermuxWorkspaceResolver?
    let closeWorkspace: (@MainActor (MobileWorkspacePreview.ID) -> Void)?
    #if DEBUG
    @Environment(\.supermuxProjectsPreviewMacs) private var previewMacs
    #endif
    /// The phone's per-Mac routes, injected at the app's composition root
    /// and run by the shell's root view (`supermuxPhoneRoutes(seams:)`);
    /// absent in previews and on the Mac.
    @Environment(SupermuxPhoneRouteModel.self) private var routes: SupermuxPhoneRouteModel?

    func body(content: Content) -> some View {
        let runnable = seams.filter { $0.status != .unavailable }
        var macInfos = seams.map(SupermuxMacInfo.init(seam:))
        var keys = Set(runnable.map(SupermuxProjectsConnectionKey.init(seam:)))
        var run: @MainActor @Sendable () async -> Void = { [model] in
            await model.runSessions(runnable)
        }
        #if DEBUG
        if !previewMacs.isEmpty {
            // Like the shell, opening a workspace on another Mac makes that
            // Mac the foreground.
            let previews = SupermuxProjectsPreviewFixture.foregroundFirst(
                previewMacs,
                opened: selectedWorkspaceID,
                in: workspaces
            )
            macInfos = previews.map(\.mac)
            keys = Set(previews.map { SupermuxProjectsConnectionKey(previewPairingID: $0.mac.pairingID) })
            run = { [model] in await model.runPreviewSessions(previews) }
        }
        #endif
        let macs = macInfos
        let sessionKeys = keys
        let runSessions = run
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
        let selectWorkspace = selectWorkspace
        let resolveWorkspace = resolveWorkspace
        return content
            .task(id: sessionKeys) {
                model.updateMacs(macs)
                await runSessions()
            }
            .onChange(of: routes?.routes ?? [:], initial: true) { _, routes in
                model.updateRoutes(routes)
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
            .onChange(of: selectedWorkspaceID) { _, selected in
                model.shellSelectionDidChange(to: selected?.rawValue)
            }
            // A Mac's copy that joins a merged project takes the project's
            // state: open inside an open one, closed inside a closed one (the
            // iPhone's merged list; the macOS `List` keeps per-Mac rows).
            #if os(iOS)
            .onChange(of: model.copiesOutOfStep, initial: true) { _, projectIDs in
                model.syncCopies(projectIDs)
            }
            #endif
            // Detail-route destination, New Worktree sheet and error alerts: on
            // the stable wrapper above the `List`, never inside a lazy row.
            .modifier(SupermuxProjectsSectionNavigation(model: model))
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

    /// The identity of a DEBUG layout-preview Mac (one fixed connection).
    init(previewPairingID: String) {
        self.pairingID = previewPairingID
        self.clientID = nil
        self.hostCapabilities = nil
    }
}

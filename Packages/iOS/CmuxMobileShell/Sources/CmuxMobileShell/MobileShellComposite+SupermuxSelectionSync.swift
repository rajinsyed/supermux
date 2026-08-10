// SUPERMUX:begin supermux-mobile-selection-sync
import CMUXMobileCore
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
import SupermuxMobileCore

/// One optimistic phone selection waiting to be reconciled with the Mac's
/// authoritative workspace-list state.
struct SupermuxMobileSelectionSyncIntent: Equatable, Sendable {
    let requestID: UUID
    let workspaceID: MobileWorkspacePreview.ID
    let focusedPanel: MobileWorkspaceFocusedPanel?
}

extension MobileShellComposite {
    /// Whether this Mac serves any version of bidirectional selection sync.
    /// An upstream or older Mac keeps the pre-existing phone-local behavior.
    var supportsSupermuxSelectionSync: Bool {
        supportedHostCapabilities.contains(
            SupermuxMobileCapability.selectionSyncV1.rawValue
        ) || supportsSupermuxPanelSelectionSync
    }

    /// Whether this Mac synchronizes browser, Simulator, and every other panel
    /// kind in addition to workspaces and terminals.
    var supportsSupermuxPanelSelectionSync: Bool {
        supportedHostCapabilities.contains(
            SupermuxMobileCapability.selectionSyncV2.rawValue
        )
    }

    /// Selects a panel optimistically on the phone and queues the matching Mac
    /// focus mutation through the shared serialized selection pipeline.
    ///
    /// - Parameters:
    ///   - panelID: Stable Mac panel UUID string.
    ///   - kind: Forward-compatible Mac panel-type wire value.
    ///   - workspaceID: Phone row identity of the owning workspace.
    public func selectWorkspacePanel(
        panelID: String,
        kind: String,
        workspaceID: MobileWorkspacePreview.ID
    ) {
        let selection = MobileWorkspaceFocusedPanel(
            panelID: panelID,
            kind: kind
        )
        guard selectedWorkspaceFocusedPanel != selection else { return }
        selectedWorkspaceFocusedPanel = selection
        enqueueSupermuxSelectionSync(
            workspaceID: workspaceID,
            focusedPanel: selection
        )
    }

    /// Queues a phone selection behind earlier requests so rapid taps cannot
    /// arrive at the Mac out of order. The local selection is already
    /// optimistic; after the RPC, one authoritative list/sync fetch confirms it.
    @discardableResult
    func enqueueSupermuxSelectionSync(
        workspaceID: MobileWorkspacePreview.ID,
        focusedPanel: MobileWorkspaceFocusedPanel?
    ) -> Task<Void, Never>? {
        guard supportsSupermuxSelectionSync,
              connectionState == .connected,
              let client = remoteClient else {
            return nil
        }

        let method: SupermuxMobileMethod
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID(for: workspaceID).rawValue,
        ]
        if let focusedPanel {
            if supportsSupermuxPanelSelectionSync {
                method = .panelSelect
                params["panel_id"] = focusedPanel.panelID
            } else {
                guard focusedPanel.kind == MobileWorkspaceFocusedPanel.terminalKind else {
                    return nil
                }
                method = .terminalSelect
                params["terminal_id"] = focusedPanel.panelID
            }
        } else {
            method = .workspaceSelect
        }

        let intent = SupermuxMobileSelectionSyncIntent(
            requestID: UUID(),
            workspaceID: workspaceID,
            focusedPanel: focusedPanel
        )
        pendingSupermuxSelectionSyncIntent = intent

        let previous = supermuxSelectionSyncTask
        let operationID = UUID()
        let generation = connectionGeneration
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.supermuxSelectionSyncOperationID == operationID {
                    self.supermuxSelectionSyncTask = nil
                    self.supermuxSelectionSyncOperationID = nil
                }
            }
            guard !Task.isCancelled,
                  self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                  ) else {
                if self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID {
                    self.pendingSupermuxSelectionSyncIntent = nil
                }
                return
            }

            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: method.rawValue,
                    params: params
                )
                _ = try await client.sendRequest(request)
                guard self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                ), !Task.isCancelled else {
                    return
                }
                guard self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID else {
                    return
                }

                _ = await self.reloadWorkspaceListFromMac()
                // A successful selection is authoritative even if the follow-up
                // fetch was lost. Keep the optimistic effective panel; the next
                // pushed row change is free to reconcile normally.
                if self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID {
                    self.pendingSupermuxSelectionSyncIntent = nil
                }
            } catch {
                guard self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                ), !Task.isCancelled else {
                    return
                }
                guard self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID else {
                    return
                }

                self.pendingSupermuxSelectionSyncIntent = nil
                guard !self.disconnectForAuthorizationFailureIfNeeded(error) else { return }
                self.handleMacAvailabilityFailureIfCurrent(
                    after: error,
                    expectedClient: client,
                    expectedGeneration: generation
                )
                // Explicit rollback: after a rejected or failed selection, read
                // the Mac's authoritative selection instead of leaving the
                // optimistic phone state stranded.
                _ = await self.reloadWorkspaceListFromMac()
                self.applyOperationalError(error)
            }
        }
        supermuxSelectionSyncTask = task
        supermuxSelectionSyncOperationID = operationID
        return task
    }

    /// Applies the Mac's selected workspace and focused panel to the phone,
    /// unless a newer optimistic phone selection is still in flight.
    func reconcileSupermuxSelection(
        from response: MobileSyncWorkspaceListResponse
    ) {
        let authoritativeRemoteWorkspace = response.workspaces.first(where: \.isSelected)
        let authoritativeWorkspaceID = authoritativeRemoteWorkspace
            .map { MobileWorkspacePreview.ID(rawValue: $0.id) }
            .flatMap {
                rowWorkspaceID(
                    forRemoteWorkspaceID: $0,
                    macDeviceID: foregroundMacDeviceID,
                    instanceTag: activeMacInstanceTag
                )
            }
        let authoritativeFocusedPanel = authoritativeRemoteWorkspace.flatMap {
            $0.focusedPanel ?? $0.terminals.first(where: \.isFocused).map {
                MobileWorkspaceFocusedPanel(
                    panelID: $0.id,
                    kind: MobileWorkspaceFocusedPanel.terminalKind
                )
            }
        }

        if let pending = pendingSupermuxSelectionSyncIntent {
            guard workspaces.contains(where: { $0.id == pending.workspaceID }) else {
                pendingSupermuxSelectionSyncIntent = nil
                applyAuthoritativeSupermuxSelection(
                    workspaceID: authoritativeWorkspaceID,
                    focusedPanel: authoritativeFocusedPanel
                )
                return
            }

            setSelectedWorkspaceID(pending.workspaceID)
            applyEffectiveSupermuxFocusedPanel(pending.focusedPanel)

            guard authoritativeWorkspaceID == pending.workspaceID,
                  authoritativeFocusedPanel == pending.focusedPanel else {
                return
            }

            pendingSupermuxSelectionSyncIntent = nil
            applyEffectiveSupermuxFocusedPanel(authoritativeFocusedPanel)
            return
        }

        applyAuthoritativeSupermuxSelection(
            workspaceID: authoritativeWorkspaceID,
            focusedPanel: authoritativeFocusedPanel
        )
    }

    private func applyAuthoritativeSupermuxSelection(
        workspaceID: MobileWorkspacePreview.ID?,
        focusedPanel: MobileWorkspaceFocusedPanel?
    ) {
        if let workspaceID,
           workspaces.contains(where: { $0.id == workspaceID }) {
            setSelectedWorkspaceID(workspaceID)
        } else if let selectedWorkspaceID,
                  workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            // A Mac can temporarily report no globally-selected row while its
            // windows are changing. Preserve a still-valid phone selection
            // rather than blanking the detail during that transient.
        } else {
            setSelectedWorkspaceID(workspaces.first?.id)
        }
        applyEffectiveSupermuxFocusedPanel(focusedPanel)
    }

    private func applyEffectiveSupermuxFocusedPanel(
        _ focusedPanel: MobileWorkspaceFocusedPanel?
    ) {
        selectedWorkspaceFocusedPanel = focusedPanel
        guard let focusedPanel,
              focusedPanel.kind == MobileWorkspaceFocusedPanel.terminalKind,
              let selectedWorkspace,
              let terminal = selectedWorkspace.terminals.first(where: {
                  $0.id.rawValue == focusedPanel.panelID
              }) else {
            syncSelectedTerminalForWorkspace()
            return
        }
        selectedTerminalID = terminal.id
    }
}
// SUPERMUX:end supermux-mobile-selection-sync

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

/// The selected panel whose Mac focus is known to be ready for stream startup.
struct SupermuxMobileStreamFocusReadiness: Equatable, Sendable {
    let workspaceID: MobileWorkspacePreview.ID
    let focusedPanel: MobileWorkspaceFocusedPanel
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
    /// - Returns: A task that completes with the Mac focus acknowledgement,
    ///   without waiting for the follow-up authoritative list reconciliation.
    @discardableResult
    public func selectWorkspacePanel(
        panelID: String,
        kind: String,
        workspaceID: MobileWorkspacePreview.ID
    ) -> Task<Bool, Never>? {
        let selection = MobileWorkspaceFocusedPanel(
            panelID: panelID,
            kind: kind
        )
        if selectedWorkspaceFocusedPanel == selection {
            let readiness = SupermuxMobileStreamFocusReadiness(
                workspaceID: workspaceID,
                focusedPanel: selection
            )
            if supermuxStreamFocusReadiness == readiness {
                return nil
            }
            if pendingSupermuxSelectionSyncIntent?.workspaceID == workspaceID,
               pendingSupermuxSelectionSyncIntent?.focusedPanel == selection {
                return supermuxSelectionFocusTask
            }
        }
        selectedWorkspaceFocusedPanel = selection
        supermuxStreamFocusReadiness = nil
        return enqueueSupermuxSelectionSync(
            workspaceID: workspaceID,
            focusedPanel: selection
        )
    }

    /// Whether an authoritative Mac frame already confirmed this exact intent.
    ///
    /// The Mac pushes its updated state after applying a focus mutation, and
    /// that push can outrace the mutation's own RPC reply. Reconciliation then
    /// clears the pending intent as confirmed before the reply lands; the
    /// reply must read that as success, not as a superseded selection —
    /// otherwise the UI abandons a surface the Mac just focused (the
    /// flash-then-revert on re-entering a browser/Simulator tab).
    func supermuxSelectionAlreadyConfirmed(
        _ intent: SupermuxMobileSelectionSyncIntent
    ) -> Bool {
        pendingSupermuxSelectionSyncIntent == nil
            && selectedWorkspaceID == intent.workspaceID
            && selectedWorkspaceFocusedPanel == intent.focusedPanel
    }

    /// Whether the currently active streamed panel may start against the Mac.
    /// Hosts without generic panel selection keep their legacy stream behavior.
    func supermuxAllowsStreamStart(
        panelID: String,
        kind: String
    ) -> Bool {
        guard supportsSupermuxPanelSelectionSync else { return true }
        guard let workspaceID = selectedWorkspaceID else { return false }
        let focusedPanel = MobileWorkspaceFocusedPanel(
            panelID: panelID,
            kind: kind
        )
        return selectedWorkspaceFocusedPanel == focusedPanel
            && supermuxStreamFocusReadiness == SupermuxMobileStreamFocusReadiness(
                workspaceID: workspaceID,
                focusedPanel: focusedPanel
            )
    }

    /// Queues a phone selection behind earlier focus mutations so rapid taps
    /// cannot reach the Mac out of order. Reconciliation runs on a separate
    /// serialized tail, allowing streamed panels to start after the focus reply
    /// instead of waiting for an additional workspace-list round trip.
    @discardableResult
    func enqueueSupermuxSelectionSync(
        workspaceID: MobileWorkspacePreview.ID,
        focusedPanel: MobileWorkspaceFocusedPanel?
    ) -> Task<Bool, Never>? {
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

        let previousFocus = supermuxSelectionFocusTask
        let generation = connectionGeneration
        let focusTask = Task { @MainActor [weak self] () -> Bool in
            _ = await previousFocus?.value
            guard let self else { return false }
            guard !Task.isCancelled,
                  self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                  ) else {
                if self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID {
                    self.pendingSupermuxSelectionSyncIntent = nil
                    self.supermuxStreamFocusReadiness = nil
                }
                return false
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
                ), !Task.isCancelled,
                      self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID
                        || self.supermuxSelectionAlreadyConfirmed(intent) else {
                    return false
                }

                if let focusedPanel {
                    self.supermuxStreamFocusReadiness = SupermuxMobileStreamFocusReadiness(
                        workspaceID: workspaceID,
                        focusedPanel: focusedPanel
                    )
                }
                return true
            } catch {
                guard self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                ), !Task.isCancelled,
                      self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID else {
                    // A lost reply after the Mac's own push already confirmed
                    // this exact selection is still a success.
                    return self.supermuxSelectionAlreadyConfirmed(intent)
                }

                self.pendingSupermuxSelectionSyncIntent = nil
                self.supermuxStreamFocusReadiness = nil
                guard !self.disconnectForAuthorizationFailureIfNeeded(error) else { return false }
                self.handleMacAvailabilityFailureIfCurrent(
                    after: error,
                    expectedClient: client,
                    expectedGeneration: generation
                )
                // Explicit rollback: after a rejected or failed selection, read
                // the Mac's authoritative selection instead of leaving the
                // optimistic phone state stranded. Stream startup still receives
                // `false` even when this recovery fetch also fails.
                _ = await self.reloadWorkspaceListFromMac()
                self.applyOperationalError(error)
                return false
            }
        }
        supermuxSelectionFocusTask = focusTask

        let previousReconciliation = supermuxSelectionSyncTask
        let operationID = UUID()
        let reconciliationTask = Task { @MainActor [weak self] in
            let focusSucceeded = await focusTask.value
            await previousReconciliation?.value
            guard let self else { return }
            defer {
                if self.supermuxSelectionSyncOperationID == operationID {
                    self.supermuxSelectionSyncTask = nil
                    self.supermuxSelectionSyncOperationID = nil
                }
            }
            guard focusSucceeded,
                  !Task.isCancelled,
                  self.isCurrentRemoteOperation(
                    client: client,
                    generation: generation
                  ),
                  self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID else {
                return
            }

            _ = await self.reloadWorkspaceListFromMac()
            // A successful selection is authoritative even if the follow-up
            // fetch was lost. Keep the optimistic effective panel; the next
            // pushed row change is free to reconcile normally.
            if self.pendingSupermuxSelectionSyncIntent?.requestID == intent.requestID {
                self.pendingSupermuxSelectionSyncIntent = nil
            }
        }
        supermuxSelectionSyncTask = reconciliationTask
        supermuxSelectionSyncOperationID = operationID
        return focusTask
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
            if let authoritativeFocusedPanel {
                supermuxStreamFocusReadiness = SupermuxMobileStreamFocusReadiness(
                    workspaceID: pending.workspaceID,
                    focusedPanel: authoritativeFocusedPanel
                )
            } else {
                supermuxStreamFocusReadiness = nil
            }
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
        if let workspaceID = selectedWorkspaceID, let focusedPanel {
            supermuxStreamFocusReadiness = SupermuxMobileStreamFocusReadiness(
                workspaceID: workspaceID,
                focusedPanel: focusedPanel
            )
        } else {
            supermuxStreamFocusReadiness = nil
        }
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

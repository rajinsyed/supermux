import Foundation

/// Panel-scoped liveness evidence for structured coding agents.
///
/// cmux tracks one PID per agent key (`agentPIDs` / `agentPIDPanelIdsByKey`),
/// so with several Claude Code instances sharing the `claude_code` key only
/// the most recent reporter's panel holds verifiable process evidence. A
/// sibling panel whose agent dies without a SessionEnd hook keeps its last
/// lifecycle value forever: both stale sweeps iterate only owned keys, so the
/// workspace activity indicator stays on with no agent running.
///
/// This registry keeps the LAST process identity each panel reported per
/// status key, independent of who currently owns the key, so the existing
/// sweeps can also retire lifecycle entries whose process is provably gone.
/// It is evidence-only bookkeeping: recording never mutates cmux state, and
/// retirement clears lifecycle solely through the same panel-scoped
/// `Workspace.clearAgentLifecycle` mutation every other clear path uses.
@MainActor
final class SupermuxPanelAgentEvidence {
    static let shared = SupermuxPanelAgentEvidence()

    /// Recorded proof for one (panel, status key): the reporting process's
    /// identity, or `nil` when the process was already unreadable at record
    /// time — an explicit "no proof of life", distinct from "never recorded".
    private struct Evidence {
        let identity: AgentPIDProcessIdentity?
    }

    /// workspace → panel → status key → evidence at last report.
    private var evidenceByWorkspace: [UUID: [UUID: [String: Evidence]]] = [:]

    /// Records the identity a panel last reported for an agent status key.
    /// Called from the fenced hook in `Workspace.recordAgentPID`, which is the
    /// single path every PID-bearing agent report flows through.
    func record(
        workspaceId: UUID,
        panelId: UUID,
        statusKey: String,
        identity: AgentPIDProcessIdentity?
    ) {
        evidenceByWorkspace[workspaceId, default: [:]][panelId, default: [:]][statusKey] =
            Evidence(identity: identity)
    }

    /// Status keys on this panel whose recorded process is provably gone.
    /// Keys with no recorded evidence are never returned — with nothing to
    /// prove either way, the sweep must not touch them.
    func deadStatusKeys(
        workspaceId: UUID,
        panelId: UUID,
        isIdentityLive: (AgentPIDProcessIdentity) -> Bool
    ) -> [String] {
        guard let panelEvidence = evidenceByWorkspace[workspaceId]?[panelId] else { return [] }
        return panelEvidence.compactMap { key, evidence in
            if let identity = evidence.identity, isIdentityLive(identity) { return nil }
            return key
        }
    }

    /// Panels holding any evidence, for the workspace-level sweep.
    func panelIds(workspaceId: UUID) -> [UUID] {
        Array(evidenceByWorkspace[workspaceId]?.keys ?? [UUID: [String: Evidence]]().keys)
    }

    func removeEvidence(workspaceId: UUID, panelId: UUID, statusKey: String) {
        evidenceByWorkspace[workspaceId]?[panelId]?.removeValue(forKey: statusKey)
        pruneEmpty(workspaceId: workspaceId, panelId: panelId)
    }

    func removePanel(workspaceId: UUID, panelId: UUID) {
        evidenceByWorkspace[workspaceId]?.removeValue(forKey: panelId)
        pruneEmpty(workspaceId: workspaceId, panelId: nil)
    }

    func removeWorkspace(workspaceId: UUID) {
        evidenceByWorkspace.removeValue(forKey: workspaceId)
    }

    private func pruneEmpty(workspaceId: UUID, panelId: UUID?) {
        if let panelId, evidenceByWorkspace[workspaceId]?[panelId]?.isEmpty == true {
            evidenceByWorkspace[workspaceId]?.removeValue(forKey: panelId)
        }
        if evidenceByWorkspace[workspaceId]?.isEmpty == true {
            evidenceByWorkspace.removeValue(forKey: workspaceId)
        }
    }
}

extension Workspace {
    /// Clears this panel's agent lifecycle entries whose recorded process is
    /// provably dead. Keys whose PID this panel still owns are left to
    /// upstream's own stale sweep, which already clears lifecycle with the
    /// PID. Returns whether anything was cleared.
    @discardableResult
    func supermuxClearDeadPanelAgentLifecycle(panelId: UUID) -> Bool {
        let registry = SupermuxPanelAgentEvidence.shared
        let lifecycleKeys = Set(
            (agentLifecycleStatesByPanelId[panelId] ?? [:]).keys
                .filter { !AgentHibernationLifecycleStatusKeys.isManualKey($0) }
        )
        guard !lifecycleKeys.isEmpty else {
            // Nothing left to retire; drop the panel's evidence so future
            // sweeps stop re-reading the process table for it.
            registry.removePanel(workspaceId: id, panelId: panelId)
            return false
        }
        let ownedStatusKeys = Set(
            (agentPIDKeysByPanelId[panelId] ?? []).map { agentStatusKey(forAgentPIDKey: $0) }
        )
        let deadKeys = registry.deadStatusKeys(workspaceId: id, panelId: panelId) { identity in
            Self.agentPIDProcessIdentity(pid: identity.pid) == identity
        }
        var didClear = false
        for key in deadKeys where lifecycleKeys.contains(key) && !ownedStatusKeys.contains(key) {
            if clearAgentLifecycle(key: key, panelId: panelId) {
                didClear = true
            }
            registry.removeEvidence(workspaceId: id, panelId: panelId, statusKey: key)
        }
        return didClear
    }

    /// Workspace-wide companion for the periodic stale sweep: visits every
    /// panel with recorded evidence, dropping evidence for panels that no
    /// longer exist. Returns whether any lifecycle state was cleared.
    @discardableResult
    func supermuxSweepDeadAgentLifecycle() -> Bool {
        let registry = SupermuxPanelAgentEvidence.shared
        var didClear = false
        for panelId in registry.panelIds(workspaceId: id) {
            guard panels[panelId] != nil else {
                registry.removePanel(workspaceId: id, panelId: panelId)
                continue
            }
            if supermuxClearDeadPanelAgentLifecycle(panelId: panelId) {
                didClear = true
            }
        }
        return didClear
    }
}

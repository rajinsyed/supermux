/// Wire representation of a workspace's agent-activity state, carried as the
/// optional `supermux_activity` workspace-list field.
///
/// Mirrors the visible states of the Mac's `SupermuxWorkspaceActivity`
/// (`idle` never travels — an idle workspace simply omits the field).
public enum SupermuxWorkspaceActivityDTO: String, CaseIterable, Codable, Sendable, Equatable {
    /// An agent is actively working.
    case working
    /// An agent is blocked waiting for user input.
    case needsInput = "needs_input"
    /// An agent finished its turn and is ready for review.
    case ready
}

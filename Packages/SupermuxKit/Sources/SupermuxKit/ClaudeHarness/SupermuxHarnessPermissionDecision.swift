/// A user decision for a pending CLI `can_use_tool` request.
public enum SupermuxHarnessPermissionDecision: Equatable, Sendable {
    /// Allows the tool with echoed or edited input and optional selected permission suggestions.
    case allow(
        updatedInput: SupermuxHarnessJSONObject,
        updatedPermissions: [SupermuxHarnessJSONObject]?
    )
    /// Denies the tool with a required model-visible reason and optional turn interruption.
    case deny(message: String, interrupt: Bool)
}

/// Claude Code permission modes accepted by launch arguments and control requests.
public enum SupermuxHarnessPermissionMode: String, CaseIterable, Sendable {
    /// Ask for potentially unsafe operations under the normal policy.
    case `default`
    /// Automatically accept file edits while retaining other permission checks.
    case acceptEdits
    /// Restrict the session to planning behavior.
    case plan
    /// Bypass permission prompts when the CLI and account permit it.
    case bypassPermissions
}

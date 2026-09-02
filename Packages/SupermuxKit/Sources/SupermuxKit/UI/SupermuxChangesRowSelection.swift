import Foundation

/// Identity of the Changes-panel row whose diff was last opened.
///
/// A file modified again after staging appears in both the Staged and the
/// Changes sections with the same path, so the path alone would highlight
/// both rows; the section side is part of the identity.
struct SupermuxChangesRowSelection: Hashable, Sendable {
    let changeID: SupermuxGitFileChange.ID
    let staged: Bool

    init(_ change: SupermuxGitFileChange, staged: Bool) {
        changeID = change.id
        self.staged = staged
    }
}

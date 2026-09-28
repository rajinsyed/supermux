import Foundation
import SupermuxMobileCore
public import SupermuxMobileKit

/// The section-wide editing seams: the header's Add Project and the empty
/// state act on the lead Mac (foreground first). A project's OWN detail
/// screen edits through its Mac's session instead (see
/// ``SupermuxProjectDetailContext``).
extension SupermuxProjectsSectionModel {
    /// The lead Mac's editor seam; with no session every call throws
    /// `SupermuxMacUnavailableError`, which the sheets surface.
    var editingActions: SupermuxProjectEditingActions {
        primarySession?.editingActions ?? Self.unavailableEditingActions
    }

    /// Builds a file-browser store on the lead Mac, or `nil` while
    /// disconnected or without `supermux.files.v1`.
    /// - Parameter root: The confined root to browse.
    public func makeFileBrowserStore(root: SupermuxFilesRoot) -> SupermuxMobileFileBrowserStore? {
        primarySession?.makeFileBrowserStore(root: root)
    }

    /// An editor seam whose every call fails with "not connected".
    static var unavailableEditingActions: SupermuxProjectEditingActions {
        SupermuxProjectEditingActions(
            createProject: { _ in throw SupermuxMacUnavailableError() },
            updateProject: { _, _ in throw SupermuxMacUnavailableError() },
            deleteProject: { _ in throw SupermuxMacUnavailableError() },
            editorProject: { _ in nil },
            createPreset: { _ in throw SupermuxMacUnavailableError() },
            updatePreset: { _, _ in throw SupermuxMacUnavailableError() },
            deletePreset: { _ in throw SupermuxMacUnavailableError() }
        )
    }
}

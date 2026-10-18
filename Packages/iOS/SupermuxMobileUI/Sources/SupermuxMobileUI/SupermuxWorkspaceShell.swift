public import CmuxMobileShellModel

/// The phone shell's workspace list, as a nested drag reads and refreshes it.
///
/// The app's shell store (`MobileShellComposite`) already has both members;
/// the app declares the conformance, and tests use a fake.
@MainActor
public protocol SupermuxWorkspaceShell: AnyObject {
    /// Every connected Mac's rows, Mac by Mac.
    var workspaces: [MobileWorkspacePreview] { get }

    /// Fetches the list of the Mac that owns `id` again: the foreground
    /// Mac's own list, or a background Mac's coalesced refresh.
    /// - Parameter id: The workspace a mutation hit.
    func refreshAfterWorkspaceMutation(id: MobileWorkspacePreview.ID) async
}

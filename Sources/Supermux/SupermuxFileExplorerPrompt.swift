import AppKit
import SupermuxKit

/// Carries the destination for a "New File" / "New Folder" command from the
/// context menu to the action handler.
///
/// `parentDirectory` is where the new item is created; `expandNode` is the
/// directory tree node (if any) that must be expanded afterward so the new item
/// is visible. Reference type because it rides on `NSMenuItem.representedObject`.
final class SupermuxFileOpRequest: NSObject {
    let parentDirectory: URL
    let expandNode: FileExplorerNode?

    init(parentDirectory: URL, expandNode: FileExplorerNode?) {
        self.parentDirectory = parentDirectory
        self.expandNode = expandNode
    }
}

/// Localized strings for the file-explorer create/rename/duplicate/trash UI.
/// All keys are `supermux.fileOps.*` and live in `Resources/Localizable.xcstrings`.
enum SupermuxFileOpText {
    static var newFileMenu: String {
        String(localized: "supermux.fileOps.menu.newFile", defaultValue: "New File…")
    }
    static var newFolderMenu: String {
        String(localized: "supermux.fileOps.menu.newFolder", defaultValue: "New Folder…")
    }
    static var renameMenu: String {
        String(localized: "supermux.fileOps.menu.rename", defaultValue: "Rename…")
    }
    static var duplicateMenu: String {
        String(localized: "supermux.fileOps.menu.duplicate", defaultValue: "Duplicate")
    }
    static var moveToTrashMenu: String {
        String(localized: "supermux.fileOps.menu.moveToTrash", defaultValue: "Move to Trash")
    }

    static var newFileTitle: String {
        String(localized: "supermux.fileOps.prompt.newFile.title", defaultValue: "New File")
    }
    static var newFileMessageFormat: String {
        String(localized: "supermux.fileOps.prompt.newFile.message",
               defaultValue: "Enter a name for the new file in “%@”.")
    }
    static var newFolderTitle: String {
        String(localized: "supermux.fileOps.prompt.newFolder.title", defaultValue: "New Folder")
    }
    static var newFolderMessageFormat: String {
        String(localized: "supermux.fileOps.prompt.newFolder.message",
               defaultValue: "Enter a name for the new folder in “%@”.")
    }
    static var renameTitle: String {
        String(localized: "supermux.fileOps.prompt.rename.title", defaultValue: "Rename")
    }
    static var renameMessageFormat: String {
        String(localized: "supermux.fileOps.prompt.rename.message",
               defaultValue: "Enter a new name for “%@”.")
    }
    static var createButton: String {
        String(localized: "supermux.fileOps.prompt.create", defaultValue: "Create")
    }
    static var cancelButton: String {
        String(localized: "supermux.fileOps.prompt.cancel", defaultValue: "Cancel")
    }

    static var trashConfirmTitleSingleFormat: String {
        String(localized: "supermux.fileOps.trash.confirmTitleSingle",
               defaultValue: "Move “%@” to the Trash?")
    }
    static var trashConfirmTitleMultipleFormat: String {
        String(localized: "supermux.fileOps.trash.confirmTitleMultiple",
               defaultValue: "Move %lld items to the Trash?")
    }
    static var trashConfirmMessage: String {
        String(localized: "supermux.fileOps.trash.confirmMessage",
               defaultValue: "You can restore them later from the Trash.")
    }

    static var errorTitle: String {
        String(localized: "supermux.fileOps.error.title", defaultValue: "Couldn’t Complete the Operation")
    }
    static var errorInvalidNameFormat: String {
        String(localized: "supermux.fileOps.error.invalidName", defaultValue: "“%@” isn’t a valid name.")
    }
    static var errorAlreadyExistsFormat: String {
        String(localized: "supermux.fileOps.error.alreadyExists",
               defaultValue: "An item named “%@” already exists.")
    }
    static var errorNotFound: String {
        String(localized: "supermux.fileOps.error.notFound", defaultValue: "The item could no longer be found.")
    }
    static var errorGenericFormat: String {
        String(localized: "supermux.fileOps.error.generic", defaultValue: "The operation failed: %@")
    }
}

@MainActor
extension FileExplorerPanelView.Coordinator {
    /// The window hosting the explorer, used to anchor sheets.
    var supermuxHostWindow: NSWindow? {
        outlineView?.window ?? containerView?.window
    }

    /// Presents a single-field name prompt as a sheet; calls `onConfirm` with the
    /// entered text only when the user confirms (not on Cancel).
    func supermuxPromptForName(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String,
        onConfirm: @escaping (String) -> Void
    ) {
        guard let window = supermuxHostWindow else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: SupermuxFileOpText.cancelButton)

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingHead
        field.stringValue = defaultValue
        alert.accessoryView = field
        // Field editor selects all text on becoming first responder, so the
        // current name is pre-selected for a quick overwrite during rename.
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm(field.stringValue)
        }
    }

    /// Presents a Trash confirmation sheet; calls `onConfirm` when accepted.
    func supermuxConfirmTrash(_ nodes: [FileExplorerNode], onConfirm: @escaping () -> Void) {
        guard let window = supermuxHostWindow, !nodes.isEmpty else { return }
        let alert = NSAlert()
        if nodes.count == 1 {
            alert.messageText = String(format: SupermuxFileOpText.trashConfirmTitleSingleFormat, nodes[0].name)
        } else {
            alert.messageText = String(format: SupermuxFileOpText.trashConfirmTitleMultipleFormat, nodes.count)
        }
        alert.informativeText = SupermuxFileOpText.trashConfirmMessage
        alert.addButton(withTitle: SupermuxFileOpText.moveToTrashMenu)
        alert.addButton(withTitle: SupermuxFileOpText.cancelButton)
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            onConfirm()
        }
    }

    /// Maps a file-operation error to a localized title/message and shows it.
    func supermuxPresentFileOpError(_ error: Error) {
        let (title, message) = supermuxFileOpErrorText(for: error)
        guard let window = supermuxHostWindow else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func supermuxFileOpErrorText(for error: Error) -> (title: String, message: String) {
        let title = SupermuxFileOpText.errorTitle
        guard let opError = error as? SupermuxFileSystemOperationError else {
            return (title, error.localizedDescription)
        }
        switch opError {
        case .invalidName(let name):
            return (title, String(format: SupermuxFileOpText.errorInvalidNameFormat, name))
        case .alreadyExists(let name):
            return (title, String(format: SupermuxFileOpText.errorAlreadyExistsFormat, name))
        case .notFound:
            return (title, SupermuxFileOpText.errorNotFound)
        case .failed(let reason):
            return (title, String(format: SupermuxFileOpText.errorGenericFormat, reason))
        }
    }
}

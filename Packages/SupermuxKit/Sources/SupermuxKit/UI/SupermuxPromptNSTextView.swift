import AppKit

/// The plain-text view behind the New Worktree prompt. A plain-text
/// `NSTextView` ignores pasted or dropped images, so this one hands them to
/// ``onImages`` instead; text pastes and drops as usual.
final class SupermuxPromptNSTextView: NSTextView {
    /// Receives the image files of a paste or drop.
    var onImages: (([URL]) -> Void)?
    /// Told when the view gains or loses keyboard focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Takes keyboard focus once, when first placed in a window.
    var focusOnAppear = false
    private let importer = SupermuxPromptImageImporter()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        window.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        guard isEditable, let files = importer.imageFiles(from: .general) else {
            super.paste(sender)
            return
        }
        onImages?(files)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), SupermuxPromptImageImporter.holdsImages(.general) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: - Drop

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.png, .tiff]
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsImages(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsImages(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, let files = importer.imageFiles(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onImages?(files)
        return true
    }

    private func acceptsImages(_ sender: any NSDraggingInfo) -> Bool {
        isEditable && SupermuxPromptImageImporter.holdsImages(sender.draggingPasteboard)
    }
}

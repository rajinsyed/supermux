import AppKit

/// The plain-text view behind the New Worktree prompt. A plain-text
/// `NSTextView` ignores pasted or dropped images, so this one hands them to
/// ``onImages`` (unconverted: the receiver converts them off the main
/// actor); text pastes and drops as usual.
final class SupermuxPromptNSTextView: NSTextView {
    /// Receives the images of a paste or drop.
    var onImages: ((SupermuxPromptImageSource) -> Void)?
    /// Whether images are taken; when not, a paste or drop behaves as in a
    /// plain-text view (a dropped file inserts its path).
    var acceptsImages = true
    /// Told when the view gains or loses keyboard focus.
    var onFocusChange: ((Bool) -> Void)?
    /// Takes keyboard focus once, when first placed in a window, unless the
    /// user is already typing in another field there (the editor reappears
    /// when they switch Macs).
    var focusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        // A focused text field edits through the window's field editor, an NSText.
        guard !(window.firstResponder is NSText) else { return }
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
        guard isEditable, acceptsImages, let images = SupermuxPromptImageImporter.source(from: .general) else {
            super.paste(sender)
            return
        }
        onImages?(images)
    }

    // A plain-text view disables Paste for an image-only pasteboard; both
    // validation paths (menu item and generic) enable it here.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        pastesImages(menuItem.action) ?? super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        pastesImages(item.action) ?? super.validateUserInterfaceItem(item)
    }

    /// Whether Paste is enabled for images, or `nil` to let the text view decide.
    private func pastesImages(_ action: Selector?) -> Bool? {
        guard action == #selector(paste(_:)), acceptsImages, SupermuxPromptImageImporter.holdsImages(.general) else {
            return nil
        }
        return isEditable
    }

    // MARK: - Drop

    /// Every image type `NSImage` reads, so a drop is delivered for any image
    /// data ``SupermuxPromptImageImporter/holdsImages(_:)`` accepts.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(rawValue:))
    }

    /// Whether the current drag carries images, read once when it enters.
    private var dragHoldsImages = false

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragHoldsImages = SupermuxPromptImageImporter.holdsImages(sender.draggingPasteboard)
        return takesImages ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        takesImages ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard takesImages, let images = SupermuxPromptImageImporter.source(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onImages?(images)
        return true
    }

    private var takesImages: Bool {
        isEditable && acceptsImages && dragHoldsImages
    }
}

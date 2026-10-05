import AppKit

/// The plain-text view behind the New Worktree prompt. A plain-text
/// `NSTextView` ignores pasted or dropped images, so this one hands them to
/// ``onImages`` instead; text pastes and drops as usual.
final class SupermuxPromptNSTextView: NSTextView {
    /// Receives the image files of a paste or drop.
    var onImages: (([URL]) -> Void)?
    /// Whether images are taken; when not, a paste or drop behaves as in a
    /// plain-text view (a dropped file inserts its path).
    var acceptsImages = true
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
        guard isEditable, acceptsImages, let files = importer.imageFiles(from: .general) else {
            super.paste(sender)
            return
        }
        onImages?(files)
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
        guard takesImages, let files = importer.imageFiles(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onImages?(files)
        return true
    }

    private var takesImages: Bool {
        isEditable && acceptsImages && dragHoldsImages
    }
}

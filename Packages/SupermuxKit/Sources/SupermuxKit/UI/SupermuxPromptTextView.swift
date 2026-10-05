import AppKit
import SwiftUI

/// The New Worktree prompt's editor: a plain-text editor like `TextEditor`
/// (13 pt system font, scrolls past its height) that also takes images,
/// handing a pasted or dropped image to `onImages` (see
/// ``SupermuxPromptNSTextView``).
///
/// Its ideal height follows the text, so the sheet's `frame(minHeight:maxHeight:)`
/// grows it while typing and scrolls past the maximum.
struct SupermuxPromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEditable: Bool
    /// Whether pasted or dropped images are attached (else they act as in
    /// a plain-text view).
    var acceptsImages: Bool
    var focusOnAppear: Bool
    var onImages: (SupermuxPromptImageSource) -> Void

    /// Insets that put the first character where the sheet's placeholder is.
    static let textInset = NSSize(width: 4, height: 8)

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = SupermuxPromptNSTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Prompts often hold code: keep quotes and dashes as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text
        textView.focusOnAppear = focusOnAppear
        textView.delegate = context.coordinator

        let scrollView = FillingScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SupermuxPromptNSTextView else { return }
        if textView.string != text { textView.string = text }
        update(textView, coordinator: context.coordinator)
    }

    /// The text's height at the proposed width (the view's own width before
    /// SwiftUI proposes one), for the sheet's frame to clamp.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = proposed ?? scrollView.frame.width
        let textHeight = context.coordinator.measuredHeight(
            of: textView.string,
            font: textView.font,
            width: width - Self.textInset.width * 2
        )
        return CGSize(width: width, height: ceil(textHeight + Self.textInset.height * 2))
    }

    private func update(_ textView: SupermuxPromptNSTextView, coordinator: Coordinator) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.acceptsImages = acceptsImages
        textView.onImages = { images in coordinator.parent.onImages(images) }
        // Focus can change while SwiftUI is placing the view (focus on
        // appear); the binding is written after that pass.
        textView.onFocusChange = { focused in
            Task { @MainActor in coordinator.parent.isFocused = focused }
        }
    }

    /// Keeps the text view at least as tall as the visible area, so a click
    /// below a short prompt still lands in it.
    private final class FillingScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let textView = documentView as? NSTextView,
                  textView.minSize.height != contentSize.height else { return }
            textView.minSize.height = contentSize.height
            textView.sizeToFit()
        }
    }

    /// Pushes typed text into the binding, and measures it.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SupermuxPromptTextView
        // Lays the text out at any width without touching the view, whose
        // own width is still zero before its first layout.
        private let measureStorage = NSTextStorage()
        private let measureLayout = NSLayoutManager()
        private let measureContainer = NSTextContainer()

        init(parent: SupermuxPromptTextView) {
            self.parent = parent
            super.init()
            measureStorage.addLayoutManager(measureLayout)
            measureLayout.addTextContainer(measureContainer)
        }

        /// The laid-out height of `text` in a text container `width` wide.
        func measuredHeight(of text: String, font: NSFont?, width: CGFloat) -> CGFloat {
            if measureStorage.string != text {
                let font = font ?? .systemFont(ofSize: 13)
                measureStorage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            }
            measureContainer.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
            measureLayout.ensureLayout(for: measureContainer)
            return measureLayout.usedRect(for: measureContainer).height
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

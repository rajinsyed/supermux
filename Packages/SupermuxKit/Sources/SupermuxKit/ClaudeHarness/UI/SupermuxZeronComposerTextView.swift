import AppKit
import SwiftUI
import SupermuxZeronUI

/// The macOS composer input: an `NSTextView` bridge with zeron's exact text
/// metrics and the unwrapped-width measurement the flip decision needs.
///
/// ── Why not `TextEditor` ──
///
/// `TextEditor` gives no control over the 2 pt caret rect, the exact 22.75 pt
/// line box, the selection rect geometry, or the container inset — and, fatally
/// for this design, no way to measure a line's **unwrapped** width. The flip
/// rule compares the widest unwrapped line against a learned compact capacity;
/// a wrapped measurement is the post-flip width, which feeds back into the
/// decision that produced it and oscillates (spec 04 §1.2).
///
/// ── The metrics, and why each one is set explicitly ──
///
/// | Property | Value | Why |
/// |---|---|---|
/// | line box | **22.75** fixed (`min == max`) | `.lineSpacing` adds space *between* lines without setting the box, so the first line's ascent is wrong and every derived height drifts (plan R7). |
/// | font | Geist 14 | Geist is narrower than SF Pro; a silent fallback shifts every measured width in the specs (plan R10). |
/// | caret | 2 pt, `theme.caret` | `insertionPointColor` tints it; `drawInsertionPoint` pins the width. The 500 ms square wave is `NSTextView`'s own default and is close enough (plan R11). |
/// | selection | `theme.selection` | Flat rects behind the glyphs, no rounding — which is what `selectedTextAttributes` produces. |
/// | container inset | `.zero` + `lineFragmentPadding = 0` | The pill owns all 16 pt of the leading inset; a default 5 pt padding would put the text at 21. |
///
/// ── Return vs Shift-Return ──
///
/// Return sends and Shift-Return inserts a newline, intercepted in
/// `doCommandBy` so IME composition is untouched: while marked text exists
/// AppKit routes the key to the input context and never reaches this method.
struct SupermuxZeronComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let theme: SupermuxZeronTheme
    let placeholder: String
    /// Whether the view should hold first responder.
    @Binding var isFocused: Bool
    /// Fires after every layout with a fresh measurement for the flip reducer.
    let onMeasure: (SupermuxZeronComposerFlip.Measurement) -> Void
    /// Fires on every edit and caret move with the caret's character offset,
    /// which drives the slash token.
    let onCaretChange: (Int) -> Void
    /// Return with no Shift.
    let onSubmit: () -> Void
    /// A key the slash menu claims while it is open. Returning `true` swallows
    /// it; `false` lets the text view handle it normally.
    let onMenuKey: (SupermuxZeronComposerMenuKey) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Registration is lazy and CoreText substitutes SILENTLY, so touch the
        // font table before anything asks AppKit for "Geist".
        SupermuxZeronFonts.assertRegistered()

        let textView = MeasuringTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.contentInsets = NSEdgeInsets()
        context.coordinator.textView = textView
        apply(theme: theme, to: textView)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MeasuringTextView else { return }
        context.coordinator.parent = self
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let location = min(selected.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
        }
        apply(theme: theme, to: textView)
        textView.placeholder = placeholder
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
        textView.measureAndReport()
    }

    private func apply(theme: SupermuxZeronTheme, to textView: MeasuringTextView) {
        let font = SupermuxZeronFonts.platformSans(
            size: SupermuxZeronMetrics.Composer.inputTextSize
        )
        textView.font = font
        textView.defaultParagraphStyle = Self.paragraphStyle
        // Empty input renders the placeholder tone; typing switches to `text` —
        // the whole input's color flips, exactly as `composer.rs:3081` does.
        textView.textColor = NSColor(text.isEmpty ? theme.textFaint : theme.text)
        textView.insertionPointColor = NSColor(theme.caret)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(theme.selection),
        ]
        textView.typingAttributes = [
            .font: font,
            .paragraphStyle: Self.paragraphStyle,
            .foregroundColor: NSColor(theme.text),
        ]
        textView.placeholderColor = NSColor(theme.textFaint)
        textView.placeholder = placeholder
    }

    /// The FIXED 22.75 pt line box. `minimum == maximum` is the whole point:
    /// anything else lets a tall glyph grow the box and desynchronize the
    /// analytic `clamp(h + 20, 76, 260) + 46 + 2`.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = SupermuxZeronMetrics.Composer.inputLineHeight
        style.maximumLineHeight = SupermuxZeronMetrics.Composer.inputLineHeight
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SupermuxZeronComposerTextView
        weak var textView: MeasuringTextView?

        init(_ parent: SupermuxZeronComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MeasuringTextView else { return }
            parent.text = textView.string
            textView.measureAndReport()
            reportCaret(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MeasuringTextView else { return }
            reportCaret(in: textView)
        }

        private func reportCaret(in textView: NSTextView) {
            // The slash model counts CHARACTERS; `NSRange` counts UTF-16 units.
            let utf16Offset = textView.selectedRange().location
            let string = textView.string
            guard let index = String.Index(
                String.Index(utf16Offset: utf16Offset, in: string),
                within: string
            ) else {
                parent.onCaretChange(string.count)
                return
            }
            parent.onCaretChange(string.distance(from: string.startIndex, to: index))
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            // `StandardKeyBinding.dict` maps BOTH Return and Shift-Return to
            // `insertNewline:` — only Option-Return gets
            // `insertNewlineIgnoringFieldEditor:` (verified directly against
            // AppKit's binding table). So the selector ALONE cannot tell the two
            // apart, and `NSApp.currentEvent` is already nil by the time the
            // input context calls back; the shift state has to be latched in
            // `keyDown`.
            let shift = (textView as? MeasuringTextView)?
                .lastKeyDownModifiers.contains(.shift) ?? false
            let isReturn = selector == #selector(NSResponder.insertNewline(_:))

            // While the slash menu is open it claims ↑ ↓ Tab Return Escape; the
            // input keeps focus and native text editing throughout, exactly as
            // `set_mention_controls` does — it merely redirects bound keys.
            // Shift-Return is NOT one of them: zeron binds `enter` and
            // `shift-enter` to different actions, so a shift-held Return must
            // reach the newline path even with a row highlighted.
            if !(isReturn && shift),
               let key = SupermuxZeronComposerMenuKey(selector: selector),
               parent.onMenuKey(key) {
                return true
            }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if shift {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }

    // MARK: - The measuring text view

    /// An `NSTextView` that reports zeron's five measurements after every
    /// layout, and paints the placeholder itself.
    final class MeasuringTextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder: String = ""
        var placeholderColor: NSColor = .secondaryLabelColor
        /// The modifiers of the key event currently being interpreted. Latched
        /// here because AppKit's input context clears `NSApp.currentEvent`
        /// before `doCommandBy` runs, and Return vs Shift-Return share one
        /// selector.
        private(set) var lastKeyDownModifiers: NSEvent.ModifierFlags = []
        /// Bumped on every layout, so the flip reducer can enforce "at most one
        /// flip per layout pass".
        private var layoutEpoch: UInt64 = 0
        private var lastReported: SupermuxZeronComposerFlip.Measurement?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredContentHeight)
        }

        override func layout() {
            super.layout()
            measureAndReport()
        }

        override func keyDown(with event: NSEvent) {
            lastKeyDownModifiers = event.modifierFlags
            super.keyDown(with: event)
            lastKeyDownModifiers = []
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            // The placeholder is shaped by the SAME metrics as real content, so
            // it sits exactly where the first line of text would.
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? SupermuxZeronFonts.platformSans(
                    size: SupermuxZeronMetrics.Composer.inputTextSize
                ),
                .foregroundColor: placeholderColor,
                .paragraphStyle: SupermuxZeronComposerTextView.paragraphStyle,
            ]
            (placeholder as NSString).draw(at: .zero, withAttributes: attributes)
        }

        /// A 2 pt caret, not the system's 1 pt.
        override func drawInsertionPoint(
            in rect: NSRect,
            color: NSColor,
            turnedOn flag: Bool
        ) {
            var rect = rect
            rect.size.width = SupermuxZeronMetrics.Composer.caretWidth
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        }

        override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
            var rect = rect
            rect.size.width += SupermuxZeronMetrics.Composer.caretWidth
            super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
        }

        /// `content_height = max(sum of line heights, 22.75)`.
        var measuredContentHeight: CGFloat {
            guard let layoutManager, let textContainer else {
                return SupermuxZeronMetrics.Composer.inputLineHeight
            }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer).height
            return max(used, SupermuxZeronMetrics.Composer.inputLineHeight)
        }

        /// The widest **unwrapped** line — the flip's `text_width`.
        ///
        /// Measured off the string, not off the laid-out fragments: a wrapped
        /// fragment's width is capped by the container, which is precisely the
        /// feedback the learned capacity exists to avoid. Returns **0 while the
        /// placeholder is showing**, so the placeholder can never trigger the
        /// expand flip.
        var measuredUnwrappedWidth: CGFloat {
            guard !string.isEmpty else { return 0 }
            let font = font ?? SupermuxZeronFonts.platformSans(
                size: SupermuxZeronMetrics.Composer.inputTextSize
            )
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            return string
                .split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { widest, line in
                    max(widest, (String(line) as NSString).size(withAttributes: attributes).width)
                }
        }

        /// Publishes one measurement, bumping the layout epoch. Skipped when
        /// nothing that matters changed, so a redraw does not re-arm a flip.
        func measureAndReport() {
            layoutEpoch += 1
            let measurement = SupermuxZeronComposerFlip.Measurement(
                textWidth: measuredUnwrappedWidth,
                hasNewline: string.contains("\n"),
                contentHeight: measuredContentHeight,
                lastWidth: bounds.width,
                layoutEpoch: layoutEpoch
            )
            if let lastReported,
               lastReported.textWidth == measurement.textWidth,
               lastReported.hasNewline == measurement.hasNewline,
               lastReported.contentHeight == measurement.contentHeight,
               lastReported.lastWidth == measurement.lastWidth {
                return
            }
            lastReported = measurement
            coordinator?.parent.onMeasure(measurement)
        }
    }
}

/// The keys the slash menu claims while it is open.
enum SupermuxZeronComposerMenuKey: Sendable, Equatable, Hashable {
    case up
    case down
    case tab
    case accept
    case dismiss

    init?(selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): self = .up
        case #selector(NSResponder.moveDown(_:)): self = .down
        case #selector(NSResponder.insertTab(_:)): self = .tab
        case #selector(NSResponder.insertNewline(_:)): self = .accept
        case #selector(NSResponder.cancelOperation(_:)): self = .dismiss
        default: return nil
        }
    }
}

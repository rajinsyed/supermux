import CmuxMobileSupport
import SwiftUI

struct AltScreenNoticeButton: View {
    let dismissNotice: () -> Void
    @State private var isPresentingExplanation = false

    var body: some View {
        Button {
            isPresentingExplanation = true
        } label: {
            Label(buttonAccessibilityLabel, systemImage: "exclamationmark.triangle.fill")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.orange)
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityIdentifier("MobileTerminalAltScreenNoticeButton")
        // SUPERMUX:begin ios-workspace-toolbar-persistent-actions
        .altScreenNoticeExplanationPopover(
            isPresented: $isPresentingExplanation,
            dismissNotice: dismissFromPopover
        )
        // SUPERMUX:end ios-workspace-toolbar-persistent-actions
    }

    private var buttonAccessibilityLabel: String {
        L10n.string(
            "mobile.altScreenNotice.button.accessibilityLabel",
            defaultValue: "Explain full-screen terminal sizing"
        )
    }

    private func dismissFromPopover() {
        dismissNotice()
        isPresentingExplanation = false
    }
}

// SUPERMUX:begin ios-workspace-toolbar-persistent-actions
/// The alt-screen sizing explanation, shared by the standalone notice button
/// above and the workspace toolbar's overflow-menu entry so both entry points
/// present identical content.
extension View {
    func altScreenNoticeExplanationPopover(
        isPresented: Binding<Bool>,
        dismissNotice: @escaping () -> Void
    ) -> some View {
        popover(isPresented: isPresented) {
            ViewThatFits(in: .vertical) {
                AltScreenNoticeExplanationContent(dismissNotice: dismissNotice)

                ScrollView {
                    AltScreenNoticeExplanationContent(dismissNotice: dismissNotice)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(
                idealWidth: AltScreenNoticePresentationSizing.maxWidth,
                maxWidth: AltScreenNoticePresentationSizing.maxWidth
            )
            .presentationSizing(AltScreenNoticePresentationSizing())
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct AltScreenNoticeExplanationContent: View {
    let dismissNotice: () -> Void

    static var title: String {
        L10n.string(
            "mobile.altScreenNotice.title",
            defaultValue: "Full-screen terminal app"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(Self.title)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.orange)

            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: dismissNotice) {
                Text(dismissActionTitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote.weight(.medium))
            .accessibilityIdentifier("MobileTerminalAltScreenNoticeDismissPermanentlyButton")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var explanation: String {
        L10n.string(
            "mobile.altScreenNotice.explanation",
            defaultValue: "Full-screen mode mirrors the Mac terminal's exact size, so it may not fill this screen. Claude Code: `/tui default`. Codex: restart with `codex --no-alt-screen`."
        )
    }

    private var dismissActionTitle: String {
        L10n.string(
            "mobile.altScreenNotice.dismissAction",
            defaultValue: "Don't Show Again"
        )
    }
}
// SUPERMUX:end ios-workspace-toolbar-persistent-actions

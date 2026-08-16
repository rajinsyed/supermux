//
//  SupermuxZeronSendButton.swift
//  SupermuxZeronUI
//
//  The 28 pt circle: send / steer / stop. Spec 04 §5, from
//  `composer.rs:5140-5188`.
//
//  ── The two corrections this file encodes ──
//
//  1. **Stop is NEUTRAL** (plan §0.3 C11). `composer.rs:370`'s comment and
//     `feature-inventory.md` §1.7 both call it a "red stop square"; the rendered
//     element uses `theme.text` for the plate and `theme.bg` for the 11 pt
//     `rounded(3)` square, and `02-after-working-overlay.png` confirms a light
//     grey circle with a dark square. There is no red in `render_send_button`.
//  2. **There is NO transition between Send/Steer and Stop.** They are separate
//     elements with different ids; gpui swaps them on the frame the mode
//     changes. No cross-fade, no morph. The hover opacity is likewise a snap —
//     a plain `.hover()`, not a `hover_blend`.
//
//  Send and Steer are visually IDENTICAL: nothing in the rendered element
//  distinguishes them. The difference is only which command is queued.
//

public import SwiftUI

/// The composer's send / steer / stop button.
public struct SupermuxZeronSendButton: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let mode: SupermuxZeronSendMode
    private let isBlocked: Bool
    private let onSubmit: () -> Void
    private let onInterrupt: () -> Void

    @State private var isHovered = false

    /// - Parameters:
    ///   - isBlocked: Dimmed to 0.35 and fully inert — the cursor and the click
    ///     listener are both removed, so this is not merely a disabled look.
    ///     Only ever true for the submitting arms.
    public init(
        theme: SupermuxZeronTheme,
        mode: SupermuxZeronSendMode,
        isBlocked: Bool = false,
        onSubmit: @escaping () -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        self.theme = theme
        self.mode = mode
        self.isBlocked = isBlocked
        self.onSubmit = onSubmit
        self.onInterrupt = onInterrupt
    }

    public var body: some View {
        Button(action: activate) {
            ZStack {
                Circle().fill(theme.text)
                glyph
            }
            .frame(width: Metrics.sendDiameter, height: Metrics.sendDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { isHovered = $0 && !blocked }
        // gpui's `.opacity()` multiplies through to children, so the glyph dims
        // with the plate — SwiftUI behaves the same way.
        .opacity(opacity)
        // The source SNAPS: no animation modifier on either the hover opacity
        // or the mode swap.
        .animation(nil, value: mode)
        .animation(nil, value: isHovered)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Only the submitting arms can be blocked; Stop always works.
    private var blocked: Bool { isBlocked && mode.submits }

    @ViewBuilder
    private var glyph: some View {
        switch mode {
        case .send, .steer:
            SupermuxZeronComposerIcon(.arrowUp, size: Metrics.sendGlyph)
                .foregroundStyle(theme.bg)
        case .stop:
            RoundedRectangle(cornerRadius: Metrics.stopSquareRadius, style: .continuous)
                .fill(theme.bg)
                .frame(width: Metrics.stopSquare, height: Metrics.stopSquare)
        }
    }

    private var opacity: Double {
        if blocked { return 0.35 }
        return isHovered ? 0.85 : 1
    }

    private func activate() {
        guard !blocked else { return }
        if mode.submits { onSubmit() } else { onInterrupt() }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .send:
            String(
                localized: "supermux.zeron.composer.send",
                defaultValue: "Send",
                bundle: .supermuxZeronUI
            )
        case .steer:
            String(
                localized: "supermux.zeron.composer.steer",
                defaultValue: "Send — steers the current run",
                bundle: .supermuxZeronUI
            )
        case .stop:
            String(
                localized: "supermux.zeron.composer.stop",
                defaultValue: "Stop",
                bundle: .supermuxZeronUI
            )
        }
    }
}

// MARK: - Attach

/// The paperclip: a 28 pt square with `rounded_full`, a 16 pt icon at
/// `textMuted`, and an `ink(0.10)` hover wash faded over 150 ms.
public struct SupermuxZeronAttachButton: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(theme: SupermuxZeronTheme, action: @escaping () -> Void) {
        self.theme = theme
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            SupermuxZeronComposerIcon(.paperclip, size: Metrics.attachIcon)
                .foregroundStyle(theme.textMuted)
                .frame(width: Metrics.attachButton, height: Metrics.attachButton)
                .background(
                    Circle()
                        .fill(theme.ink(0.10))
                        .opacity(isHovered ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
                            value: isHovered
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(
            String(
                localized: "supermux.zeron.composer.attach",
                defaultValue: "Attach",
                bundle: .supermuxZeronUI
            )
        )
    }
}

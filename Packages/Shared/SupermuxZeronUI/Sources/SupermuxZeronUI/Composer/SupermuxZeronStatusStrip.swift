//
//  SupermuxZeronStatusStrip.swift
//  SupermuxZeronUI
//
//  The 24 pt reserved strip ABOVE the pill. Spec 04 §6.1, from
//  `theme.rs:456` + `shell.rs:4798-4868`.
//
//  ── The reserved-height rule ──
//
//  The strip renders its 24 pt box **unconditionally**, and is EMPTY in most
//  states. Reserving it is what stops the composer shifting when a run starts or
//  ends, and its height is load-bearing for the transcript's bottom edge fade:
//  the fade is opaque from the PILL's top, and the strip above it is treated as
//  empty air (`bottom_band = stack_h − 24`).
//
//  ── What the strip does NOT own ──
//
//  The working indicator ("Sifting… 15s") is **not here in this build.** It
//  moved into the transcript, appended under the last row while the run is live
//  "so it reads as part of the streaming reply and scrolls away with it"
//  (`transcript.rs:2642`). It lands just above the composer only because the
//  last row is pinned to the bottom. `SupermuxZeronWorkingTrailer` (W1) owns it;
//  this strip stays empty in the `.working` state and merely holds the air.
//

public import SwiftUI

/// What the strip shows, keyed by the session indicator.
///
/// Every case except `.errored` and `.sending` renders an EMPTY 24 pt box.
public enum SupermuxZeronStatusStripState: Sendable, Equatable, Hashable {
    /// A live run — empty; the working loader lives in the transcript.
    case working
    /// Awaiting input — empty; the question surface below is the answer.
    case awaitingInput
    /// `"Run failed"` in `theme.danger` at 11 pt.
    case errored
    /// An in-flight send with no live run: the spinner plus `"Sending…"` at
    /// 12 pt `textMuted`.
    case sending
    /// Idle, or no session — empty.
    case idle
}

/// The reserved 24 pt strip above the composer pill.
public struct SupermuxZeronStatusStrip: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer

    private let theme: SupermuxZeronTheme
    private let state: SupermuxZeronStatusStripState

    public init(theme: SupermuxZeronTheme, state: SupermuxZeronStatusStripState) {
        self.theme = theme
        self.state = state
    }

    public var body: some View {
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            content
            Spacer(minLength: 0)
        }
        // The strip's px is 24 — 8 pt MORE inset than the composer container's
        // 16, so its content aligns with the pill's inner text, not its border.
        // The padding precedes the 768 cap because gpui's `max_w` is the BORDER
        // box: the 24 lives inside the 768, exactly as the composer column's 16
        // does. The strip must therefore be a SIBLING of that column, never a
        // child of it, or it inherits the 16 on top and lands 24 pt off.
        .padding(.horizontal, SupermuxZeronMetrics.Theme.spaceLG + 8)
        .frame(height: SupermuxZeronMetrics.Theme.statusStripHeight)
        .frame(maxWidth: Metrics.containerMaxWidth)
        .frame(maxWidth: .infinity)
        // Reserved even when empty: this is what stops the composer shifting.
        .accessibilityHidden(accessibilityText == nil)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .errored:
            Text(
                String(
                    localized: "supermux.zeron.status.runFailed",
                    defaultValue: "Run failed",
                    bundle: .supermuxZeronUI
                )
            )
            .font(SupermuxZeronFonts.sans(size: 11))
            .foregroundStyle(theme.danger)
        case .sending:
            // `gradient_spinner("sending-indicator", …, 2.5)` — the SHARED
            // loader, leased on the one 30 fps clock so it is phase-locked with
            // the transcript's working trailer.
            SupermuxZeronGradientSpinner(leaseID: "sending-indicator")
            Text(
                String(
                    localized: "supermux.zeron.status.sending",
                    defaultValue: "Sending…",
                    bundle: .supermuxZeronUI
                )
            )
            .font(SupermuxZeronFonts.sans(size: 12))
            .foregroundStyle(theme.textMuted)
        case .working, .awaitingInput, .idle:
            EmptyView()
        }
    }

    private var accessibilityText: String? {
        switch state {
        case .errored, .sending: ""
        case .working, .awaitingInput, .idle: nil
        }
    }
}

// MARK: - Notice chip

/// The failure / notice chip shown ABOVE the pill inside the container.
/// Spec 04 §1.8, from `composer.rs:5327-5402`. A click anywhere dismisses it.
public struct SupermuxZeronComposerNotice: View {
    /// Which palette the chip wears.
    public enum Severity: Sendable, Equatable, Hashable {
        /// The engine is not connected — amber, not red.
        case offline
        /// Any other failure — red.
        case failure
    }

    private let theme: SupermuxZeronTheme
    private let severity: Severity
    private let message: String
    private let onDismiss: () -> Void

    public init(
        theme: SupermuxZeronTheme,
        severity: Severity,
        message: String,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.theme = theme
        self.severity = severity
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            SupermuxZeronComposerIcon(.dangerTriangle, size: 14)
                .foregroundStyle(textColor)
                .padding(.top, 2)
            Text(message)
                .font(SupermuxZeronFonts.sans(size: 12))
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(base.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(base.opacity(0.16), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    private var base: Color {
        switch severity {
        case .offline: theme.warning
        case .failure: theme.danger
        }
    }

    private var textColor: Color {
        switch severity {
        case .offline: theme.warningMuted.opacity(0.9)
        case .failure: theme.dangerMuted.opacity(0.9)
        }
    }
}

/// The turn-boundary steer hint, shown when the button is in Steer mode and the
/// harness can only steer at a turn boundary (`composer.rs:5392`).
public struct SupermuxZeronSteerHint: View {
    private let theme: SupermuxZeronTheme

    public init(theme: SupermuxZeronTheme) { self.theme = theme }

    public var body: some View {
        Text(
            String(
                localized: "supermux.zeron.composer.steerHint",
                defaultValue: """
                    This agent can't be steered mid-turn — your message will be queued \
                    and sent when the current turn finishes.
                    """,
                bundle: .supermuxZeronUI
            )
        )
        .font(SupermuxZeronFonts.sans(size: 11))
        .foregroundStyle(theme.textMuted.opacity(0.8))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

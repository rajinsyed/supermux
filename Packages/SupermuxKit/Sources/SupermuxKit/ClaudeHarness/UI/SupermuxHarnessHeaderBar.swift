import SwiftUI
import CmuxFoundation
import SupermuxClaudeHarness

/// The panel's top chrome: working directory, model, session state, cost, and
/// the interrupt control.
///
/// Takes immutable values plus closures — it must not hold the session model,
/// so the same bar can be rendered from a preview or a test.
struct SupermuxHarnessHeaderBar: View {
    let workingDirectory: String
    let modelLabel: String?
    let stateLabel: String
    let stateColor: Color
    let totalCostUSD: Double?
    let isBusy: Bool
    let theme: SupermuxHarnessTheme
    let onInterrupt: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing8) {
            directoryChip
            if let modelLabel {
                chip(text: modelLabel, symbol: "sparkles")
            }
            Spacer(minLength: SupermuxHarnessTokens.spacing4)
            stateIndicator
            // Hidden until a turn actually cost something: "$0.0000" on a
            // fresh session reads as a bug, not as information.
            if let totalCostUSD, totalCostUSD > 0 {
                Text(String(format: "$%.4f", totalCostUSD))
                    .cmuxFont(size: SupermuxHarnessTokens.caption, monospacedDigit: true)
                    .foregroundStyle(theme.mutedText)
                    .supermuxHarnessRigidLabel()
            }
            // No header stop button: the composer's send→stop morph is the one
            // interrupt affordance (four simultaneous busy signals is three too
            // many). `onInterrupt` stays in the API for a future menu action.
        }
        .padding(.horizontal, SupermuxHarnessTokens.spacing10)
        .padding(.vertical, SupermuxHarnessTokens.spacing6)
        .background(theme.pageIsTransparent ? Color.clear : theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: SupermuxHarnessTokens.hairline)
        }
    }

    private var directoryChip: some View {
        chip(
            text: (workingDirectory as NSString).lastPathComponent,
            symbol: "folder"
        )
        .help(workingDirectory)
    }

    private func chip(text: String, symbol: String) -> some View {
        HStack(spacing: SupermuxHarnessTokens.spacing4) {
            Image(systemName: symbol)
                .font(.system(size: SupermuxHarnessTokens.caption2))
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .cmuxFont(size: SupermuxHarnessTokens.caption)
        .foregroundStyle(theme.softText)
        .padding(.horizontal, SupermuxHarnessTokens.spacing6)
        .padding(.vertical, SupermuxHarnessTokens.spacing2)
        .background(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
            )
            .fill(theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: SupermuxHarnessTokens.chipRadius, style: .continuous
            )
            .strokeBorder(theme.border, lineWidth: SupermuxHarnessTokens.hairline)
        )
    }

    /// The state dot breathes while a turn is running — the transcript's own
    /// liveness signal (a static dot reads as a dead panel). Static under
    /// Reduce Motion.
    private var stateIndicator: some View {
        HStack(spacing: SupermuxHarnessTokens.spacing4) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .opacity(isBusy && isPulsing && !reduceMotion ? 0.35 : 1)
                .animation(
                    isBusy && !reduceMotion
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )
            Text(stateLabel)
                .cmuxFont(size: SupermuxHarnessTokens.caption)
                .foregroundStyle(theme.mutedText)
                .supermuxHarnessRigidLabel()
        }
        .onChange(of: isBusy) { _, busy in
            isPulsing = busy
        }
        .onAppear {
            isPulsing = isBusy
        }
    }
}

/// The user-facing name and dot colour of a session state.
///
/// lint:allow namespace-type — pure presentation mapping. (lint:allow)
enum SupermuxHarnessStatePresentation {
    static func label(
        process: ClaudeProcessPhase, turn: ClaudeTurnPhase
    ) -> String {
        switch process {
        case .dormant:
            return String(localized: "supermux.harness.state.idle", defaultValue: "Idle")
        case .spawning, .handshaking:
            return String(localized: "supermux.harness.state.starting", defaultValue: "Starting…")
        case .stopping:
            return String(localized: "supermux.harness.state.stopping", defaultValue: "Stopping…")
        case .exited:
            return String(localized: "supermux.harness.state.exited", defaultValue: "Ended")
        case .failed:
            return String(localized: "supermux.harness.state.failed", defaultValue: "Failed")
        case .running:
            switch turn {
            case .idle:
                return String(localized: "supermux.harness.state.ready", defaultValue: "Ready")
            case .dispatching, .active:
                return String(localized: "supermux.harness.state.working", defaultValue: "Working…")
            case .interrupting:
                return String(
                    localized: "supermux.harness.state.interrupting",
                    defaultValue: "Interrupting…"
                )
            case .uncertain:
                return String(
                    localized: "supermux.harness.state.uncertain",
                    defaultValue: "Delivery unknown"
                )
            }
        }
    }

    static func color(
        process: ClaudeProcessPhase, turn: ClaudeTurnPhase, theme: SupermuxHarnessTheme
    ) -> Color {
        switch process {
        case .failed:
            return theme.danger
        case .exited, .dormant, .stopping:
            return theme.mutedText
        case .spawning, .handshaking:
            return theme.toolAccent
        case .running:
            switch turn {
            case .idle: return theme.accent
            case .dispatching, .active, .interrupting: return theme.toolAccent
            case .uncertain: return theme.danger
            }
        }
    }
}

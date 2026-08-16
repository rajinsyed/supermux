//
//  SupermuxZeronNoticeRow.swift
//  SupermuxZeronUI
//
//  Notices, and the turn result summary. Plan §2.0 row table.
//
//  ── Two very different rows, one file ──
//
//  1. **Notice.** zeron's `error_chip` (`transcript.rs:3554-3604`) is the only
//     transcript-level notice it has: a 34 pt min-height card, radius 10, 1 pt
//     `danger @ 0.16` border on a `danger @ 0.05` fill, an 8 pt-padded row with
//     a 20 pt / radius 6 `danger @ 0.12` icon tile holding a 12 pt
//     danger-triangle at `dangerMuted @ 0.8`, the MEDIUM "Error" label in the
//     same tone, then the message at `text @ 0.8`. Everything is 12 pt.
//
//     supermux's notices carry three severities, so `info` and `warning` reuse
//     the identical geometry with the neutral (`ink(0.045)` fill, `hairline(0.08)`
//     border — zeron's own `input_chip` recipe) and warning tones. Nothing about
//     the box changes; only the ink does.
//
//  2. **Result summary.** zeron has NO result row: its header bar carried the
//     cost, and the plan deletes that bar (§2.1), routing cost to "the result
//     meta row" as a **quiet 11 pt `textFaint` meta line**. So this is a single
//     unadorned line of `"$0.0321 · 4.2s · 2 turns · ↑1024 ↓512"` — no plate, no
//     border, no icon. It is deliberately the least prominent thing in the
//     column: the number matters only when the user goes looking for it.
//

public import SupermuxClaudeHarness
public import SwiftUI

// MARK: - Notice

/// A launcher / protocol / process notice.
public struct SupermuxZeronNoticeRow: View {
    private let notice: SupermuxHarnessNotice
    private let theme: SupermuxZeronTheme

    public init(notice: SupermuxHarnessNotice, theme: SupermuxZeronTheme) {
        self.notice = notice
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // 20 pt / radius 6 icon tile.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tileFill)
                    .frame(width: 20, height: 20)
                    .overlay(
                        SupermuxZeronNoticeGlyph(asset: glyphAsset)
                            .frame(width: 12, height: 12)
                            .foregroundStyle(accent.opacity(0.8))
                    )
                Text(kindLabel)
                    .font(SupermuxZeronFonts.sans(size: 12, weight: .medium))
                    .foregroundStyle(accent.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                // The message WRAPS; it must never truncate. zeron's own comment
                // (`transcript.rs:3548-3552`) is emphatic: "Unlike the web port,
                // the message WRAPS instead of truncating: startup-crash errors
                // carry the agent's exit status and stderr, and a one-line
                // ellipsis was exactly what made zeronsh/comet#95 undiagnosable
                // from the screenshot." A `lineLimit(1)` here reintroduces that
                // exact bug, and supermux's launcher diagnostics are the same
                // shape of long, load-bearing message.
                Text(notice.title)
                    .font(SupermuxZeronFonts.sans(size: 12))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 34 - 14, alignment: .center)

            // zeron's chip truncates and drops the detail. supermux notices
            // regularly carry a multi-line launcher diagnostic that is the whole
            // point of the notice, so it renders under the header in mono at the
            // detail size — inside the same box, no disclosure control (a
            // chevron here would be the only fold in the transcript that is not
            // a tool group).
            if let detail = notice.detail, !detail.isEmpty {
                Text(detail)
                    .font(SupermuxZeronFonts.mono(size: SupermuxZeronMetrics.Chips.outputTextSize))
                    .foregroundStyle(theme.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 34, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(boxFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(boxBorder, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// The severity's ink. `error` and `warning` take their status tokens;
    /// `info` stays neutral, exactly as zeron's `input_chip` does.
    private var accent: Color {
        switch notice.severity {
        case .info: theme.textMuted
        case .warning: theme.warningMuted
        case .error: theme.dangerMuted
        }
    }

    private var boxFill: Color {
        switch notice.severity {
        case .info: theme.ink(0.045)
        case .warning: theme.warning.opacity(0.05)
        case .error: theme.danger.opacity(0.05)
        }
    }

    private var boxBorder: Color {
        switch notice.severity {
        case .info: theme.hairline(0.08)
        case .warning: theme.warning.opacity(0.16)
        case .error: theme.danger.opacity(0.16)
        }
    }

    private var tileFill: Color {
        switch notice.severity {
        case .info: theme.ink(0.09)
        case .warning: theme.warning.opacity(0.12)
        case .error: theme.danger.opacity(0.12)
        }
    }

    private var glyphAsset: String {
        switch notice.severity {
        case .info: "widget"
        case .warning, .error: "danger-triangle"
        }
    }

    private var kindLabel: String {
        switch notice.severity {
        case .info:
            String(localized: "supermux.zeron.notice.info", defaultValue: "Note", bundle: .supermuxZeronUI)
        case .warning:
            String(localized: "supermux.zeron.notice.warning", defaultValue: "Warning", bundle: .supermuxZeronUI)
        case .error:
            String(localized: "supermux.zeron.notice.error", defaultValue: "Error", bundle: .supermuxZeronUI)
        }
    }
}

/// A template glyph from the vendored Solar catalog.
///
/// Reads the asset directly rather than through an icon enum, because the enum
/// (`Icons/SupermuxZeronIcon.swift`) is owned by another workstream. **Swap this
/// for that enum when it lands** — the asset names here are the enum's cases.
struct SupermuxZeronNoticeGlyph: View {
    let asset: String

    var body: some View {
        Image(asset, bundle: .supermuxZeronUI)
            .renderingMode(.template)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Result summary

/// The turn's cost/duration summary, as a quiet 11 pt `textFaint` meta line.
public struct SupermuxZeronResultMetaRow: View {
    private let summary: SupermuxHarnessResultSummary
    private let theme: SupermuxZeronTheme

    public init(summary: SupermuxHarnessResultSummary, theme: SupermuxZeronTheme) {
        self.summary = summary
        self.theme = theme
    }

    public var body: some View {
        // No `.monospacedDigit()` — on a custom face it substitutes the SYSTEM
        // face rather than enabling Geist's own `tnum`, which would set this
        // line in San Francisco beside Geist text. See the working trailer.
        Text(verbatim: Self.line(for: summary))
            .font(SupermuxZeronFonts.sans(size: 11))
            .foregroundStyle(summary.isError ? theme.danger : theme.textFaint)
            .lineLimit(1)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ` · `-joined segments, in a fixed order.
    ///
    /// Pure and `static` so the line is testable and so the mobile projection
    /// can render the identical string.
    public static func line(for summary: SupermuxHarnessResultSummary) -> String {
        var parts: [String] = []
        if let cost = summary.totalCostUSD {
            parts.append(String(format: "$%.4f", cost))
        }
        if let duration = summary.durationMs {
            parts.append(durationText(milliseconds: duration))
        }
        if let turns = summary.numTurns {
            parts.append(
                String(
                    format: String(
                        localized: "supermux.zeron.result.turns",
                        defaultValue: "%lld turns",
                        bundle: .supermuxZeronUI
                    ),
                    Int64(turns)
                )
            )
        }
        if let input = summary.inputTokens, let output = summary.outputTokens {
            // U+2191 / U+2193, matching the jump pill's literal-glyph idiom.
            parts.append("\u{2191}\(input) \u{2193}\(output)")
        }
        if summary.terminalReason == "aborted_streaming" {
            parts.append(
                String(
                    localized: "supermux.zeron.result.interrupted",
                    defaultValue: "interrupted",
                    bundle: .supermuxZeronUI
                )
            )
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// `"420ms"` / `"4.2s"` / `"1m 12s"`.
    public static func durationText(milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

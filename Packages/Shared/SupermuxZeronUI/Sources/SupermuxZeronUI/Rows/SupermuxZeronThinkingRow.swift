//
//  SupermuxZeronThinkingRow.swift
//  SupermuxZeronUI
//
//  Extended thinking, rendered with the GROUP-HEADER PRIMITIVE (plan §2.0):
//  a 26 pt row, an 18 pt chevron tile carrying `▸`/`▾`, and a 12 pt
//  `text_muted` label that lifts to `text` on hover.
//
//  ── Why the group header and not a bespoke row ──
//
//  zeron has no thinking row of its own — supermux's Claude harness emits
//  thinking blocks and zeron's harnesses do not, so there is no upstream
//  geometry to copy. The plan resolves this by reusing the ONE existing
//  disclosure primitive in the design system rather than inventing a second
//  one, so a thinking row and a tool group are indistinguishable in weight,
//  height, tile, glyph and hover behaviour. Every value below is the tool
//  group's, read from `SupermuxZeronMetrics.Chips`.
//
//  What that replaces: the old `SupermuxHarnessThinkingRow` used an SF Symbol
//  `brain` glyph, an SF Symbol chevron that ROTATED, a one-line preview of the
//  newest line, and a 24 pt timeline-gutter indent. All four are gone —
//  zeron's disclosure glyph is a text character that is SWAPPED, not rotated,
//  and its body is flush.
//
//  ── The body is markdown ──
//
//  Thinking is prose; expanded, it renders through the same
//  `SupermuxZeronMarkdownView` as an assistant reply, so a numbered plan inside
//  a thinking block gets the accent markers and inline code gets the violet
//  wash. It is flush to the column's left edge for the same reason the
//  assistant row is.
//

public import SwiftUI

internal import Foundation

/// A thinking block, collapsed to its header until expanded.
public struct SupermuxZeronThinkingRow: View {
    private typealias Chips = SupermuxZeronMetrics.Chips

    private let text: String
    private let isStreaming: Bool
    private let theme: SupermuxZeronTheme
    private let rowKey: String
    private let onOpenURL: ((URL) -> Void)?

    @State private var isOpen = false
    @State private var isHeaderHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        text: String,
        isStreaming: Bool,
        theme: SupermuxZeronTheme,
        rowKey: String,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.theme = theme
        self.rowKey = rowKey
        self.onOpenURL = onOpenURL
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                SupermuxZeronAssistantRow(
                    text: text,
                    isStreaming: isStreaming,
                    theme: theme,
                    rowKey: "\(rowKey)-think",
                    onOpenURL: onOpenURL
                )
                .padding(.top, SupermuxZeronMetrics.Transcript.gapBlock)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: Chips.groupHeaderGap) {
            SupermuxZeronChipTile(fill: theme.ink(0.06)) {
                // Swapped, NOT rotated. The tool group does the same, and
                // adding a rotation here would make the two disclosure
                // affordances behave differently in the same transcript.
                Text(verbatim: isOpen ? "\u{25BE}" : "\u{25B8}")
                    .font(SupermuxZeronFonts.sans(size: Chips.tileChevronGlyph))
                    .foregroundStyle(theme.textMuted.opacity(0.7))
            }

            Text(label)
                .font(SupermuxZeronFonts.sans(size: Chips.textSize))
                .foregroundStyle(isHeaderHovered ? theme.text : theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Chips.groupHeaderPadX)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Chips.groupHeaderHeight)
        .contentShape(Rectangle())
        // Hover lifts the TEXT only; the tile's fill is static.
        .onHover { isHeaderHovered = $0 }
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: isHeaderHovered
        )
        .modifier(SupermuxZeronChipTapTarget(isEnabled: true) { isOpen.toggle() })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(.isButton)
    }

    private var label: String {
        isStreaming ? Self.thinkingLabel : Self.thoughtLabel
    }

    private static let thinkingLabel = String(
        localized: "supermux.zeron.thinking.active",
        defaultValue: "Thinking…",
        bundle: .module,
        comment: "Disclosure label on an extended-thinking block that is still streaming."
    )

    private static let thoughtLabel = String(
        localized: "supermux.zeron.thinking.settled",
        defaultValue: "Thought",
        bundle: .module,
        comment: "Disclosure label on a completed extended-thinking block."
    )
}

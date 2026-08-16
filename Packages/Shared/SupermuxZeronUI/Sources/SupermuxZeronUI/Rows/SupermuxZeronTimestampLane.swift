//
//  SupermuxZeronTimestampLane.swift
//  SupermuxZeronUI
//
//  The hover-revealed timestamp strip. Spec 02 §5.
//
//  ── The one rule that must not be broken ──
//
//  **The lane's height is RESERVED unconditionally.** It exists whether or not
//  the row is hovered; only the LABEL is conditional. That is what makes the
//  reveal free of layout cost — a SwiftUI implementation that inserts and
//  removes the label reflows the whole list, and in a virtualized transcript
//  that fights the stick spring on every pointer move.
//
//  So the lane is a `ZStack` over a zero-alpha spacer at a FIXED frame, and the
//  label's opacity is what animates. `spec 02 §13.2` prescribes exactly this.
//
//  ── Geometry ──
//
//                          user row    assistant row
//      lane height         16          20
//      lane top padding    0            4  (content lane = 16)
//      alignment           trailing     leading
//      horizontal inset    0            0   ← flush with the column edge
//
//  The zero horizontal inset is deliberate (`transcript.rs:2903-2909`): the web
//  original's `px-1` netted out flush because its message text carried the same
//  inset. Here the markdown text and the user bubble sit AT the content column
//  edges, so the label must too — the assistant label's left edge on the text's
//  first-character x, the user label's right edge on the bubble's right edge (a
//  user-reported 4 px drift).
//
//  The assistant's 4 pt top pad reproduces `chat-view.tsx:183`'s
//  `VStack padding={4}`. It is grown INTO the reserved height, so the reveal
//  still never shifts layout.
//
//  ── Format ──
//
//  Deliberately NOT localized. zeron hardcodes `"%b %-d, %-I:%M %p"`, so this
//  uses `dateFormat = "MMM d, h:mm a"` with `en_US_POSIX`. A localized template
//  would make `%p` locale-dependent and `%b` non-English, and the plan's final
//  note calls this out explicitly.
//

public import Foundation
public import SwiftUI

/// The height-reserved timestamp lane.
///
/// Below the `LazyVStack` boundary, so it takes only immutable values — a
/// `Date?` and two `Bool`s — and never an observable store.
public struct SupermuxZeronTimestampLane: View {
    private let timestamp: Date?
    private let isUserRow: Bool
    /// Whether ANY row of this entry is hovered (macOS), or the platform's
    /// touch-side equivalent (iOS: the last row of the most recent entry, or a
    /// row tapped within the last 3 s).
    private let isRevealed: Bool
    private let theme: SupermuxZeronTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        timestamp: Date?,
        isUserRow: Bool,
        isRevealed: Bool,
        theme: SupermuxZeronTheme
    ) {
        self.timestamp = timestamp
        self.isUserRow = isUserRow
        self.isRevealed = isRevealed
        self.theme = theme
    }

    private var laneHeight: CGFloat {
        isUserRow
            ? SupermuxZeronMetrics.Transcript.tsLaneUser
            : SupermuxZeronMetrics.Transcript.tsLaneAssistant
    }

    private var topPad: CGFloat {
        isUserRow ? 0 : SupermuxZeronMetrics.Transcript.tsLaneAssistantTopPad
    }

    private var alignment: Alignment { isUserRow ? .trailing : .leading }

    public var body: some View {
        // A row with no timestamp reserves NOTHING: zeron only builds the strip
        // for `row.timestamp.map(...)`, so an assistant row mid-stream — or any
        // non-final row of an entry — has no lane at all.
        if let timestamp {
            ZStack(alignment: alignment) {
                // The reservation. `wash(0)` rather than `Color.clear`, per the
                // token rule: a resting wash is white-at-zero-alpha so a
                // mid-fade blend never passes through grey.
                theme.wash(0)
                    .frame(maxWidth: .infinity)
                    .frame(height: laneHeight - topPad)
                Text(Self.label(for: timestamp))
                    .font(SupermuxZeronFonts.sans(size: 11))
                    .foregroundStyle(theme.textMuted.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(isRevealed ? 1 : 0)
            }
            .frame(height: laneHeight - topPad, alignment: alignment)
            .padding(.top, topPad)
            .frame(maxWidth: .infinity, alignment: alignment)
            // Opacity only, no translate. `fade_quick` = 150 ms EASE. zeron has
            // no exit animation here (the element is simply dropped), but a
            // SwiftUI opacity tween is symmetric; the difference is 150 ms of
            // fade-out on un-hover, which is strictly less jarring and cannot
            // shift layout.
            .animation(
                reduceMotion ? nil : SupermuxZeronMetrics.Motion.fadeQuick.animation,
                value: isRevealed
            )
            .accessibilityLabel(Text(Self.label(for: timestamp)))
        }
    }

    // MARK: - Formatting

    /// `"Jul 1, 3:45 PM"`. Hardcoded English by design — see the header.
    public static func label(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// One shared formatter. `DateFormatter` construction is expensive enough
    /// that building one per row would show up in a streaming transcript, and
    /// it is never mutated after construction.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()
}

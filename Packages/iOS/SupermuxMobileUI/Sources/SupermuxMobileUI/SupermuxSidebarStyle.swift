import SwiftUI

/// Shared row geometry for the phone's Projects sidebar.
///
/// The pre-redesign row stacked a 40pt gradient avatar, a `.headline` title, a
/// derived "1 open · 2 worktrees" subtitle, an `info.circle` accessory and a
/// disclosure chevron — five competing elements on a ~60pt rhythm, which made
/// ten projects scroll like fifty and read as a settings screen rather than a
/// sidebar.
///
/// The Mac sidebar this section mirrors carries a 20pt avatar, a 12pt name and
/// nothing else. These constants take the Mac's PROPORTIONS — not its absolute
/// sizes — and rebuild them at the phone's scale.
///
/// Matching the Mac's absolute sizes was the first version's mistake: a 26pt
/// avatar under a `.subheadline` name is correct for a 13" sidebar and reads as
/// undersized on a phone, where it sits directly under a list whose own rows
/// title in `.headline`. The section looked like a shrunken inset rather than a
/// peer of the content below it. So the type here is one step up — the project
/// name matches the shell workspace row's `.headline` exactly — and the avatar
/// and row heights follow it.
///
/// The sizes here are the values at the DEFAULT content size. Type in this
/// section scales with Dynamic Type (`.font(.system(.headline, …))` and
/// friends), so the avatar and row heights have to scale with it or a large
/// accessibility size would push text out of a fixed-height row. Views read
/// them through ``SupermuxScaledRowMetrics``, which applies the scaling; the
/// raw constants stay available for the places that must not scale (the
/// hosting table's own insets).
/// lint:allow namespace-enum — layout-constant table shared by the section, the project row, and its nested rows; stateless, nothing to instantiate.
enum SupermuxProjectRowMetrics {
    /// Project avatar edge length. Sized against the `.headline` name beside
    /// it, the way the Mac's 20pt chip is sized against its 12pt name.
    static let avatarSize: CGFloat = 30
    /// Gap between the avatar column and the text column.
    static let avatarTextGap: CGFloat = 11
    /// Row inset from the section's leading/trailing edges.
    static let rowHorizontalPadding: CGFloat = 10
    /// Touch floor for a tappable row — comfortably above the 44pt minimum,
    /// matching the rhythm of the workspace rows below the section.
    static let minimumRowHeight: CGFloat = 48
    /// Touch floor for a single-line nested row (worktrees): visually lighter
    /// than a two-line workspace row, still comfortably tappable.
    static let compactRowHeight: CGFloat = 44
    /// Vertical gap between sibling rows.
    static let rowSpacing: CGFloat = 1
    /// Corner radius of a row's pressed plate.
    static let rowCornerRadius: CGFloat = 10
    /// Where a nested row's CONTENT starts, measured from the row's own
    /// leading inset: exactly the project title's leading edge.
    ///
    /// Mirrors the Mac, where a nested row's icon slot is the project row's
    /// avatar slot — empty for a workspace, a branch glyph for a worktree — so
    /// nested titles line up under the project title instead of drifting off
    /// behind an indent.
    static var nestedIndent: CGFloat { avatarSize + avatarTextGap }
}

/// ``SupermuxProjectRowMetrics`` scaled for the current Dynamic Type setting.
///
/// A property wrapper bundle rather than free constants, because `@ScaledMetric`
/// only works as a stored property on a `View`. Every sidebar row holds one of
/// these instead of reading the raw constants, so the avatar, the row heights,
/// and the nested indent all grow together with the text they surround.
///
/// The hosting table re-measures on a content-size change already — its height
/// cache key carries `preferredContentSizeCategory` — so scaled rows land at
/// their real height instead of a stale cached one.
///
/// **The `DynamicProperty` conformance is load-bearing, not decoration.**
/// SwiftUI updates a view's `@ScaledMetric` storage by reflecting over the
/// view's stored properties and descending into anything that conforms to
/// `DynamicProperty` (`ScaledMetric` itself is one — SwiftUICore). A plain
/// struct is NOT descended into, so without this conformance every wrapper in
/// here would keep returning its unscaled base value forever and the whole
/// type would silently do nothing.
struct SupermuxScaledRowMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .headline) private var avatar = SupermuxProjectRowMetrics.avatarSize
    @ScaledMetric(relativeTo: .headline) private var gap = SupermuxProjectRowMetrics.avatarTextGap
    @ScaledMetric(relativeTo: .headline) private var minimumHeight = SupermuxProjectRowMetrics.minimumRowHeight
    @ScaledMetric(relativeTo: .subheadline) private var compactHeight = SupermuxProjectRowMetrics.compactRowHeight

    /// Project avatar edge length at the current type size.
    var avatarSize: CGFloat { avatar }
    /// Gap between the avatar column and the text column.
    var avatarTextGap: CGFloat { gap }
    /// Touch floor for a tappable row.
    var minimumRowHeight: CGFloat { minimumHeight }
    /// Touch floor for a single-line nested row.
    var compactRowHeight: CGFloat { compactHeight }
    /// Where a nested row's content starts — the project title's leading edge.
    var nestedIndent: CGFloat { avatar + gap }
}

/// The section's motion vocabulary.
///
/// One spring drives everything a disclosure touches at once — the pill's
/// chevron, the nested rows' entrance, and the hosting table row's height —
/// so expanding a project reads as a single movement rather than three
/// independently-timed ones. Every caller pairs these with an
/// `accessibilityReduceMotion` check.
/// lint:allow namespace-enum — animation-constant table shared across the section's views; stateless, nothing to instantiate.
enum SupermuxProjectMotion {
    /// Project expand/collapse. The tiny bounce is what separates "the rows
    /// appeared" from "the rows settled".
    static let disclosure = Animation.snappy(duration: 0.3, extraBounce: 0.05)
    /// Rows appearing or leaving inside a disclosure.
    static let nestedContent = Animation.snappy(duration: 0.24)
    /// Press-highlight fade. Fast enough to feel like a response, slow enough
    /// not to strobe during a scroll that grazes a row.
    static let press = Animation.easeOut(duration: 0.12)

    /// The nested rows' entrance: they slide down out of the project row and
    /// fade, and leave by fading only — a reversed slide would read as the
    /// rows escaping upward past their own parent.
    ///
    /// Computed, not stored: `AnyTransition` is not `Sendable`, so a `static
    /// let` would be a shared-mutable-global error under Swift 6.
    static var nestedTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -8)),
            removal: .opacity
        )
    }
}

/// The press treatment every sidebar row shares: a rounded plate that fades in
/// under the finger and out again.
///
/// `.buttonStyle(.plain)` gives no press feedback at all, which is why the
/// pre-redesign rows felt inert — a tap produced nothing until the navigation
/// push landed. This is the same affordance UIKit gives a table row, drawn to
/// the row's own corner radius so it never squares off against its neighbors.
struct SupermuxSidebarRowButtonStyle: ButtonStyle {
    /// Corner radius of the pressed plate.
    var cornerRadius: CGFloat = SupermuxProjectRowMetrics.rowCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        Plate(configuration: configuration, cornerRadius: cornerRadius)
    }

    /// Nested so the style can read `accessibilityReduceMotion` — a
    /// `ButtonStyle` body is not itself a `View` and has no environment.
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0))
                )
                .animation(
                    reduceMotion ? nil : SupermuxProjectMotion.press,
                    value: configuration.isPressed
                )
        }
    }
}

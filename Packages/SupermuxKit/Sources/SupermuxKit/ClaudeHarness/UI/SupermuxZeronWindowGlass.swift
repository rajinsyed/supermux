//
//  SupermuxZeronWindowGlass.swift
//  SupermuxKit
//
//  The macOS shell backdrop: `NSVisualEffectView` behind-window blur with the
//  `glass()` tint on top. Plan §2.1, risk R3.
//
//  gpui's setup at the pinned rev is `UnderWindowBackground` / `behindWindow` /
//  `active`, which `NSVisualEffectView.Material.underWindowBackground` matches
//  exactly. On top of it goes `theme.glass()` — `#080808 @ 0.80` dark,
//  `#FAFAFA @ 0.80` light — and that composite is what produces the `#060606`
//  transcript backdrop both zeron screenshots measure.
//
//  ── Why the shared package is not enough ──
//
//  `SupermuxZeronGlass` already vends the material + tint. This adds the two
//  macOS-window-level concerns the shared package must not know about:
//
//  1. **Full-height under the titlebar.** The transcript viewport spans the whole
//     window and scrolls UNDER the chrome — that is the premise of row 0's 62 pt
//     top gap and of the fade's 38 pt `insetTop`. If the backdrop stopped at the
//     content area, the fade's clear zone would be painting over the wrong band.
//  2. **Never going flat on resign-key.** `.active` rather than
//     `.followsWindowActiveState`: zeron's glass does not change tone when the
//     window loses focus, and a transcript whose ground shifts on focus change
//     reads as a rendering bug.
//

internal import AppKit
public import SupermuxZeronUI
public import SwiftUI

/// The macOS chat-pane shell backdrop.
///
/// Mount it as the ROOT of the harness view, with the transcript, status strip
/// and composer composited over it:
///
/// ```swift
/// SupermuxZeronWindowGlass(theme: theme) {
///     transcriptStack
/// }
/// ```
public struct SupermuxZeronWindowGlass<Content: View>: View {
    private let theme: SupermuxZeronTheme
    private let content: Content

    public init(theme: SupermuxZeronTheme, @ViewBuilder content: () -> Content) {
        self.theme = theme
        self.content = content()
    }

    public var body: some View {
        ZStack {
            SupermuxZeronVisualEffect(material: .underWindowBackground)
                .ignoresSafeArea()
            theme.glass()
                .ignoresSafeArea()
            content
        }
    }
}

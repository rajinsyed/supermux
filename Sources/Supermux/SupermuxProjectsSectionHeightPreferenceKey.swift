import SwiftUI

/// Reports the measured height of ``SupermuxProjectsMount`` up the view tree to
/// the cmux sidebar's scroll area, so the empty drop/tap area below the
/// workspace rows can subtract it.
///
/// cmux sizes the sidebar scroll content to *exactly* fill the viewport when
/// everything fits: the empty area below the last workspace row is given a
/// finite remainder (`SidebarWorkspaceScrollLayout.emptyAreaHeight`) rather than
/// `maxHeight: .infinity`, which is what keeps the document from overflowing and
/// showing a phantom scroller / scrollable empty space when content fits
/// (https://github.com/manaflow-ai/cmux/issues/3241). That fit assumes the
/// workspace rows are the *only* content.
///
/// Supermux inserts the Projects section at the top of the same scroll content
/// (the `sidebar-projects-section` touchpoint), so its height must be folded
/// into the remainder. Otherwise the document overflows the viewport by exactly
/// the Projects-section height and that surplus becomes scrollable empty space.
struct SupermuxProjectsSectionHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Publishes this view's laid-out height through
    /// ``SupermuxProjectsSectionHeightPreferenceKey`` so an ancestor (the cmux
    /// sidebar scroll area) can read it with `.onPreferenceChange`.
    func supermuxReportsProjectsSectionHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SupermuxProjectsSectionHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
    }
}

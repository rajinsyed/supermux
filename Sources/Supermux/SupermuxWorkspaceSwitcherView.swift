import AppKit
import SupermuxKit
import SwiftUI

/// The root SwiftUI view of the workspace switcher overlay: a centered,
/// frosted-glass panel whose width is computed to exactly hug its row of compact
/// workspace thumbnails (scrolling only when there are too many to fit), each card
/// showing its workspace name and branch directly beneath its preview — over a
/// dimmed click-to-cancel backdrop.
///
/// It observes ``SupermuxWorkspaceSwitcherViewState`` (a dedicated, transient
/// store) for the live selection/preview updates the controller pushes, and
/// renders each workspace as a value-driven ``SupermuxWorkspaceSwitcherCard``.
struct SupermuxWorkspaceSwitcherView: View {
    let state: SupermuxWorkspaceSwitcherViewState

    /// Resolves project avatar logos (custom/auto-detected) above the card row, so
    /// only immutable `NSImage` values flow down to cards — mirroring the sidebar's
    /// `SupermuxProjectsSectionView` pattern and honoring the snapshot-boundary rule.
    @State private var iconStore = SupermuxProjectIconStore()

    /// Exact width of the card row including its inset padding.
    private var contentWidth: CGFloat {
        let count = CGFloat(state.items.count)
        guard count > 0 else { return 0 }
        let cards = count * SupermuxWorkspaceSwitcherStyle.previewSize.width
        let gaps = max(0, count - 1) * SupermuxWorkspaceSwitcherStyle.cardSpacing
        return cards + gaps + 2 * SupermuxWorkspaceSwitcherStyle.panelPadding
    }

    /// Panel hugs its cards, capped so a long row scrolls instead of overflowing.
    private var panelWidth: CGFloat {
        min(contentWidth, SupermuxWorkspaceSwitcherStyle.maxStripWidth)
    }

    private var needsScroll: Bool {
        contentWidth > SupermuxWorkspaceSwitcherStyle.maxStripWidth
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { state.onCancel() }

            panel
                .padding(.horizontal, 24)
        }
        .transition(.opacity)
        .task(id: shownProjectsToken) {
            await iconStore.refresh(projects: shownProjects)
        }
    }

    /// The distinct owning projects of the shown workspaces, so the icon store only
    /// probes what the strip actually displays (deduped by project id).
    private var shownProjects: [SupermuxProject] {
        var seen = Set<UUID>()
        var result: [SupermuxProject] = []
        for item in state.items {
            if let project = item.project, seen.insert(project.id).inserted {
                result.append(project)
            }
        }
        return result
    }

    /// Identity token (id + root + custom icon path) so the refresh re-runs when a
    /// shown project's icon source changes, not only when the project set changes.
    private var shownProjectsToken: [String] {
        shownProjects.map { "\($0.id.uuidString)|\($0.rootPath)|\($0.customIconPath ?? "")" }
    }

    private var panel: some View {
        strip
            .padding(.vertical, SupermuxWorkspaceSwitcherStyle.panelPadding)
            .frame(width: panelWidth)
            .background(
                RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.panelCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .background(
                        SupermuxVisualEffectBackground(material: .hudWindow)
                            .clipShape(RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.panelCornerRadius, style: .continuous))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: SupermuxWorkspaceSwitcherStyle.panelCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 24, y: 12)
    }

    @ViewBuilder
    private var strip: some View {
        if needsScroll {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    cardRow
                        .padding(.vertical, SupermuxWorkspaceSwitcherStyle.cardShadowBleed)
                }
                .onChange(of: state.selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(state.selectedIndex, anchor: .center) }
            }
            .frame(height: SupermuxWorkspaceSwitcherStyle.cardHeight + 2 * SupermuxWorkspaceSwitcherStyle.cardShadowBleed)
        } else {
            cardRow
                .frame(height: SupermuxWorkspaceSwitcherStyle.cardHeight)
        }
    }

    private var cardRow: some View {
        HStack(spacing: SupermuxWorkspaceSwitcherStyle.cardSpacing) {
            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                SupermuxWorkspaceSwitcherCard(
                    item: item,
                    isSelected: index == state.selectedIndex,
                    projectIcon: item.projectId.flatMap { iconStore.image(for: $0) },
                    onTap: { state.onSelectIndex(index) }
                )
                .id(index)
            }
        }
        .padding(.horizontal, SupermuxWorkspaceSwitcherStyle.panelPadding)
        // A transparent AppKit overlay tracks real pointer movement and reports the
        // card under the cursor — clicks pass straight through to the buttons.
        .overlay(
            SupermuxPointerTrackingStrip(count: state.items.count) { index in
                state.onPointerOverCard(index)
            }
        )
    }
}

/// A transparent overlay over the card row that reports which card the pointer
/// moves over, via an AppKit mouse-moved tracking area. The card index is derived
/// from the pointer's x-position in the row's own (content-space) coordinates — so
/// it stays correct while the row scrolls — and is driven by the same event that
/// proves real movement, with no dependence on SwiftUI `.onHover` ordering. The
/// view never participates in hit-testing, so clicks reach the cards beneath it.
private struct SupermuxPointerTrackingStrip: NSViewRepresentable {
    let count: Int
    let onPointerOverCard: (Int) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onPointerOverCard = onPointerOverCard
        view.count = count
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onPointerOverCard = onPointerOverCard
        nsView.count = count
    }

    final class TrackingView: NSView {
        var onPointerOverCard: ((Int) -> Void)?
        var count = 0
        private var movementTrackingArea: NSTrackingArea?
        /// Last cursor position we acted on, used to ignore any zero-delta
        /// `mouseMoved` (so only genuine cursor movement can move the selection,
        /// regardless of macOS-version event quirks).
        private var lastLocationInWindow: NSPoint?

        // Observe movement only — let clicks fall through to the SwiftUI buttons.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Seed from the current cursor so the first real move is a true delta.
            lastLocationInWindow = window?.mouseLocationOutsideOfEventStream
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let movementTrackingArea {
                removeTrackingArea(movementTrackingArea)
                self.movementTrackingArea = nil
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            movementTrackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let location = event.locationInWindow
            guard location != lastLocationInWindow else { return }
            lastLocationInWindow = location
            let x = convert(location, from: nil).x
            if let index = cardIndex(atX: x) {
                onPointerOverCard?(index)
            }
        }

        /// Maps an x-coordinate (in this view's space, whose origin sits at the
        /// row's leading edge including its inset) to a card index, or `nil` when
        /// the pointer is in the inset or a gap between cards.
        private func cardIndex(atX x: CGFloat) -> Int? {
            guard count > 0 else { return nil }
            let cardWidth = SupermuxWorkspaceSwitcherStyle.previewSize.width
            let slot = cardWidth + SupermuxWorkspaceSwitcherStyle.cardSpacing
            let relative = x - SupermuxWorkspaceSwitcherStyle.panelPadding
            guard relative >= 0 else { return nil }
            let index = Int(relative / slot)
            guard index < count else { return nil }
            let offsetInSlot = relative - CGFloat(index) * slot
            guard offsetInSlot <= cardWidth else { return nil } // in the gap
            return index
        }
    }
}

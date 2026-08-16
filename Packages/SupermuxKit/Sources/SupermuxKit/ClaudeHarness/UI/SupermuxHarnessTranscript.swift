//
//  SupermuxHarnessTranscript.swift
//  SupermuxKit
//
//  The macOS transcript: the zeron scroll host + a `LazyVStack` of row boxes,
//  the edge fade, the working trailer, and the jump pill.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  WHAT THIS FILE REPLACED, AND WHY
//  ═══════════════════════════════════════════════════════════════════════════
//
//  The previous implementation was a SwiftUI `ScrollView` with a macOS-15
//  `defaultScrollAnchor` branch and a macOS-14 `ScrollViewReader` +
//  `PreferenceKey` fallback. Both are gone, along with the fallback's whole
//  "am I at the bottom?" preference plumbing. They cannot express zeron's
//  motion model for one reason, stated in plan R1:
//
//      SwiftUI's scroll callbacks fire for PROGRAMMATIC scrolls as well as user
//      input, and the stick spring scrolls programmatically every frame — so a
//      pin-break test wired to `onScrollGeometryChange` breaks its own pin on
//      frame one.
//
//  `SupermuxZeronScrollHost` supplies the missing primitive (a user-input-only
//  callback); `SupermuxZeronSpringDriver` supplies the post-layout pump. See
//  those files' headers for the mechanism.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  LAYOUT
//  ═══════════════════════════════════════════════════════════════════════════
//
//      ZStack
//        └ scroll host                  ← .supermuxZeronEdgeFade(...)
//        │   └ LazyVStack(spacing: 0)
//        │       └ SupermuxZeronRowEquatable per row
//        └ jump pill                    ← OUTSIDE the fade, deliberately
//
//  The pill sits outside the fade because in zeron it is a LATER SIBLING of the
//  faded outlet: an overlay inside the fade's scope would be tinted by it
//  (`shell.rs:4961-4964`). It is positioned `stackHeight - 14` above the
//  region's bottom, horizontally centred with a 10 pt right bias.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  THE LIST-BOUNDARY RULE (cmux #2586)
//  ═══════════════════════════════════════════════════════════════════════════
//
//  Nothing below the `LazyVStack` holds an observable store. The hover store,
//  the spring driver and the scroll controller all live HERE, above the
//  boundary; each row receives an already-resolved `Bool`, a `CGFloat` gap, and
//  a pre-built trailer view. `hoverEntry.isRevealed(entryID:)` is called from
//  `body`, and it is a pure read — the writes happen in `.onHover`, an event
//  handler.
//

internal import AppKit
public import SupermuxClaudeHarness
public import SupermuxZeronUI
public import SwiftUI

/// The scrolling transcript.
public struct SupermuxHarnessTranscript: View {
    private let rows: [SupermuxHarnessRow]
    /// Identifies the session. A change resets the scroll host and re-lands at
    /// the bottom instantly (spec 02 §8.4).
    private let sessionKey: String
    private let theme: SupermuxZeronTheme
    /// The measured composer + status-strip height the transcript scrolls under.
    /// Feeds the last row's bottom pad AND the fade's bottom band, which is why
    /// one value drives both and they cannot drift.
    private let bottomClearance: CGFloat
    /// The own-send reservation. Zero unless a locally-sent turn is anchored.
    private let runway: CGFloat
    /// Whether a turn is live; mounts the working trailer on the last row.
    private let isWorking: Bool
    /// The send→turn bridge: `"Sending…"` with no timer.
    private let isSendingBridge: Bool
    /// Seconds since the turn started.
    private let elapsedSeconds: Int
    /// `fnv1a(sessionKey)` — the deterministic flavour-word rotation seed.
    private let flavourSeed: UInt64

    @State private var controller = SupermuxZeronScrollController()
    @State private var hoverEntry = SupermuxZeronHoverEntry()
    /// The tool-group fold state, owned HERE — above the lazy boundary.
    ///
    /// Keeping it out of the row model is what makes a fold flip repaint the
    /// row without invalidating its identity, which is the fix for the tween
    /// replaying on every scroll-back (plan R5).
    @State private var foldStore = SupermuxZeronFoldStore()
    @State private var driver: SupermuxZeronSpringDriver?
    @State private var showsJumpPill = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        rows: [SupermuxHarnessRow],
        sessionKey: String,
        theme: SupermuxZeronTheme,
        bottomClearance: CGFloat,
        runway: CGFloat = 0,
        isWorking: Bool = false,
        isSendingBridge: Bool = false,
        elapsedSeconds: Int = 0,
        flavourSeed: UInt64 = 0
    ) {
        self.rows = rows
        self.sessionKey = sessionKey
        self.theme = theme
        self.bottomClearance = bottomClearance
        self.runway = runway
        self.isWorking = isWorking
        self.isSendingBridge = isSendingBridge
        self.elapsedSeconds = elapsedSeconds
        self.flavourSeed = flavourSeed
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            SupermuxZeronScrollHost(controller: controller) {
                content
            }
            .supermuxZeronEdgeFade(.macOS(stackHeight: bottomClearance))

            // OUTSIDE the fade — see the header.
            if showsJumpPill {
                SupermuxZeronJumpPill(theme: theme) { driver?.engagePin() }
                    .transition(SupermuxZeronJumpPill.transition)
                    // `bottom = stackHeight - 14` and a 10 pt right bias, so the
                    // pill's centre lands on `columnCentre - 5`.
                    .padding(.bottom, max(bottomClearance - 14, 0))
                    .padding(.trailing, 10)
            }
        }
        .background(SupermuxZeronTranscriptLinkBridge(driver: driver))
        .onAppear { installDriver() }
        // The display link holds a STRONG reference to the driver, so a driver
        // with a live link never deallocates — the loop must be stopped here,
        // not left to `deinit`. Without this, closing a panel mid-stream leaves
        // a 60 Hz tick running against a dead scroll view for the process's life.
        .onDisappear {
            driver?.teardown()
            driver = nil
        }
        .onChange(of: sessionKey) { _, _ in
            hoverEntry.clear()
            // The old row ids no longer exist, so their folds are dead keys.
            foldStore.reset()
            driver?.attach()
        }
        // A row-set change is a document commit: wake the spring so the growth
        // glides instead of hard-snapping on the next layout.
        .onChange(of: rows.count) { _, _ in driver?.wake() }
        .onChange(of: rows.last?.version) { _, _ in driver?.wake() }
        .onChange(of: reduceMotion) { _, newValue in driver?.reduceMotion = newValue }
        .animation(
            reduceMotion ? nil : SupermuxZeronJumpPill.presenceAnimation,
            value: showsJumpPill
        )
    }

    // MARK: - Content

    private var content: some View {
        // Built ONCE per render, above the loop: the rows capture only these
        // closures, never the store (the `IndexSectionActions` pattern).
        let foldActions = foldStore.actions
        // `spacing: 0`: the vertical rhythm is PADDING on each row, never
        // spacing between siblings, so a splice cannot change the gap above a
        // neighbour (spec 02 §2.2).
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                SupermuxZeronRowEquatable(
                    row: row,
                    topGap: SupermuxZeronRowGap.topGap(
                        index: index,
                        previous: index > 0 ? rows[index - 1] : nil,
                        row: row
                    ),
                    bottomPad: index == rows.count - 1 ? lastRowBottomPad : 0,
                    isTimestampRevealed: hoverEntry.isRevealed(entryID: row.entryID),
                    theme: theme,
                    trailer: index == rows.count - 1 ? trailer : nil,
                    trailerVersion: trailerVersion,
                    folds: foldSnapshot(for: row),
                    foldActions: foldActions
                )
                .equatable()
                .onHover { isInside in
                    if isInside {
                        hoverEntry.enter(rowID: row.id, entryID: row.entryID)
                    } else {
                        hoverEntry.leave(rowID: row.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A pure READ of the fold store. Non-group rows get the settled default,
    /// so a prose row's fingerprint never churns on a fold elsewhere.
    private func foldSnapshot(for row: SupermuxHarnessRow) -> SupermuxZeronToolGroupFolds {
        guard case .toolGroup(let group) = row.kind else {
            return SupermuxZeronToolGroupFolds()
        }
        return foldStore.folds(for: group)
    }

    /// `bottomClearance + 24 + 8 + runway`.
    ///
    /// The `+24` clears the fade band and the `+8` is literal breathing room, so
    /// the row's LOWEST content — the timestamp lane — never renders inside the
    /// fade when the transcript is pinned (spec 02 §2.4 / §5.5).
    private var lastRowBottomPad: CGFloat {
        SupermuxZeronMetrics.Transcript.lastRowBottomPad(
            bottomClearance: bottomClearance,
            runway: runway
        )
    }

    private var trailer: AnyView? {
        guard isWorking else { return nil }
        return AnyView(
            SupermuxZeronWorkingTrailer(
                flavourSeed: flavourSeed,
                elapsedSeconds: elapsedSeconds,
                isSending: isSendingBridge,
                theme: theme
            )
        )
    }

    /// Changes whenever the trailer's rendered content changes, so the last
    /// row's `EquatableView` gate lets a tick through. `AnyView` cannot be
    /// compared, so without this the elapsed timer would freeze.
    private var trailerVersion: UInt64 {
        guard isWorking else { return 0 }
        return UInt64(elapsedSeconds) &* 2 &+ (isSendingBridge ? 1 : 0)
    }

    private func installDriver() {
        guard driver == nil else { return }
        let driver = SupermuxZeronSpringDriver(controller: controller)
        driver.reduceMotion = reduceMotion
        driver.onJumpPillVisibilityChange = { shows in showsJumpPill = shows }
        self.driver = driver
    }
}

// MARK: - Display-link bridge

/// Hands the spring driver an `NSView` to vend its `CADisplayLink` from.
///
/// macOS's `CADisplayLink` must be created by an `NSView`, `NSWindow` or
/// `NSScreen`; SwiftUI exposes none of those. A zero-size representable in the
/// background is the smallest way to get one that is guaranteed to be in the
/// same window (and therefore on the same display) as the transcript.
private struct SupermuxZeronTranscriptLinkBridge: NSViewRepresentable {
    let driver: SupermuxZeronSpringDriver?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = false
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let driver, view.window != nil else { return }
        driver.bind(linkSource: view)
    }
}

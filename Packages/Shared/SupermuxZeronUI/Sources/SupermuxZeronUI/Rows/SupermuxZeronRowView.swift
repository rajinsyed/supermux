//
//  SupermuxZeronRowView.swift
//  SupermuxZeronUI
//
//  Dispatches one `SupermuxHarnessRow` to its renderer inside the shared row box.
//
//  ── The list-boundary contract (cmux #2586) ──
//
//  This view and everything under it take IMMUTABLE VALUES AND CLOSURES ONLY.
//  No observable store crosses the `LazyVStack` boundary, and no function called
//  from `body` writes state. Violating either reintroduces the 100 % CPU spin
//  loop. The reference pattern is `IndexSectionActions` / `SectionGapActions` in
//  `Sources/SessionIndexView.swift`.
//
//  ── Row identity and re-render cost ──
//
//  Rows compare on `(id, version)`. The host wraps each row in
//  ``SupermuxZeronRowEquatable`` so SwiftUI skips a body evaluation for any row
//  whose fingerprint did not change — that is what keeps a streaming transcript
//  from rebuilding every visible row per delta, which would visibly fight the
//  stick spring (spec 07 §7.4).
//
//  ── Which renderer each kind gets ──
//
//  | Kind             | Renderer                     | Timestamp lane | Owner |
//  |------------------|------------------------------|----------------|-------|
//  | `userPrompt`     | `SupermuxZeronUserBubble`    | user (16, trailing) | W1 |
//  | `assistantProse` | `SupermuxZeronAssistantRow`  | assistant (20, leading) | W3 |
//  | `thinking`       | `SupermuxZeronThinkingRow`   | assistant | W3 |
//  | `toolGroup`      | `SupermuxZeronToolGroupView` | assistant | W2 |
//  | `result`         | `SupermuxZeronResultMetaRow` | assistant | W1 |
//  | `notice`         | `SupermuxZeronNoticeRow`     | assistant | W1 |
//
//  Only `userPrompt` is a "user row" for lane purposes: it alone gets the 16 pt
//  trailing lane; everything else gets the 20 pt leading lane with its 4 pt top
//  pad (spec 02 §5.2).
//
//  ── What the host must thread through ──
//
//  `folds` / `foldActions` come from a `SupermuxZeronFoldStore` the HOST owns —
//  never the row. That is what keeps a fold from invalidating a row's identity
//  (which would replay the tween on every scroll-back; plan R5). Passing the
//  defaults renders every group settled and inert, which is correct for a
//  preview but not for the live transcript.
//

public import SupermuxClaudeHarness
public import SwiftUI

/// One transcript row, wrapped in the universal row box.
public struct SupermuxZeronRowView: View {
    private let row: SupermuxHarnessRow
    private let topGap: CGFloat
    private let bottomPad: CGFloat
    private let gutter: CGFloat
    private let isTimestampRevealed: Bool
    private let theme: SupermuxZeronTheme
    private let trailer: AnyView?
    /// This group row's fold snapshot, read out of the host's store.
    private let folds: SupermuxZeronToolGroupFolds
    /// The host's fold closures. Closures only — never the store itself.
    private let foldActions: SupermuxZeronFoldActions
    private let onOpenURL: ((URL) -> Void)?

    public init(
        row: SupermuxHarnessRow,
        topGap: CGFloat,
        bottomPad: CGFloat = 0,
        gutter: CGFloat = SupermuxZeronMetrics.Transcript.gutter,
        isTimestampRevealed: Bool = false,
        theme: SupermuxZeronTheme,
        trailer: AnyView? = nil,
        folds: SupermuxZeronToolGroupFolds = SupermuxZeronToolGroupFolds(),
        foldActions: SupermuxZeronFoldActions = .inert,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.row = row
        self.topGap = topGap
        self.bottomPad = bottomPad
        self.gutter = gutter
        self.isTimestampRevealed = isTimestampRevealed
        self.theme = theme
        self.trailer = trailer
        self.folds = folds
        self.foldActions = foldActions
        self.onOpenURL = onOpenURL
    }

    /// Only a user prompt takes the trailing 16 pt lane.
    private var isUserRow: Bool {
        if case .userPrompt = row.kind { return true }
        return false
    }

    public var body: some View {
        SupermuxZeronRowBox(
            topGap: topGap,
            bottomPad: bottomPad,
            gutter: gutter,
            timestamp: row.timestamp,
            isUserRow: isUserRow,
            isTimestampRevealed: isTimestampRevealed,
            theme: theme,
            trailer: trailer
        ) {
            inner
        }
    }

    @ViewBuilder
    private var inner: some View {
        switch row.kind {
        case .userPrompt(let text):
            SupermuxZeronUserBubble(text: text, theme: theme)
        case .assistantProse(let text, let isStreaming):
            // Owned by W3. `rowKey` is the row's stable id, which is what keys
            // the streaming veil's per-element state — it must survive the
            // streaming→complete transition unchanged.
            SupermuxZeronAssistantRow(
                text: text,
                isStreaming: isStreaming,
                theme: theme,
                rowKey: row.id,
                onOpenURL: onOpenURL
            )
        case .thinking(let text, let isStreaming):
            // Owned by W3.
            SupermuxZeronThinkingRow(
                text: text,
                isStreaming: isStreaming,
                theme: theme,
                rowKey: row.id,
                onOpenURL: onOpenURL
            )
        case .toolGroup(let group):
            // Owned by W2. The fold snapshot and its closures come from the
            // host's store, ABOVE the lazy boundary.
            SupermuxZeronToolGroupView(
                group: group,
                folds: folds,
                theme: theme,
                actions: foldActions
            )
        case .result(let summary):
            SupermuxZeronResultMetaRow(summary: summary, theme: theme)
        case .notice(let notice):
            SupermuxZeronNoticeRow(notice: notice, theme: theme)
        }
    }
}

// MARK: - Equatable gate

/// A row whose identity for SwiftUI is exactly `(id, version)`.
///
/// Wrapping the row view in `EquatableView` through this reproduces zeron's
/// "only changed rows rebuild" contract: the row model's `version` is a content
/// fingerprint, so an unchanged row keeps it across a streaming delta and its
/// body is never re-evaluated.
///
/// Every other field is part of the comparison too, because a changed gap or a
/// changed reveal state must still repaint — they just change far less often
/// than the row content does.
public struct SupermuxZeronRowEquatable: View, Equatable {
    /// Everything the comparison looks at, in one `Sendable` value.
    ///
    /// Split out so `==` can be `nonisolated`: a `View`-conforming struct is
    /// main-actor isolated by inference, and `Equatable.==` is not, so a
    /// comparison that reads the view's own stored properties crosses isolation
    /// and Swift 6 rejects the conformance.
    public struct Fingerprint: Sendable, Equatable {
        public let rowID: String
        public let version: UInt64
        public let timestamp: Date?
        public let topGap: CGFloat
        public let bottomPad: CGFloat
        public let gutter: CGFloat
        public let isTimestampRevealed: Bool
        public let theme: SupermuxZeronTheme
        public let hasTrailer: Bool
        /// Bumped by the host when the trailer's CONTENT changes (the elapsed
        /// second, the rotated flavour word). `AnyView` cannot be compared, so
        /// without this the row would never notice a trailer update.
        public let trailerVersion: UInt64
        /// A fold flip must repaint the row even though its content fingerprint
        /// did not change — that is the whole point of keeping fold state off
        /// the row model.
        public let folds: SupermuxZeronToolGroupFolds
    }

    private let fingerprint: Fingerprint
    private let row: SupermuxHarnessRow
    private let trailer: AnyView?
    private let foldActions: SupermuxZeronFoldActions
    private let onOpenURL: ((URL) -> Void)?

    public init(
        row: SupermuxHarnessRow,
        topGap: CGFloat,
        bottomPad: CGFloat = 0,
        gutter: CGFloat = SupermuxZeronMetrics.Transcript.gutter,
        isTimestampRevealed: Bool = false,
        theme: SupermuxZeronTheme,
        trailer: AnyView? = nil,
        trailerVersion: UInt64 = 0,
        folds: SupermuxZeronToolGroupFolds = SupermuxZeronToolGroupFolds(),
        foldActions: SupermuxZeronFoldActions = .inert,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.row = row
        self.trailer = trailer
        self.foldActions = foldActions
        self.onOpenURL = onOpenURL
        self.fingerprint = Fingerprint(
            rowID: row.id,
            version: row.version,
            timestamp: row.timestamp,
            topGap: topGap,
            bottomPad: bottomPad,
            gutter: gutter,
            isTimestampRevealed: isTimestampRevealed,
            theme: theme,
            hasTrailer: trailer != nil,
            trailerVersion: trailerVersion,
            folds: folds
        )
    }

    nonisolated public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }

    public var body: some View {
        SupermuxZeronRowView(
            row: row,
            topGap: fingerprint.topGap,
            bottomPad: fingerprint.bottomPad,
            gutter: fingerprint.gutter,
            isTimestampRevealed: fingerprint.isTimestampRevealed,
            theme: fingerprint.theme,
            trailer: trailer,
            folds: fingerprint.folds,
            foldActions: foldActions,
            onOpenURL: onOpenURL
        )
    }
}

//
//  SupermuxZeronPickerCard.swift
//  SupermuxZeronUI
//
//  The 360 × 346 flush picker card. Spec 08 §1, plan §0.3 C12.
//
//  ── READ THIS BEFORE COMPARING AGAINST THE SCREENSHOT ──
//
//  `docs/media/harness-settings/s1-picker-highlight.png` shows a two-column
//  "AGENTS | MODELS" card with section headers and a footer hint bar.
//  **That design does not exist in the source at the ported revision.** A
//  repo-wide grep for the literal "AGENTS" returns zero hits;
//  `render_harness_model_popover` renders no footer, and its rail is icons-only
//  at 44 pt with no labels. The screenshots are stale artifacts of an earlier
//  design and the plan resolved the conflict in favor of the source (§0.3 C12).
//  This file builds the source.
//
//  ── The shape ──
//
//      ┌ card 360×346, r12, border 1 hairline(0.10), blur 44, glassOverlay ─┐
//      │ ┌ rail 44 ────────┬ pane (fills, ink(0.02), border-l hairline .07) │
//      │ │ p4, gap 4       │ ┌ search row h46, px10, border-b hairline .08 ┐│
//      │ │ ★ tab 36×36 r8  │ │  [magnifer 14 muted@.7]  gap 8  [input 13] ││
//      │ │ ── divider ──   │ └─────────────────────────────────────────────┘│
//      │ │ ⬤ tab 36×36     │ ┌ list: py6, px6, gap 2, rows are DIRECT kids ┐│
//      │ │                 │ │  row px8 py6 r8 gap10                       ││
//      │ │                 │ │   [label 12.5 med / icon 11 + sub 11] ⌘1 ★  ││
//      │ └─────────────────┴──────────────────────────────────────────────┘ │
//      └────────────────────────────────────────────────────────────────────┘
//
//  The rail divider and the search row's bottom hairline are ONE CONTINUOUS
//  LINE across the card, and the arithmetic that makes that true is load-bearing
//  (`pickers.rs:2762`): 4 pad + 36 tab + 4 gap + 1 divider margin = the hairline
//  at y 45–46, which is exactly where the 46 pt search row's inside-drawn bottom
//  border lands. Change any of those five numbers and the line breaks.
//
//  ── ONE MOVING HIGHLIGHT ──
//
//  Hover does not paint. `.onHover` writes into the shared `activeIndex` and the
//  fill is derived from that, so hover and the arrow cursor can never wear two
//  washes at once. This was a twice-reported user bug in zeron
//  (`pickers.rs:1483–1486`) — never add a local `isHovered` fill to a row.
//  The invariant lives in `SupermuxZeronPickerModel` and is unit-tested there.
//

public import SwiftUI

// MARK: - Card

/// zeron's HarnessModel picker: an icons-only rail beside a search + list pane.
///
/// The card is a fixed 360 × 346 in **every** state — loading, error and empty
/// bodies are rendered *inside* it, never by resizing it (`pickers.rs:2675`,
/// `:2689`, `:3025`).
///
/// Platform shells own presentation: macOS anchors it in a `MENU_IN` popover
/// (`SupermuxHarnessRuntimePopover`), iOS presents it in a sheet at
/// `.presentationDetents([.height(346)])`. The card itself is identical.
public struct SupermuxZeronPickerCard: View {
    private let theme: SupermuxZeronTheme
    private let rows: [SupermuxZeronPickerRow]
    private let selectedID: String?
    private let isLocked: Bool
    private let onSelect: (SupermuxZeronPickerRow) -> Void
    private let onToggleFavorite: ((SupermuxZeronPickerRow) -> Void)?
    private let onDismiss: (() -> Void)?
    private let footer: AnyView?

    @Binding private var state: SupermuxZeronPickerState

    /// zeron focuses the SEARCH INPUT on open, not the frame — the input sits
    /// inside the frame, so the frame's key handler still sees arrows and Enter
    /// (`pickers.rs:837–843`). Without this the whole keyboard model is dead:
    /// `.onKeyPress` only fires for the focused view or an ancestor of it.
    @FocusState private var searchFocused: Bool

    /// The row the KEYBOARD asked to reveal.
    ///
    /// Deliberately not `state.activeIndex`: hover writes into that too, and
    /// zeron's `on_hover` does **not** scroll (`pickers.rs:2879–2884`) — only
    /// `MenuKey::Up`/`Down` call `scroll_to_item`. Scrolling on hover would
    /// yank the list out from under the pointer and can feed back into itself.
    @State private var keyboardReveal: Int?

    /// A star toggle is in flight; re-home the cursor when the reordered rows
    /// arrive. See the toggle's call site.
    @State private var pendingRehome = false

    /// - Parameters:
    ///   - theme: the appearance-keyed palette.
    ///   - rows: every row, in catalog order. Filtering and star-floating are
    ///     the card's job, not the caller's.
    ///   - selectedID: the chosen row's id, which paints the wash + ring.
    ///   - state: rail, query and cursor. Owned by the shell so a reopen can
    ///     re-anchor the cursor on the selected row.
    ///   - isLocked: a session that has already started locks its harness; the
    ///     rail tab dims to 0.35 and takes no hover or clicks.
    ///   - onSelect: fired on click, Enter, or a ⌘N accelerator.
    ///   - onToggleFavorite: `nil` hides the star column entirely rather than
    ///     rendering a dead control.
    ///   - onDismiss: Escape. `animate_close()` in zeron (`pickers.rs:1932`);
    ///     the shell owns the presentation, so it owns the close.
    ///   - footer: an optional hint bar. zeron's picker renders none (§1.9);
    ///     `SupermuxZeronPickerFooter` builds the authentic one if a shell
    ///     wants it.
    public init(
        theme: SupermuxZeronTheme,
        rows: [SupermuxZeronPickerRow],
        selectedID: String?,
        state: Binding<SupermuxZeronPickerState>,
        isLocked: Bool = false,
        onSelect: @escaping (SupermuxZeronPickerRow) -> Void,
        onToggleFavorite: ((SupermuxZeronPickerRow) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        footer: AnyView? = nil
    ) {
        self.theme = theme
        self.rows = rows
        self.selectedID = selectedID
        self._state = state
        self.isLocked = isLocked
        self.onSelect = onSelect
        self.onToggleFavorite = onToggleFavorite
        self.onDismiss = onDismiss
        self.footer = footer
    }

    private typealias M = SupermuxZeronMetrics.Pickers

    /// The rows actually painted. Computed once per `body` and threaded through
    /// every child so the render, the keyboard, and ⌘N provably walk one list.
    private var visible: [SupermuxZeronPickerRow] {
        state.visibleRows(from: rows)
    }

    public var body: some View {
        let visible = visible
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The rail leaves the tree entirely while a search is live —
                // the query spans every harness, so a per-harness rail would
                // lie. The pane widens to the full 360 and drops its left
                // border with it (`pickers.rs:2718`, `:3005`).
                if !state.filter.isSearching {
                    rail
                }
                pane(visible: visible)
            }
            if let footer {
                footer
            }
        }
        .frame(width: M.cardWidth, height: M.cardHeight)
        .background(SupermuxZeronGlassBackdrop(theme: theme, role: .menu))
        .clipShape(RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous)
                .strokeBorder(theme.hairline(0.10), lineWidth: 1)
        )
        .modifier(SupermuxZeronCardShadow())
        .accessibilityElement(children: .contain)
        .onKeyPress(phases: .down) { press in handle(press, visible: visible) }
        // `toggle` focuses the search input for this picker, which is what makes
        // the frame-level key handler above reachable at all. Anchoring the
        // cursor on the SELECTED row is step 4 of the same routine, and it must
        // run AFTER the rail is primed — `open` enforces that order.
        .onAppear {
            state.open(
                rows: rows,
                selectedID: selectedID,
                hasFavorites: rows.contains(where: \.isFavorite),
                isLocked: isLocked
            )
            searchFocused = true
        }
        // The star's re-home, applied once the caller hands back the reordered
        // rows. A state write from `onChange` is a callback, not a `body` write
        // (the cmux #2586 rule).
        .onChange(of: rows) { _, newRows in
            guard pendingRehome else { return }
            pendingRehome = false
            state.rehomeAfterFavoriteToggle(rows: newRows, selectedID: selectedID)
        }
    }

    // MARK: - Keyboard

    /// `on_key_down` (`pickers.rs:1908–1979`) + `classify_key`.
    ///
    /// Every intercepted chord returns `.handled` so it never reaches the search
    /// `TextField` — ⌘1…⌘9 in particular must not type a digit into the query.
    /// Keyboard nav walks the MODEL list only: the rail is mouse-only, and
    /// `MenuKey` has no Left/Right/Tab variant at all.
    private func handle(
        _ press: KeyPress,
        visible: [SupermuxZeronPickerRow]
    ) -> KeyPress.Result {
        // ⌘1…⌘9 are intercepted BEFORE classification and jump straight to a
        // row, against the FILTERED ordering — every path walks `visible`.
        if press.modifiers.contains(.command),
           let digit = press.characters.first?.wholeNumberValue,
           (1...9).contains(digit) {
            let index = digit - 1
            guard visible.indices.contains(index) else { return .handled }
            onSelect(visible[index])
            return .handled
        }

        switch press.key {
        case .upArrow:
            step(-1, count: visible.count)
            return .handled
        case .downArrow:
            step(1, count: visible.count)
            return .handled
        case .return:
            // `classify_key` maps Enter WITH cmd or ctrl to `MenuKey::ModEnter`,
            // which this picker ignores (it is the folder browser's "pick this
            // folder"). Only a bare Enter activates.
            if press.modifiers.contains(.command) || press.modifiers.contains(.control) {
                return .handled
            }
            guard visible.indices.contains(state.activeIndex) else { return .handled }
            onSelect(visible[state.activeIndex])
            return .handled
        case .escape:
            // `animate_close()`. Consumed here rather than left to bubble so it
            // cannot reach the search field and merely clear the query.
            onDismiss?()
            return .handled
        default:
            break
        }

        // Ctrl+N / Ctrl+P are readline motion, claimed frame-wide. Neither is a
        // text-editing binding here, so both always bubble unconsumed.
        if press.modifiers.contains(.control) {
            switch press.characters.lowercased() {
            case "n":
                step(1, count: visible.count)
                return .handled
            case "p":
                step(-1, count: visible.count)
                return .handled
            default:
                break
            }
        }

        // Everything else reaches the search input.
        return .ignored
    }

    /// Move the cursor AND ask the list to reveal it.
    ///
    /// `scroll_to_item(active)` is called by the Up/Down arms only — hover
    /// moves the same cursor but deliberately does not scroll.
    private func step(_ delta: Int, count: Int) {
        state.step(delta, count: count)
        keyboardReveal = state.activeIndex
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(spacing: M.railGap) {
            railTab(
                icon: .starBold,
                iconSize: 17,
                isViewed: state.rail == .favorites,
                isDisabled: false,
                label: Self.favoritesLabel
            ) {
                state.selectRail(.favorites, rows: rows, selectedID: selectedID)
            }

            // Full-bleed divider: the −4 horizontal margin cancels the rail's
            // own 4 pt padding so it meets the search row's hairline as one
            // continuous line. The 1 pt vertical margin is what puts it at
            // y 45–46 (see the file header).
            Rectangle()
                .fill(theme.hairline(0.08))
                .frame(height: 1)
                .padding(.horizontal, -M.railPad)
                .padding(.vertical, 1)

            // NOT disabled by `isLocked`. zeron's rule is
            // `locked && effective != Some(harness)` — a locked chat dims the
            // OTHER harnesses' tabs, never its own, and supermux has exactly one
            // harness, so this tab is always live. Dimming it here would strand a
            // locked session on the favorites view with no way back to the list.
            railTab(
                icon: .list,
                iconSize: 18,
                isViewed: state.rail == .harness,
                isDisabled: false,
                label: Self.allModelsLabel
            ) {
                state.selectRail(.harness, rows: rows, selectedID: selectedID)
            }

            Spacer(minLength: 0)
        }
        .padding(M.railPad)
        .frame(width: M.railWidth)
        // `.items_stretch()` — the rail is full height, not centered.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func railTab(
        icon: SupermuxZeronIcon.Name,
        iconSize: CGFloat,
        isViewed: Bool,
        isDisabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        SupermuxZeronPickerRailTab(
            theme: theme,
            icon: icon,
            iconSize: iconSize,
            isViewed: isViewed,
            isDisabled: isDisabled,
            label: label,
            action: action
        )
    }

    // MARK: - Pane

    private func pane(visible: [SupermuxZeronPickerRow]) -> some View {
        VStack(spacing: 0) {
            searchRow
            list(visible: visible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // t3 `bg-muted/40`: a whisper of wash lifts the pane off the rail.
        .background(theme.ink(0.02))
        .overlay(alignment: .leading) {
            // t3 `border-l border-border/70`, present only with the rail.
            if !state.filter.isSearching {
                Rectangle()
                    .fill(theme.hairline(0.07))
                    .frame(width: 1)
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            SupermuxZeronIcon(.magnifer, size: M.searchIcon)
                .foregroundStyle(theme.textMuted.opacity(0.7))
            // Borderless and untinted — the source comment is explicit:
            // "no accent tint".
            TextField(
                Self.searchPlaceholder,
                text: Binding(
                    get: { state.filter.query },
                    set: { state.setQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .font(SupermuxZeronFonts.sans(size: M.searchTextSize))
            .foregroundStyle(theme.text)
            // Enter reaches here via the input's submit while it holds focus —
            // `toggle` always focuses the search box for this picker, so this is
            // the NORMAL Enter path, not a fallback. Same outcome as the
            // frame-level Enter: it activates the cursor's row.
            .onSubmit {
                let rows = visible
                guard rows.indices.contains(state.activeIndex) else { return }
                onSelect(rows[state.activeIndex])
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, M.searchPadX)
        .frame(height: M.searchRowHeight)
        // Drawn INSIDE the 46 (border-box), so the row is 46 tall including
        // the hairline — not 47.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - List

    @ViewBuilder
    private func list(visible: [SupermuxZeronPickerRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Rows are the scroll container's DIRECT children so
                // `scrollTo(activeIndex)` maps 1:1 to row indices. Do NOT wrap
                // them in section containers — keyboard scrolling breaks
                // (`pickers.rs:2841`).
                LazyVStack(spacing: 2) {
                    if visible.isEmpty {
                        emptyNote
                    } else {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                            SupermuxZeronPickerModelRow(
                                theme: theme,
                                row: row,
                                index: index,
                                accelerator: index < 9 ? "⌘\(index + 1)" : nil,
                                highlight: state.highlight(
                                    at: index, rows: visible, selectedID: selectedID
                                ),
                                showsStar: onToggleFavorite != nil,
                                onHover: { hovered in
                                    // Hover MOVES THE CURSOR. It must never
                                    // paint a fill of its own.
                                    if hovered { state.hover(index) }
                                },
                                onSelect: { onSelect(row) },
                                onToggleFavorite: {
                                    onToggleFavorite?(row)
                                    // Starring REORDERS the list, so the cursor
                                    // must be re-homed onto the SELECTED row —
                                    // deliberately NOT onto the starred one, or
                                    // its wash lands beside the selection's ring
                                    // ("two highlighted rows", reported twice).
                                    // Armed here, applied once `rows` arrives
                                    // back re-ordered: doing it inline would
                                    // read this view's pre-toggle array.
                                    pendingRehome = true
                                }
                            )
                            .id(index)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .padding(.vertical, 6)
            .frame(maxHeight: .infinity)
            // Only the KEYBOARD reveals. `scroll_to_item` is called from the
            // Up/Down arms and from `toggle`'s open — never from `on_hover`,
            // which moves the same cursor without touching the scroll offset.
            .onChange(of: keyboardReveal) { _, index in
                guard let index, visible.indices.contains(index) else { return }
                // gpui's `scroll_to_item` is an instant offset write, not a
                // glide — an arrow key that animates its own scroll lags behind
                // a held key. Reduce Motion changes nothing here for that reason.
                proxy.scrollTo(index)
            }
        }
    }

    /// `empty_list_note` (`pickers.rs:3186–3195`): px 8, py 24, 12 pt,
    /// `textMuted @ 0.6`, centered. The copy depends on why the list is empty.
    private var emptyNote: some View {
        Text(
            state.filter.isSearching
                ? Self.noModelsFound
                : (state.rail == .favorites ? Self.noStarredModels : Self.noModels)
        )
        .font(SupermuxZeronFonts.sans(size: 12))
        .foregroundStyle(theme.textMuted.opacity(0.6))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 24)
    }

    // MARK: - Strings

    private static var searchPlaceholder: String {
        // Note the U+2026 ellipsis, not three periods.
        String(
            localized: "supermux.zeron.picker.search.placeholder",
            defaultValue: "Search models…",
            bundle: .supermuxZeronUI
        )
    }

    private static var noModelsFound: String {
        String(
            localized: "supermux.zeron.picker.empty.noMatches",
            defaultValue: "No models found",
            bundle: .supermuxZeronUI
        )
    }

    private static var noStarredModels: String {
        // Em dash U+2014, as in the source string.
        String(
            localized: "supermux.zeron.picker.empty.noStars",
            defaultValue: "No starred models yet — hit a row's star",
            bundle: .supermuxZeronUI
        )
    }

    private static var noModels: String {
        String(
            localized: "supermux.zeron.picker.empty.noModels",
            defaultValue: "No models available",
            bundle: .supermuxZeronUI
        )
    }

    private static var favoritesLabel: String {
        String(
            localized: "supermux.zeron.picker.rail.favorites",
            defaultValue: "Starred models",
            bundle: .supermuxZeronUI
        )
    }

    private static var allModelsLabel: String {
        String(
            localized: "supermux.zeron.picker.rail.all",
            defaultValue: "All models",
            bundle: .supermuxZeronUI
        )
    }
}

// MARK: - Rail tab

/// One 36 × 36 rail tab with the 3 × 20 left half-capsule indicator.
///
/// Split into its own view so the hover fill is local state on a leaf — the
/// rail's hover IS an independent hover (it is not a list row), unlike a model
/// row's, which must move the shared cursor instead.
struct SupermuxZeronPickerRailTab: View {
    let theme: SupermuxZeronTheme
    let icon: SupermuxZeronIcon.Name
    let iconSize: CGFloat
    let isViewed: Bool
    let isDisabled: Bool
    let label: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = SupermuxZeronMetrics.Pickers

    var body: some View {
        Button(action: action) {
            ZStack {
                // The resting wash is ink(0), NOT Color.clear — a mid-fade
                // through `clear` flashes grey because SwiftUI blends
                // premultiplied.
                RoundedRectangle(cornerRadius: M.railTabRadius, style: .continuous)
                    .fill(theme.ink(showsHoverFill ? 0.06 : 0))
                SupermuxZeronIcon(icon, size: iconSize)
                    .foregroundStyle(isViewed ? theme.text : theme.textMuted.opacity(0.75))
            }
            .frame(width: M.railTab, height: M.railTab)
            .overlay(alignment: .topTrailing) {
                if isViewed { indicator }
            }
            .contentShape(RoundedRectangle(cornerRadius: M.railTabRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        // A locked chat dims the whole tab and takes neither hover nor clicks.
        .opacity(isDisabled ? 0.35 : 1)
        .onHover { isHovered = $0 }
        // Reduce Motion snaps a hover fade to its endpoint
        // (`hover_fade_reduced_motion_snaps`, spec 07 §6).
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: showsHoverFill
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(isViewed ? [.isSelected] : [])
        .help(label)
    }

    /// The **active tab has no hover state** (`.when(!favorites_view, …)`), and
    /// neither does a disabled one.
    private var showsHoverFill: Bool { isHovered && !isViewed && !isDisabled }

    /// `rail_indicator` — a LEFT half-capsule whose flat right edge presses
    /// against the rail/pane border it hugs. The −4 right offset places it
    /// exactly over the rail's own padding edge, i.e. flush with the pane's
    /// left border.
    private var indicator: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: M.railIndicatorWidth,
            bottomLeadingRadius: M.railIndicatorWidth,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(theme.pickerPurple)
        .frame(width: M.railIndicatorWidth, height: M.railIndicatorHeight)
        .offset(x: -M.railIndicatorRightInset, y: M.railIndicatorTopInset)
    }
}

// MARK: - Model row

/// One two-line model row. Painted geometry only — every piece of state it
/// shows is passed in, so it holds no store reference and writes nothing from
/// `body` (the SwiftUI list-boundary rule, cmux #2586).
struct SupermuxZeronPickerModelRow: View {
    let theme: SupermuxZeronTheme
    let row: SupermuxZeronPickerRow
    let index: Int
    let accelerator: String?
    let highlight: SupermuxZeronPickerHighlight
    let showsStar: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    private typealias M = SupermuxZeronMetrics.Pickers

    var body: some View {
        // The star is a SIBLING of the row's tap target, not a child of it.
        // zeron calls `cx.stop_propagation()` first so the row's own click never
        // fires; SwiftUI has no propagation to stop — a `Button` nested inside a
        // `.plain` `Button` is simply unreachable, and the star would toggle the
        // MODEL instead of the favorite. Keeping it outside is the only way the
        // nested control works at all.
        HStack(spacing: M.rowGap) {
            Button(action: onSelect) {
                HStack(spacing: M.rowGap) {
                    labelColumn
                    if let accelerator {
                        keyboardChip(accelerator)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsStar {
                SupermuxZeronPickerStarToggle(
                    theme: theme,
                    isFavorite: row.isFavorite,
                    action: onToggleFavorite
                )
            }
        }
        .padding(.horizontal, M.rowPadX)
        .padding(.vertical, M.rowPadY)
        .background(
            RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous)
                .fill(fill)
        )
        .overlay {
            // The selection ring is an inset 1 pt strokeBorder, NEVER a
            // `.shadow()`: a SwiftUI drop shadow is a filled rect painted
            // BEHIND the element, and behind a translucent 5–11 % fill it
            // shows through as an opaque grey plate.
            if highlight == .selected {
                RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous)
                    .strokeBorder(theme.selectionRing(), lineWidth: 1)
            }
        }
        // The WHOLE row is hoverable, including the padding the label button
        // does not cover — hover moves the cursor, so a dead strip inside the
        // row would make the highlight stutter as the pointer crosses it.
        .contentShape(RoundedRectangle(cornerRadius: M.rowRadius, style: .continuous))
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.label), \(row.subline)")
        .accessibilityAddTraits(highlight == .selected ? [.isSelected] : [])
    }

    /// Resting fill is `ink(0)`, never `Color.clear`.
    private var fill: Color {
        switch highlight {
        case .selected: theme.cardSelectedBG()
        case .active: theme.ink(0.05)
        case .idle: theme.ink(0)
        }
    }

    private var labelColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.label)
                .font(SupermuxZeronFonts.sans(size: M.labelSize, weight: .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                // zeron paints a harness brand mark here. supermux has one
                // harness and ships no third-party brand marks (plan §6.4), so
                // the identity line is text-only.
                Text(row.subline)
                    .font(SupermuxZeronFonts.sans(size: M.sublineSize))
                    .foregroundStyle(theme.textMuted.opacity(M.sublineAlpha))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `popover::kbd_hint` — px 5, py 1, r 5, `ink(0.05)`, 10 pt MONO,
    /// `textMuted @ 0.6`.
    private func keyboardChip(_ label: String) -> some View {
        Text(label)
            .font(SupermuxZeronFonts.mono(size: M.kbdChipTextSize))
            .foregroundStyle(theme.textMuted.opacity(M.kbdChipTextAlpha))
            .padding(.horizontal, M.kbdChipPadX)
            .padding(.vertical, M.kbdChipPadY)
            .background(
                RoundedRectangle(cornerRadius: M.kbdChipRadius, style: .continuous)
                    .fill(theme.ink(M.kbdChipInkAlpha))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Star toggle

/// The 22 × 22 star. A nested control, so it **does** own an independent hover
/// (unlike the row it sits in), and its tap must not fall through to the row —
/// zeron calls `cx.stop_propagation()` first.
struct SupermuxZeronPickerStarToggle: View {
    let theme: SupermuxZeronTheme
    let isFavorite: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias M = SupermuxZeronMetrics.Pickers

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: M.starRadius, style: .continuous)
                    .fill(theme.ink(isHovered ? 0.08 : 0))
                SupermuxZeronIcon(isFavorite ? .starBold : .star, size: M.starIcon)
                    .foregroundStyle(
                        isFavorite ? theme.warning : theme.textMuted.opacity(0.45)
                    )
            }
            .frame(width: M.starToggle, height: M.starToggle)
            .contentShape(RoundedRectangle(cornerRadius: M.starRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : SupermuxZeronMetrics.Motion.hoverFade.animation,
            value: isHovered
        )
        .accessibilityLabel(
            isFavorite
                ? String(
                    localized: "supermux.zeron.picker.star.remove",
                    defaultValue: "Remove from starred",
                    bundle: .supermuxZeronUI
                )
                : String(
                    localized: "supermux.zeron.picker.star.add",
                    defaultValue: "Add to starred",
                    bundle: .supermuxZeronUI
                )
        )
    }
}

// MARK: - Footer hint bar

/// The authentic key-cap legend (`popover::key_cap` / `key_hint*`).
///
/// **zeron's model picker renders no footer** — these primitives were detached
/// from it and now live only on the add-space palette (spec 08 §1.9). Every
/// token here is nonetheless real zeron, measured pixel-for-pixel out of
/// `s1-picker-highlight.png`, so a shell that wants the legend back gets the
/// genuine one rather than an invention. Opt in explicitly; nothing mounts it
/// by default.
public struct SupermuxZeronPickerFooter: View {
    private let theme: SupermuxZeronTheme
    private let hints: [Hint]

    /// One legend entry: a key cap plus its tiny verb.
    public struct Hint: Identifiable, Sendable, Equatable {
        public enum Cap: Sendable, Equatable {
            /// One glyph at 12.5.
            case icon(SupermuxZeronIcon.Name)
            /// Two glyphs split by a 1 × 11 pt `hairline(0.10)` rule, sharing
            /// one verb ("[ ↑ | ↓ ] Navigate").
            case pair(SupermuxZeronIcon.Name, SupermuxZeronIcon.Name)
            /// A WORD at 11 pt mono, for keys with no glyph in the set.
            case word(String)
        }

        public let id: String
        public let cap: Cap
        public let label: String

        public init(id: String, cap: Cap, label: String) {
            self.id = id
            self.cap = cap
            self.label = label
        }
    }

    public init(theme: SupermuxZeronTheme, hints: [Hint]) {
        self.theme = theme
        self.hints = hints
    }

    public var body: some View {
        HStack(spacing: 12) {
            ForEach(hints) { hint in
                HStack(spacing: 5) {
                    cap(hint.cap)
                    Text(hint.label)
                        .font(SupermuxZeronFonts.sans(size: 10.5))
                        .foregroundStyle(theme.textMuted.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.band)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline(0.08))
                .frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    /// `key_cap`: h 22, px 5, r 5, gap 4, `ink(0.05)`.
    @ViewBuilder
    private func cap(_ cap: Hint.Cap) -> some View {
        HStack(spacing: 4) {
            switch cap {
            case .icon(let name):
                SupermuxZeronIcon(name, size: 12.5)
                    .foregroundStyle(theme.textMuted.opacity(0.7))
            case .pair(let first, let second):
                SupermuxZeronIcon(first, size: 12.5)
                    .foregroundStyle(theme.textMuted.opacity(0.7))
                Rectangle()
                    .fill(theme.hairline(0.10))
                    .frame(width: 1, height: 11)
                SupermuxZeronIcon(second, size: 12.5)
                    .foregroundStyle(theme.textMuted.opacity(0.7))
            case .word(let word):
                Text(word)
                    .font(SupermuxZeronFonts.mono(size: 11))
                    .foregroundStyle(theme.textMuted.opacity(0.7))
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.ink(0.05))
        )
    }
}

// MARK: - Shadow

/// Tailwind's `shadow-lg` recipe, standing in for gpui's unvendored
/// `shadow_lg()` preset (plan R13).
///
/// **Painted on every platform**, deliberately: `popover_card` calls
/// `.shadow_lg()` unconditionally (`popover.rs:309`) — only the *background* is
/// gated on `is_glass()`, never the shadow. This matters most in **light mode**,
/// where the audit measured the card's own edge at just 1.35:1 against a white
/// page (`hairline(0.10)` → `#DDDDDD` on `#FFFFFF`); with the shadow suppressed
/// the whole 360 × 346 card loses its silhouette and reads as part of the page.
private struct SupermuxZeronCardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.1), radius: 7.5, x: 0, y: 10)
            .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 4)
    }
}

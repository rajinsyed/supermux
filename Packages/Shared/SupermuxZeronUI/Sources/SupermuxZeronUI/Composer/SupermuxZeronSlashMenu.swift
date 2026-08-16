//
//  SupermuxZeronSlashMenu.swift
//  SupermuxZeronUI
//
//  The 380 × 280 slash-command card: trigger rule, filter + ranking, keyboard
//  model, and the rows. Spec 04 §8, from `composer.rs:3199-3219 / 4070-4261`
//  and `popover.rs:213-258 / 303 / 629`.
//
//  ── Two behaviors that look like bugs and are not ──
//
//  1. **There is no exit animation.** The slash popup passes `closing = None`
//     explicitly: "a fade-out on every keystroke-driven dismissal would read as
//     input lag, not polish". Only the entrance (`MENU_IN`, opacity 0.3 → 1 plus
//     a −2 → 0 rise) animates.
//  2. **`active` resets to row 0 on EVERY refilter**, so the top row is always
//     preselected after a keystroke — including after a keystroke that widened
//     the result set.
//

public import SwiftUI

internal import Foundation

// MARK: - Command model

/// One slash command the harness advertises.
///
/// supermux's `system.init` gives names only, so `description` and `inputHint`
/// are optional — the row collapses to the name alone, which is exactly what
/// `render_slash_popup` renders when `command.description` is empty.
public struct SupermuxZeronSlashCommand: Sendable, Equatable, Hashable, Identifiable {
    /// The bare name, WITHOUT the leading slash (`"compact"`).
    public let name: String
    public let description: String
    /// Rendered as `"<hint>"` after the description.
    public let inputHint: String?

    public var id: String { name }

    public init(name: String, description: String = "", inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }

    /// `"/compact"`.
    public var displayName: String { "/\(name)" }

    /// The 12 pt muted run to the right of the name (`composer.rs:4202-4210`).
    ///
    /// The hint is **not styled separately** — it is concatenated into the same
    /// run, separated by `" · "`: `"Set a goal · <the goal>"`.
    public var detailText: String {
        guard let inputHint, !inputHint.isEmpty else { return description }
        return description.isEmpty ? "<\(inputHint)>" : "\(description) · <\(inputHint)>"
    }
}

// MARK: - Token + filter model

/// The pure slash-token, filter and keyboard model.
///
/// Held above any lazy-list boundary and read as a value inside `body`, so no
/// view below a `ForEach` ever holds a reference to it (cmux #2586).
public struct SupermuxZeronSlashState: Sendable, Equatable, Hashable {
    /// The live token: the range it occupies in the draft plus its query.
    public struct Token: Sendable, Equatable, Hashable {
        /// Character offsets into the draft. Always starts at 0.
        public let range: Range<Int>
        /// The text between the `/` and the caret.
        public let query: String

        public init(range: Range<Int>, query: String) {
            self.range = range
            self.query = query
        }
    }

    public private(set) var token: Token?
    /// Indices into the command list, filter-ranked for the query.
    public private(set) var filtered: [Int]
    /// The highlighted row, as an index into ``filtered``.
    public private(set) var active: Int?
    /// A token the user dismissed with Escape: moving WITHIN the same token
    /// keeps the popup closed, while any edit re-enables completion.
    public private(set) var dismissed: Token?

    public init() {
        token = nil
        filtered = []
        active = nil
        dismissed = nil
    }

    /// Whether the card should be mounted at all.
    public var isOpen: Bool { token != nil }

    // MARK: The trigger rule (`slash_token`, composer.rs:3199)

    /// The slash token for a draft and caret, or `nil` when no popup opens.
    ///
    /// The `/` must be at **offset 0** — slash commands are whole-prompt
    /// prefixes. The token runs to the first whitespace; the popup closes once
    /// the caret moves past it (i.e. while typing the argument), and never
    /// opens when the query itself contains another `/` (a typed path).
    ///
    /// `caret` is a **character** offset, not a UTF-8 byte offset: Swift's
    /// `String.Index` arithmetic already refuses non-boundaries, so zeron's
    /// `is_char_boundary` guard has no Swift analogue to port.
    public static func token(in text: String, caret: Int) -> Token? {
        let characters = Array(text)
        guard caret > 0, caret <= characters.count, characters.first == "/" else { return nil }
        let end = characters.firstIndex(where: { $0.isWhitespace }) ?? characters.count
        guard caret <= end else { return nil }
        let query = String(characters[1 ..< caret])
        guard !query.contains("/") else { return nil }
        return Token(range: 0 ..< end, query: query)
    }

    // MARK: Filter + rank (`match_rank` / `filter_indices`, popover.rs:231/251)

    /// `0` prefix match, `1` substring, `nil` no match. Case-insensitive; an
    /// **empty query matches everything at rank 1**, preserving input order.
    public static func matchRank(query: String, label: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return 1 }
        let label = label.lowercased()
        if label.hasPrefix(query) { return 0 }
        return label.contains(query) ? 1 : nil
    }

    /// Prefix matches first, then substring matches, **stable within each
    /// rank**. Returns indices into `labels`.
    public static func filterIndices(query: String, labels: [String]) -> [Int] {
        labels.enumerated()
            .compactMap { index, label in
                matchRank(query: query, label: label).map { (rank: $0, index: index) }
            }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.index)
    }

    // MARK: Reducers

    /// Recomputes the token from the draft and re-ranks the cached commands.
    ///
    /// `active` resets to row 0 on every refilter — the top row is always
    /// preselected after a keystroke.
    public mutating func sync(text: String, caret: Int, commands: [SupermuxZeronSlashCommand]) {
        let next = Self.token(in: text, caret: caret)
        if let next, let dismissed, dismissed.range == next.range, dismissed.query == next.query {
            // Same token, unedited: stay closed.
            token = nil
            filtered = []
            active = nil
            return
        }
        if next == nil || dismissed?.query != next?.query { dismissed = nil }
        token = next
        guard let next else {
            filtered = []
            active = nil
            return
        }
        filtered = Self.filterIndices(query: next.query, labels: commands.map(\.name))
        active = filtered.isEmpty ? nil : 0
    }

    /// `menu_step` — wraps at both ends; `nil` enters at the edge matching the
    /// direction. An empty menu stays `nil`.
    public static func step(active: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let active else { return delta >= 0 ? 0 : count - 1 }
        let next = (active + delta) % count
        return next < 0 ? next + count : next
    }

    /// ↑ / ↓ over the filtered rows.
    public mutating func move(by delta: Int) {
        active = Self.step(active: active, count: filtered.count, delta: delta)
    }

    /// Escape: closes and records the token, so moving within it keeps it shut.
    public mutating func dismiss() {
        dismissed = token
        token = nil
        filtered = []
        active = nil
    }

    /// The command the highlighted row would accept.
    public func acceptedCommand(
        from commands: [SupermuxZeronSlashCommand]
    ) -> SupermuxZeronSlashCommand? {
        guard let active, active < filtered.count else { return nil }
        let index = filtered[active]
        return commands.indices.contains(index) ? commands[index] : nil
    }

    /// Applies an accept to the draft: the whole token range becomes
    /// `"/<name>"`. Returns the new draft and the caret to place after it.
    public func accept(
        in text: String,
        commands: [SupermuxZeronSlashCommand]
    ) -> (text: String, caret: Int)? {
        guard let token, let command = acceptedCommand(from: commands) else { return nil }
        let characters = Array(text)
        guard token.range.upperBound <= characters.count else { return nil }
        let replacement = command.displayName
        let head = String(characters[0 ..< token.range.lowerBound])
        let tail = String(characters[token.range.upperBound...])
        return (head + replacement + tail, head.count + replacement.count)
    }

    /// Selects a row by index (a click sets `active`, then accepts).
    public mutating func select(row: Int) {
        guard row >= 0, row < filtered.count else { return }
        active = row
    }
}

// MARK: - Load state

/// What the card body shows. Loading only appears on the FIRST open for a
/// harness — commands are fetched once and filtered locally per keystroke, so
/// no skeleton churns while typing.
public enum SupermuxZeronSlashPhase: Sendable, Equatable, Hashable {
    case loaded
    case loading
    case failed(String)
}

// MARK: - The card

/// The slash-command popover card.
///
/// Mounted by the platform shell above the `/` glyph, opening upward with a
/// 6 pt gap and clamped ≥ 8 pt from every window edge. It renders only itself;
/// anchoring is the shell's job because a caret point is not addressable from
/// inside the card.
public struct SupermuxZeronSlashMenu: View {
    private typealias Metrics = SupermuxZeronMetrics.Composer
    private typealias Pickers = SupermuxZeronMetrics.Pickers

    private let theme: SupermuxZeronTheme
    private let commands: [SupermuxZeronSlashCommand]
    private let state: SupermuxZeronSlashState
    private let phase: SupermuxZeronSlashPhase
    private let showsKeyboardHints: Bool
    private let onSelect: (Int) -> Void
    private let onAccept: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var hoveredRow: Int?

    /// - Parameters:
    ///   - showsKeyboardHints: iOS renders the ⌘ badge only when a hardware
    ///     keyboard is attached (`GCKeyboard.coalesced != nil`); macOS always.
    public init(
        theme: SupermuxZeronTheme,
        commands: [SupermuxZeronSlashCommand],
        state: SupermuxZeronSlashState,
        phase: SupermuxZeronSlashPhase = .loaded,
        showsKeyboardHints: Bool = true,
        onSelect: @escaping (Int) -> Void = { _ in },
        onAccept: @escaping (Int) -> Void = { _ in }
    ) {
        self.theme = theme
        self.commands = commands
        self.state = state
        self.phase = phase
        self.showsKeyboardHints = showsKeyboardHints
        self.onSelect = onSelect
        self.onAccept = onAccept
    }

    public var body: some View {
        card
            .frame(width: Metrics.slashCardWidth)
            .frame(maxHeight: Metrics.slashCardMaxHeight, alignment: .top)
            .clipShape(shape)
            // MENU_IN: opacity 0.3 → 1 (never 0 — a menu popping in from zero
            // looks slower) plus a −2 → 0 rise. There is NO exit animation.
            .opacity(appeared ? 1 : SupermuxZeronMetrics.Motion.menuInOpacityFloor)
            .offset(y: appeared ? 0 : SupermuxZeronMetrics.Motion.menuInRise)
            .onAppear {
                guard !reduceMotion else {
                    appeared = true
                    return
                }
                withAnimation(SupermuxZeronMetrics.Motion.menuIn.animation) { appeared = true }
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.slashCardRadius, style: .continuous)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            body(for: phase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.slashCardPad)
        .background(
            SupermuxZeronComposerBackdrop(
                theme: theme,
                surface: .menu,
                cornerRadius: Metrics.slashCardRadius
            )
        )
        .overlay(shape.strokeBorder(theme.hairline(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private func body(for phase: SupermuxZeronSlashPhase) -> some View {
        switch phase {
        case .loading where state.filtered.isEmpty:
            SupermuxZeronSlashSkeleton(theme: theme)
        case .failed(let text):
            messageRow(text, color: theme.dangerMuted)
        case .loading, .loaded:
            if state.filtered.isEmpty {
                messageRow(emptyText, color: theme.textMuted)
            } else {
                rows
            }
        }
    }

    private var emptyText: String {
        commands.isEmpty
            ? String(
                localized: "supermux.zeron.slash.noCommands",
                defaultValue: "This agent has no slash commands",
                bundle: .supermuxZeronUI
            )
            : String(
                localized: "supermux.zeron.slash.noMatches",
                defaultValue: "No matching commands",
                bundle: .supermuxZeronUI
            )
    }

    private func messageRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(SupermuxZeronFonts.sans(size: 12))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: some View {
        // Deliberately a plain VStack in a ScrollView, not a LazyVStack: the
        // card caps at 280 pt and the command list is a handful of rows, so
        // laziness buys nothing and would put these rows below a lazy boundary
        // (cmux #2586) for no reason.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.filtered.enumerated()), id: \.offset) { row, index in
                    if commands.indices.contains(index) {
                        SupermuxZeronSlashRow(
                            theme: theme,
                            command: commands[index],
                            isActive: state.active == row,
                            isHovered: hoveredRow == row,
                            showsCommandBadge: showsKeyboardHints
                        )
                        .contentShape(Rectangle())
                        .onHover { hovering in hoveredRow = hovering ? row : nil }
                        .onTapGesture {
                            onSelect(row)
                            onAccept(row)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Row

/// One slash row: the ⌘ badge, the command name, and the description.
///
/// The badge is a **plain tinted glyph** — no plate, no background, no border,
/// no rounding.
struct SupermuxZeronSlashRow: View {
    private typealias Pickers = SupermuxZeronMetrics.Pickers

    let theme: SupermuxZeronTheme
    let command: SupermuxZeronSlashCommand
    let isActive: Bool
    let isHovered: Bool
    let showsCommandBadge: Bool

    var body: some View {
        HStack(spacing: SupermuxZeronMetrics.Theme.spaceSM) {
            if showsCommandBadge {
                SupermuxZeronComposerIcon(.command, size: 14)
                    .foregroundStyle(theme.textMuted)
            }
            Text(command.displayName)
                .font(SupermuxZeronFonts.sans(size: Pickers.labelSize, weight: .medium))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: true, vertical: false)
            if !command.detailText.isEmpty {
                Text(command.detailText)
                    .font(SupermuxZeronFonts.sans(size: 12))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Pickers.menuRowPadX)
        .padding(.vertical, Pickers.menuRowPadY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        // The active row is `theme.text`; an inactive row rests at text @ 90 %
        // and brightens with the hover wash over the same 150 ms.
        .foregroundStyle(isActive || isHovered ? theme.text : theme.text.opacity(0.9))
    }

    private var rowBackground: some View {
        // The hover wash and the keyboard-selected wash are the SAME fill here
        // (`menu_row`); only `menu_row_nav` distinguishes them, and the slash
        // popup uses plain `menu_row`. Resting is `wash(0)` — white at zero
        // alpha, never `Color.clear`, so the mid-fade cannot flash grey.
        RoundedRectangle(cornerRadius: Pickers.menuRowRadius, style: .continuous)
            .fill(isActive || isHovered ? theme.cardSelectedBG() : theme.wash(0))
            .animation(SupermuxZeronMetrics.Motion.hoverFade.animation, value: isHovered)
    }
}

// MARK: - Skeleton

/// `popover::skeleton_rows(3)` — 28 pt `ink(0.04)` bars pulsing on the shared
/// 2400 ms clock with a 0.08-of-period per-row stagger.
struct SupermuxZeronSlashSkeleton: View {
    let theme: SupermuxZeronTheme
    private let rowCount = 3
    private let stagger = 0.08

    @Environment(\.supermuxZeronPulseClock) private var clockOverride
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reading the phase renews this skeleton's lease on the ONE 30 fps
        // clock and subscribes the body to its frame counter — never
        // `.repeatForever` or `TimelineView(.animation)` (plan R12). It is a
        // read of published state; the lease is the clock's own bookkeeping.
        let clock = clockOverride ?? SupermuxZeronPulseClock.shared
        let delta = clock.phase(
            period: Double(SupermuxZeronMetrics.Motion.zeronPulse.durationMS) / 1000,
            leasedBy: "slash-skeleton",
            reduceMotion: reduceMotion
        )
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0 ..< rowCount, id: \.self) { row in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.ink(0.04))
                    .frame(height: 28)
                    .opacity(opacity(delta: delta, row: row))
            }
        }
        .padding(.vertical, 4)
    }

    /// Reduced motion snaps a LOADER to its START state (plan §4 / spec 07 §6),
    /// which for the skeleton wave is the 0.35 floor — `pulseWave(0) == 0`, so
    /// the clock's static 0 already lands there.
    private func opacity(delta: Double, row: Int) -> Double {
        guard !reduceMotion else { return 0.35 }
        let phase = SupermuxZeronMetrics.Loaders.staggeredPhase(
            delta,
            index: row,
            stagger: stagger
        )
        return SupermuxZeronMetrics.Loaders.skeletonOpacity(phase)
    }
}

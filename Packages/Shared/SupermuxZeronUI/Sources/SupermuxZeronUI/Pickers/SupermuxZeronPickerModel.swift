//
//  SupermuxZeronPickerModel.swift
//  SupermuxZeronUI
//
//  The picker's pure core: rows, filtering, ranking, and the ONE MOVING
//  HIGHLIGHT invariant. Spec 08 §1.8, §2.3, §2.4, §2.5.
//
//  Split out of the card view on purpose. Everything here is a value type with
//  no SwiftUI dependency, so the highlight invariant — a twice-reported user bug
//  in zeron ("two highlighted rows", `pickers.rs:1483–1486`) — is unit-testable
//  without rendering anything.
//

internal import Foundation

// MARK: - Row

/// One selectable row in the picker's model pane.
///
/// zeron rows are two-line: the model label over a *harness identity* subline
/// (t3 `showProvider`, which replaces the model description). supermux has one
/// harness, so the subline carries the provider/alias identity instead — the
/// geometry is identical either way.
public struct SupermuxZeronPickerRow: Identifiable, Sendable, Equatable, Hashable {
    /// Stable identity; the value handed back on selection.
    public let id: String
    /// Line 1 — 12.5 pt MEDIUM in `theme.text`, truncating.
    public let label: String
    /// Line 2 — 11 pt in `theme.textMuted @ 0.7`, truncating. The harness
    /// identity in zeron; the provider/alias line here.
    public let subline: String
    /// Whether this row is starred. Stars float to the top of every view and
    /// break rank ties during a search.
    public let isFavorite: Bool

    public init(id: String, label: String, subline: String, isFavorite: Bool = false) {
        self.id = id
        self.label = label
        self.subline = subline
        self.isFavorite = isFavorite
    }
}

// MARK: - Rail

/// Which rail tab the pane is showing.
///
/// The rail is **mouse-only** in zeron: `MenuKey` has no `Left`/`Right`/`Tab`
/// variant at all, so no key binding moves focus into it (spec 08 §2.1).
public enum SupermuxZeronPickerRail: Sendable, Equatable, Hashable, CaseIterable {
    /// The favorites star tab — always the rail's first child.
    case favorites
    /// The harness tab. supermux has exactly one (plan §0.4).
    case harness
}

// MARK: - Highlight

/// How a row is painted. **At most one treatment per row, always.**
///
/// `selected` wins over `active`, which is what makes hover and the keyboard
/// cursor unable to wear two washes at once (`pickers.rs:2867–2871`).
public enum SupermuxZeronPickerHighlight: Sendable, Equatable, Hashable {
    /// The chosen model: `cardSelectedBG()` fill **plus** a 1 pt inset
    /// `selectionRing()`. Never a `.shadow()`.
    case selected
    /// The keyboard/hover cursor: `ink(0.05)`, no ring.
    case active
    /// Transparent — `ink(0)`, never `Color.clear`.
    case idle
}

// MARK: - Filter

/// The search query and its ranking rules (`pickers.rs:1373–1400`).
///
/// A value type with real instance surface, so the ranking is reachable from a
/// test without a view, a store, or a live picker.
public struct SupermuxZeronPickerFilter: Sendable, Equatable, Hashable {
    /// The raw query. Derived state, never stored on the picker in zeron:
    /// `query = search.text().trim()`.
    public let query: String

    public init(query: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `searching = !query.is_empty()`. **This also removes the rail from the
    /// tree**, because the query spans every harness.
    public var isSearching: Bool { !query.isEmpty }

    /// `popover::match_rank` (`popover.rs:234–247`): 0 = case-insensitive
    /// prefix, 1 = substring, `nil` = no match. An empty query matches
    /// everything at rank 1, preserving input order.
    public static func matchRank(query: String, label: String) -> Int? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return 1 }
        let label = label.lowercased()
        if label.hasPrefix(query) { return 0 }
        if label.contains(query) { return 1 }
        return nil
    }

    /// Ranks and orders `rows` for a live query.
    ///
    /// Exactly zeron's ladder: `min(rank(label), rank("{subline} {label}") + 2)`,
    /// rows with no match dropped, then sorted by
    /// `(rank, !isFavorite, inputIndex)` — so **within a rank, starred rows
    /// float above unstarred**, then input order breaks the remaining ties.
    public func ranked(_ rows: [SupermuxZeronPickerRow]) -> [SupermuxZeronPickerRow] {
        guard isSearching else { return rows }
        var scored: [(rank: Int, unstarred: Int, index: Int, row: SupermuxZeronPickerRow)] = []
        for (index, row) in rows.enumerated() {
            let byLabel = Self.matchRank(query: query, label: row.label)
            let byHarness = Self.matchRank(query: query, label: "\(row.subline) \(row.label)")
                .map { $0 + 2 }
            guard let rank = [byLabel, byHarness].compactMap({ $0 }).min() else { continue }
            scored.append((rank, row.isFavorite ? 0 : 1, index, row))
        }
        scored.sort {
            ($0.rank, $0.unstarred, $0.index) < ($1.rank, $1.unstarred, $1.index)
        }
        return scored.map(\.row)
    }
}

// MARK: - State

/// The picker's whole interaction state, as one value.
///
/// The card holds exactly one of these in `@State`. Hover, arrow keys, ⌘N and
/// the star toggle all mutate **this** — never a per-row flag — which is the
/// mechanism behind the one-moving-highlight rule.
public struct SupermuxZeronPickerState: Sendable, Equatable {
    /// Which rail tab is showing. Ignored while ``filter`` is searching.
    public var rail: SupermuxZeronPickerRail
    /// The live query.
    public var filter: SupermuxZeronPickerFilter
    /// The keyboard cursor. The **only** highlight that moves; hover writes
    /// here rather than painting locally.
    public var activeIndex: Int

    public init(
        rail: SupermuxZeronPickerRail = .harness,
        query: String = "",
        activeIndex: Int = 0
    ) {
        self.rail = rail
        self.filter = SupermuxZeronPickerFilter(query: query)
        self.activeIndex = activeIndex
    }

    // MARK: Visible rows

    /// The rows the pane shows, flat and in render order.
    ///
    /// Keyboard nav, ⌘N jumps, Enter and the render all walk **this same list**
    /// (`pickers.rs:1354–1355`), which is why `scrollTo(activeIndex)` maps 1:1
    /// to row indices and why rows must stay the scroll container's direct
    /// children — no section wrappers (spec 08 §1.7).
    ///
    /// - A live search spans everything and ignores the rail.
    /// - Favorites view: starred rows only, in input order.
    /// - Harness view: starred rows floated to the top (t3 `groupFavorites`),
    ///   each partition preserving catalog order.
    public func visibleRows(from all: [SupermuxZeronPickerRow]) -> [SupermuxZeronPickerRow] {
        if filter.isSearching { return filter.ranked(all) }
        switch rail {
        case .favorites:
            return all.filter(\.isFavorite)
        case .harness:
            return all.filter(\.isFavorite) + all.filter { !$0.isFavorite }
        }
    }

    // MARK: The highlight

    /// How the row at `index` paints, given the current selection.
    ///
    /// **The invariant:** a row is never both. `selected` wins, so the
    /// keyboard cursor sitting on the selected row shows one treatment, not two
    /// stacked washes.
    public func highlight(
        at index: Int,
        rows: [SupermuxZeronPickerRow],
        selectedID: String?
    ) -> SupermuxZeronPickerHighlight {
        guard rows.indices.contains(index) else { return .idle }
        if let selectedID, rows[index].id == selectedID { return .selected }
        return index == activeIndex ? .active : .idle
    }

    // MARK: Reducers

    /// `menu_step` (`popover.rs:213–229`): wraps at **both** ends via
    /// `rem_euclid`. An empty list parks the cursor at 0.
    public mutating func step(_ delta: Int, count: Int) {
        guard count > 0 else {
            activeIndex = 0
            return
        }
        let next = (activeIndex + delta) % count
        activeIndex = next < 0 ? next + count : next
    }

    /// Hover **moves the keyboard cursor** instead of painting its own wash.
    ///
    /// This is the whole fix. Do not add a local `isHovered` fill at the call
    /// site: hover + arrow cursor would then wear two washes at once.
    public mutating func hover(_ index: Int) {
        if activeIndex != index { activeIndex = index }
    }

    /// Typing resets the cursor to the top of the fresh results
    /// (`pickers.rs:435–450`) and the caller resets the scroll offset with it.
    ///
    /// The programmatic clear inside ``open(rows:selectedID:hasFavorites:isLocked:)``
    /// deliberately does **not** route through here — zeron mutes that one
    /// reset, because an unmuted one clobbers the just-anchored selected row
    /// back to 0 and leaves the top row wearing a second highlight.
    public mutating func setQuery(_ query: String) {
        let next = SupermuxZeronPickerFilter(query: query)
        guard next != filter else { return }
        filter = next
        activeIndex = 0
    }

    /// Opening the picker (`toggle`, `pickers.rs:760–862`). **The order matters.**
    ///
    /// 1. Clear the query.
    /// 2. **Prime the rail before anchoring the highlight** — the visible rows
    ///    depend on it. Favorites when unlocked and any star exists, else the
    ///    harness tab; a locked chat stays on its own harness.
    /// 3. Anchor the cursor on the **selected** row, never row 0: "row 0
    ///    otherwise reads as a second active row (user report)."
    public mutating func open(
        rows: [SupermuxZeronPickerRow],
        selectedID: String?,
        hasFavorites: Bool,
        isLocked: Bool
    ) {
        filter = SupermuxZeronPickerFilter(query: "")
        rail = (!isLocked && hasFavorites) ? .favorites : .harness
        activeIndex = selectedIndex(rows: rows, selectedID: selectedID)
    }

    /// Switching rail tabs re-anchors the cursor the same way an open does —
    /// the visible set just changed under it.
    public mutating func selectRail(
        _ rail: SupermuxZeronPickerRail,
        rows: [SupermuxZeronPickerRow],
        selectedID: String?
    ) {
        self.rail = rail
        activeIndex = selectedIndex(rows: rows, selectedID: selectedID)
    }

    /// After a star toggle, re-home the cursor onto the **selected** row —
    /// deliberately NOT onto the row that was just starred.
    ///
    /// Starring reorders the list, and following the starred row left its cursor
    /// wash beside the selected row's ring: "two highlighted rows" (user report,
    /// twice — `pickers.rs:1480–1485`).
    public mutating func rehomeAfterFavoriteToggle(
        rows: [SupermuxZeronPickerRow],
        selectedID: String?
    ) {
        activeIndex = selectedIndex(rows: rows, selectedID: selectedID)
    }

    /// The selected row's index in the **visible** rows, or 0 when the current
    /// view does not contain it (the favorites and search views may not).
    public func selectedIndex(rows: [SupermuxZeronPickerRow], selectedID: String?) -> Int {
        let visible = visibleRows(from: rows)
        guard let selectedID,
              let index = visible.firstIndex(where: { $0.id == selectedID })
        else { return 0 }
        return index
    }
}

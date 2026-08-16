//
//  SupermuxZeronHoverEntry.swift
//  SupermuxKit
//
//  Per-entry hover tracking, driving the timestamp reveal. Spec 02 §5.1.
//
//  ── Why hover is tracked PER ROW but resolved PER ENTRY ──
//
//  Hovering ANY row of an entry reveals that entry's timestamp. But enter/leave
//  ordering across sibling rows is NOT guaranteed: moving the pointer from row A
//  to row B in the same entry can deliver B's enter before A's leave, and a naive
//  "leave clears the reveal" would blank the strip B just lit.
//
//  zeron's fix (`transcript.rs:2925-2948`) is the one reproduced here: the store
//  holds `(rowID, entryID)`, and **only the row that OWNS the current reveal may
//  clear it**. A stale leave from an earlier row is ignored.
//
//  ── Where this lives ──
//
//  ABOVE the `LazyVStack` boundary. The store is `@Observable`; a row view
//  receives only an already-resolved `Bool` and an `onHover` closure, never the
//  store itself (cmux #2586). Reading `isRevealed(entryID:)` from the host's
//  `body` is a pure read; the writes happen in the `.onHover` callback, which is
//  an event handler, not a `body` call.
//

public import Observation

internal import Foundation

/// Which entry's timestamp is revealed, and which row owns that reveal.
@MainActor
@Observable
public final class SupermuxZeronHoverEntry {
    /// `(rowID, entryID)`, or `nil` when nothing is hovered.
    public private(set) var hovered: (rowID: String, entryID: String)?

    public init() {}

    /// The entry currently revealing its timestamp.
    public var hoveredEntryID: String? { hovered?.entryID }

    /// Whether `entryID`'s timestamp lane should show its label.
    public func isRevealed(entryID: String) -> Bool {
        hovered?.entryID == entryID
    }

    /// The pointer entered `rowID`, which belongs to `entryID`.
    public func enter(rowID: String, entryID: String) {
        guard hovered?.rowID != rowID else { return }
        hovered = (rowID, entryID)
    }

    /// The pointer left `rowID`.
    ///
    /// Ignored unless `rowID` owns the current reveal — see the header.
    public func leave(rowID: String) {
        guard hovered?.rowID == rowID else { return }
        hovered = nil
    }

    /// Clears everything. Used on session switch and when the transcript loses
    /// the window, where no leave event will ever arrive.
    public func clear() {
        hovered = nil
    }
}

public import CmuxMobileShellModel
import SupermuxMobileCore
import SupermuxMobileKit

/// Puts the phone's workspace rows in the order every Mac shares.
///
/// Each Mac writes a ``SupermuxOrderKey`` for the workspaces it owns
/// (`supermux_order_key`); the phone sorts every Mac's rows by it with the
/// same ``SupermuxOrderArrangement`` the Macs use, so all devices agree.
/// Rows from a Mac that predates shared order carry no key and keep today's
/// place: after the keyed rows of their tier, in the order they came in.
///
/// Keys of different instance tags (a Stable and a Nightly build) are
/// unrelated, so each tag's rows form their own block.
///
/// ```swift
/// let rows = SupermuxPhoneWorkspaceOrder().loose(workspaces, groups: groupsByID, mode: workspaceSortMode)
/// ```
public struct SupermuxPhoneWorkspaceOrder: Sendable {
    /// The last part of a segment whose rows move by order key.
    private static let orderedMarker = "ordered"
    /// Joins the parts of a segment id.
    static let segmentSeparator = "\u{1F}"

    /// Creates the order.
    public init() {}

    /// The shell's loose rows (flat or grouped) in the shared order.
    ///
    /// - Parameters:
    ///   - rows: The shell's rows, Mac by Mac, each Mac in its own order.
    ///   - groups: The shell's groups, by id: a row in a group takes the
    ///     group's pin and moves with the group as one block.
    ///   - mode: The list's sort. ``MobileWorkspaceSortMode/automatic``
    ///     interleaves every Mac of one instance tag;
    ///     ``MobileWorkspaceSortMode/computerPriority`` keeps the incoming Mac
    ///     blocks and orders each; ``MobileWorkspaceSortMode/recentActivity``
    ///     is left alone.
    /// - Returns: The rows in the shared order, or `rows` unchanged when no
    ///   row carries a key.
    public func loose(
        _ rows: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview],
        mode: MobileWorkspaceSortMode
    ) -> [MobileWorkspacePreview] {
        guard rows.contains(where: { key(of: $0) != nil }) else { return rows }
        switch mode {
        case .recentActivity:
            return rows
        case .automatic:
            return blocks(of: rows, by: universe).flatMap { arranged($0, groups: groups) }
        case .computerPriority:
            return blocks(of: rows, by: pairing).flatMap { arranged($0, groups: groups) }
        }
    }

    /// Rows nested under one project: the keyed rows in the shared order
    /// (one block per instance tag, pinned rows first in each), then the
    /// unkeyed rows in the order they came in.
    ///
    /// Also the order a cross-Mac nested drag waits for: the owner's answer
    /// comes back in the shell's Mac-by-Mac list, which only this order shows
    /// the move in.
    /// - Parameter rows: The rows in today's order (Mac by Mac, window by
    ///   window, pinned rows first).
    /// - Returns: The same rows, keyed ones first.
    public func nested(_ rows: [MobileWorkspacePreview]) -> [MobileWorkspacePreview] {
        let keyed = rows.filter { key(of: $0) != nil }
        let unkeyed = rows.filter { key(of: $0) == nil }
        return blocks(of: keyed, by: universe).flatMap { arranged($0, groups: nil) } + unkeyed
    }

    /// The segment a keyed nested row is dragged in: one project, one
    /// instance tag, one side of the pinned line, across Macs and windows.
    /// A drop there is sent to the row's owner as a new order key.
    /// - Parameters:
    ///   - project: The merged project's id.
    ///   - row: The nested row.
    /// - Returns: The segment, or `nil` for an unkeyed row, which keeps the
    ///   per-Mac, per-window segment its Mac can apply as a `workspace.move`.
    public func orderedSegment(project: String, row: MobileWorkspacePreview) -> String? {
        guard key(of: row) != nil else { return nil }
        return [project, universe(row), row.isPinned ? "pinned" : "unpinned", Self.orderedMarker]
            .joined(separator: Self.segmentSeparator)
    }

    /// Whether a segment's rows move by order key (``orderedSegment(project:row:)``).
    /// - Parameter segment: A nested row's segment.
    public func isOrdered(segment: String) -> Bool {
        segment.hasSuffix(Self.segmentSeparator + Self.orderedMarker)
    }

    /// The order key for a nested row dropped in an ordered segment: between
    /// the keys of the nearest open rows above and below it in the drop.
    /// - Parameters:
    ///   - move: The drop.
    ///   - rows: The shell's current rows.
    ///   - seed: This phone's origin, used only when no key is known at all.
    /// - Returns: A key; neighbours with equal or out-of-order keys still
    ///   give one right after the row above (``SupermuxOrderKey/mint(after:before:known:seed:)``).
    public func mintKey(for move: SupermuxNestedMove, in rows: [MobileWorkspacePreview], seed: String) -> String {
        let byID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        let keyOf = { (id: MobileWorkspacePreview.ID) in byID[id].flatMap(key(of:)) }
        let position = move.order.firstIndex(of: move.workspaceID) ?? move.order.endIndex
        let lower = move.order[..<position].reversed().lazy.compactMap(keyOf).first
        let upper = move.order[min(position + 1, move.order.endIndex)...].lazy.compactMap(keyOf).first
        let movedUniverse = byID[move.workspaceID].map(universe)
        let known = rows
            .filter { $0.id != move.workspaceID && (movedUniverse == nil || universe($0) == movedUniverse) }
            .compactMap(key(of:))
        return SupermuxOrderKey().mint(after: lower, before: upper, known: known, seed: seed)
    }

    // MARK: Helpers

    /// The row's key when it is a valid order key; a malformed one counts as none.
    private func key(of row: MobileWorkspacePreview) -> String? {
        row.supermuxOrderKey.flatMap { SupermuxOrderKey().isValid($0) ? $0 : nil }
    }

    /// The instance tag whose keys the row's key compares with.
    private func universe(_ row: MobileWorkspacePreview) -> String {
        guard let tag = row.macInstanceTag, !tag.isEmpty else { return "default" }
        return tag
    }

    /// The row's Mac build.
    private func pairing(_ row: MobileWorkspacePreview) -> String {
        SupermuxMacSeam.pairingID(macDeviceID: row.macDeviceID, instanceTag: row.macInstanceTag)
    }

    /// The rows split by `block`, blocks in order of first appearance.
    private func blocks(
        of rows: [MobileWorkspacePreview],
        by block: (MobileWorkspacePreview) -> String
    ) -> [[MobileWorkspacePreview]] {
        var names: [String] = []
        var members: [String: [MobileWorkspacePreview]] = [:]
        for row in rows {
            let name = block(row)
            if members[name] == nil {
                names.append(name)
            }
            members[name, default: []].append(row)
        }
        return names.compactMap { members[$0] }
    }

    /// One block of rows in the shared order, or unchanged when none is keyed.
    /// - Parameter groups: The groups a row moves with, or `nil` when every
    ///   row moves alone (nested rows are never grouped).
    private func arranged(
        _ rows: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]?
    ) -> [MobileWorkspacePreview] {
        guard rows.contains(where: { key(of: $0) != nil }) else { return rows }
        let items = rows.map { row in
            let tier = (row.groupID.flatMap { groups?[$0] }?.isPinned ?? row.isPinned) ? 0 : 1
            let unit = groups != nil && row.groupID != nil
                ? "g:\(row.groupID?.rawValue ?? "")/\(tier)"
                : "w:\(row.id.rawValue)"
            return SupermuxOrderItem(
                id: row.id,
                tier: tier,
                sortKey: key(of: row).map {
                    SupermuxOrderSortKey(key: $0, canonicalID: row.rpcWorkspaceID.rawValue, tieRank: 0)
                },
                unit: unit)
        }
        let byID = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        return SupermuxOrderArrangement().arrange(items).compactMap { byID[$0] }
    }
}

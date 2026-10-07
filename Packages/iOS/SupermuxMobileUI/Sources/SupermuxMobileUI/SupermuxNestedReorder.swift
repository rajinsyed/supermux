public import CmuxMobileShellModel
import Foundation
public import Observation

/// One drag of a workspace nested under a project on the iPhone, as the
/// owning Mac will apply it.
///
/// A nested row moves only inside its segment: the rows of one project on one
/// Mac, in one of that Mac's windows, on one side of the pinned line. That is
/// the run the Mac sidebar shows in the Mac's own tab order, so the new order
/// is exactly one `workspace.move` on that Mac.
public struct SupermuxNestedMove: Equatable, Sendable {
    /// The dragged workspace's row id.
    public let workspaceID: MobileWorkspacePreview.ID
    /// The segment the row moves in (``SupermuxProjectsListLayout/nestedSegments``).
    public let segment: String
    /// The segment's rows, top to bottom, after the drop.
    public let order: [MobileWorkspacePreview.ID]
    /// Whether the drop changes the order (a row dropped on its own place does not).
    public let changesOrder: Bool

    /// Memberwise initializer.
    public init(
        workspaceID: MobileWorkspacePreview.ID,
        segment: String,
        order: [MobileWorkspacePreview.ID],
        changesOrder: Bool
    ) {
        self.workspaceID = workspaceID
        self.segment = segment
        self.order = order
        self.changesOrder = changesOrder
    }
}

/// Pure rules for dragging a nested workspace row.
public enum SupermuxNestedReorderPolicy {
    /// The move a drop makes, or `nil` when the row may not land there.
    /// - Parameters:
    ///   - leadingRun: The table's leading run top to bottom: a nested
    ///     workspace's id, or `nil` for any other row (chrome, project rows).
    ///   - source: The dragged row's index in `leadingRun`.
    ///   - destination: The row's index after the drop (UIKit's insertion index).
    ///   - segments: Each nested workspace's segment.
    public static func move(
        leadingRun: [MobileWorkspacePreview.ID?],
        from source: Int,
        to destination: Int,
        segments: [MobileWorkspacePreview.ID: String]
    ) -> SupermuxNestedMove? {
        nil
    }

    /// The workspace the Mac puts the moved one right before, or `nil` for
    /// the end of its window.
    /// - Parameters:
    ///   - move: The drop.
    ///   - workspaces: The shell's rows in the Macs' own order.
    public static func beforeWorkspaceID(
        for move: SupermuxNestedMove,
        in workspaces: [MobileWorkspacePreview]
    ) -> MobileWorkspacePreview.ID? {
        nil
    }
}

/// The nested rows the phone shows moved before their Mac has answered.
@MainActor
@Observable
public final class SupermuxNestedReorderModel {
    /// The order each segment shows while its move is on the way, by segment.
    public private(set) var orders: [String: [MobileWorkspacePreview.ID]] = [:]

    /// Creates an empty model.
    public init() {}

    /// Shows `move` at once and sends it after every earlier move.
    /// - Parameters:
    ///   - move: The drop.
    ///   - send: Sends the move and returns once the Mac's list was fetched
    ///     again; `false` when the Mac refused it.
    /// - Returns: The task that sends it.
    @discardableResult
    public func perform(
        _ move: SupermuxNestedMove,
        send: @escaping @MainActor () async -> Bool
    ) -> Task<Void, Never> {
        Task {}
    }
}

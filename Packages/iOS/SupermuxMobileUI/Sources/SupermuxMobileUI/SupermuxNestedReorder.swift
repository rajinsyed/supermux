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
        guard leadingRun.indices.contains(source), leadingRun.indices.contains(destination),
              let moved = leadingRun[source], let segment = segments[moved] else { return nil }
        func slots(_ run: [MobileWorkspacePreview.ID?]) -> [Int] {
            run.indices.filter { index in run[index].flatMap { segments[$0] } == segment }
        }
        var run = leadingRun
        run.remove(at: source)
        run.insert(moved, at: destination)
        // A move inside the segment only swaps rows between the slots the
        // segment already holds; landing anywhere else changes those slots.
        guard slots(run) == slots(leadingRun) else { return nil }
        let order = slots(run).compactMap { run[$0] }
        let previous = slots(leadingRun).compactMap { leadingRun[$0] }
        return SupermuxNestedMove(workspaceID: moved, segment: segment, order: order, changesOrder: order != previous)
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
        guard let position = move.order.firstIndex(of: move.workspaceID) else { return nil }
        if position + 1 < move.order.count {
            return move.order[position + 1]
        }
        // Dropped last: right after the row it now follows, which in the
        // Mac's tabs is before the next tab of that window outside the
        // segment (rows of the segment there are placed by this order).
        guard position > 0, let moved = workspaces.first(where: { $0.id == move.workspaceID }) else { return nil }
        let window = workspaces.filter { workspace in
            workspace.macDeviceID == moved.macDeviceID
                && workspace.macInstanceTag == moved.macInstanceTag
                && workspace.windowID == moved.windowID
        }
        let members = Set(move.order)
        guard let after = window.firstIndex(where: { $0.id == move.order[position - 1] }) else { return nil }
        return window[(after + 1)...].first { !members.contains($0.id) }?.id
    }
}

extension SupermuxNestedReorderPolicy {
    /// Whether `workspaces` lists the move's rows in its order.
    public static func listHolds(_ move: SupermuxNestedMove, _ workspaces: [MobileWorkspacePreview]) -> Bool {
        let members = Set(move.order)
        return workspaces.map(\.id).filter(members.contains) == move.order
    }
}

/// The nested rows the phone shows moved before their Mac has answered.
@MainActor
@Observable
public final class SupermuxNestedReorderModel {
    /// The order each segment shows while its move is on the way, by segment.
    public private(set) var orders: [String: [MobileWorkspacePreview.ID]] = [:]

    /// The latest move per segment: only its answer ends the segment's order.
    @ObservationIgnored private var latest: [String: Int] = [:]
    @ObservationIgnored private var moveCount = 0
    /// The last move sent, which the next one waits for.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// Creates an empty model.
    public init() {}

    /// Shows `move` at once and sends it after every earlier move.
    /// - Parameters:
    ///   - move: The drop.
    ///   - send: Sends the move and returns once the Mac's list was fetched
    ///     again; `false` when the Mac refused it.
    /// - Returns: The task that sends it.
    /// Waits until `isDone()` or `timeout` passes, checking every 50 ms.
    public static func wait(upTo timeout: Duration, until isDone: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !isDone(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @discardableResult
    public func perform(
        _ move: SupermuxNestedMove,
        send: @escaping @MainActor () async -> Bool
    ) -> Task<Void, Never> {
        moveCount += 1
        let token = moveCount
        latest[move.segment] = token
        orders[move.segment] = move.order
        let previous = tail
        let task = Task { @MainActor [weak self] in
            await previous?.value
            // Either way the list now holds the Mac's order: the move's own
            // result, or the order it kept after refusing.
            _ = await send()
            guard let self, self.latest[move.segment] == token else { return }
            self.latest[move.segment] = nil
            self.orders[move.segment] = nil
        }
        tail = task
        return task
    }
}

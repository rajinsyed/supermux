public import Foundation
public import SupermuxMobileCore

/// The order the Projects section draws its rows in: this Mac's projects and
/// the projects only other Macs have, interleaved in the shared order every
/// Mac and the phone show.
///
/// Each row sorts by its project's effective stamp (the winner among the
/// project's copies, ``SupermuxRemoteProjectsPresentation/effectiveOrder(of:)``).
/// Rows no Mac has stamped yet follow in today's order: this Mac's projects in
/// their array order, then the remote-only rows.
///
/// ```swift
/// let order = SupermuxProjectsSectionOrder()
/// let items = order.items(locals: model.projects, remotes: remote.rows, stamp: remote.effectiveOrder(of:))
/// let drawn = order.previewed(items, by: dragState.projectOrderPreview?.order)
/// ```
public struct SupermuxProjectsSectionOrder: Sendable {
    /// One row of the Projects section.
    public enum Item: Identifiable {
        /// A project with a copy on this Mac.
        case local(SupermuxProject)
        /// A project only other Macs have.
        case remote(SupermuxRemoteProjectRow)

        /// The row's unified project id: a local project's own id, or a
        /// remote-only project's derived id. The id ``SupermuxProjectsModel/moveProject(_:over:)``
        /// takes.
        public var id: UUID {
            switch self {
            case .local(let project): project.id
            case .remote(let row): row.id
            }
        }

        /// Whether only other Macs have the project.
        public var isRemoteOnly: Bool {
            switch self {
            case .local: false
            case .remote: true
            }
        }
    }

    /// Creates the order.
    public init() {}

    /// The section's rows in the shared order.
    /// - Parameters:
    ///   - locals: This Mac's projects in their array order.
    ///   - remotes: The remote-only rows in their fallback order.
    ///   - stamp: A row's effective stamp, or `nil` while no copy of its
    ///     project is stamped.
    /// - Returns: Stamped rows by stamp, then the unstamped rows: locals
    ///   first, then remotes, each in input order.
    public func items(
        locals: [SupermuxProject],
        remotes: [SupermuxRemoteProjectRow],
        stamp: (Item) -> SupermuxOrderStamp?
    ) -> [Item] {
        let unsorted = locals.map(Item.local) + remotes.map(Item.remote)
        return SupermuxProjectOrder().sorted(unsorted, stamp: stamp)
    }

    /// The rows in a drag's previewed order, while a project drag is in
    /// flight; the rows unchanged otherwise.
    ///
    /// A row added mid-drag is appended, and a previewed id that no longer
    /// has a row drops out.
    /// - Parameters:
    ///   - items: The rows in the shared order.
    ///   - previewOrder: The previewed ids, or `nil` when no drag is previewed.
    /// - Returns: The rows to draw.
    public func previewed(_ items: [Item], by previewOrder: [UUID]?) -> [Item] {
        guard let previewOrder else { return items }
        // `uniquingKeysWith`: the projects file is user-editable JSON, so a
        // hand-edited duplicate id must degrade to ForEach identity warnings,
        // never to a fatalError mid-drag.
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previewed = previewOrder.compactMap { byID[$0] }
        let placed = Set(previewOrder)
        return previewed + items.filter { !placed.contains($0.id) }
    }
}

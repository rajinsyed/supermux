public import SupermuxMobileCore
public import SwiftUI

/// Where a view finds a remote Mac's live route (direct or relay, and where)
/// by its catalog machine id (`device:<uuid>@<tag>`).
///
/// The app installs one that reads its route store
/// (``EnvironmentValues/supermuxLinkRoutes``). A view that calls it in its
/// `body` follows that store itself, so a route update redraws the small view
/// that shows it (the Mac icon, the presets bar's host mark, the Changes
/// strip), never the row or the list around it. The default knows no routes.
///
/// ```swift
/// view.environment(\.supermuxLinkRoutes, SupermuxLinkRouteLookup { id in store.route(forMachineID: id) })
/// ```
public struct SupermuxLinkRouteLookup: Sendable {
    private let lookup: @MainActor @Sendable (String) -> SupermuxLinkRoute?

    /// Creates a lookup.
    /// - Parameter lookup: The route of the Mac with this machine id while its
    ///   link is connected; nil otherwise.
    public init(_ lookup: @escaping @MainActor @Sendable (String) -> SupermuxLinkRoute?) {
        self.lookup = lookup
    }

    /// Knows no routes.
    public static let none = SupermuxLinkRouteLookup { _ in nil }

    /// The route of the Mac with this machine id; nil while it has none.
    @MainActor
    public func route(forMachineID machineID: String) -> SupermuxLinkRoute? {
        lookup(machineID)
    }
}

private struct SupermuxLinkRouteLookupKey: EnvironmentKey {
    static let defaultValue = SupermuxLinkRouteLookup.none
}

extension EnvironmentValues {
    /// Each remote Mac's live route, for the views that show it.
    public var supermuxLinkRoutes: SupermuxLinkRouteLookup {
        get { self[SupermuxLinkRouteLookupKey.self] }
        set { self[SupermuxLinkRouteLookupKey.self] = newValue }
    }
}

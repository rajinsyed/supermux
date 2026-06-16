import Observation
import SupermuxKit

/// The observable state the switcher overlay renders from.
///
/// The controller owns one instance, installs it into the overlay's SwiftUI host
/// once, and then mutates its properties as the user cycles — SwiftUI re-renders
/// reactively. Cards below the strip receive plain value snapshots (the item,
/// which carries its own preview text), not this object, so only the affected
/// cards re-evaluate.
@MainActor
@Observable
final class SupermuxWorkspaceSwitcherViewState {
    /// The frozen, ordered switchable workspaces for the current hold session.
    var items: [SupermuxWorkspaceSwitcherItem] = []
    /// Index of the highlighted card within `items`.
    var selectedIndex: Int = 0

    /// Invoked when a card is clicked (commits to that index).
    @ObservationIgnored var onSelectIndex: (Int) -> Void = { _ in }
    /// Invoked when real pointer movement places the cursor over a card (moves the
    /// highlight there without committing, like the macOS app switcher). Driven by
    /// the same mouse-moved event that proves movement, so it never fires on appear
    /// or while the strip scrolls under a stationary cursor.
    @ObservationIgnored var onPointerOverCard: (Int) -> Void = { _ in }
    /// Invoked when the user clicks outside the strip (cancel).
    @ObservationIgnored var onCancel: () -> Void = {}
}

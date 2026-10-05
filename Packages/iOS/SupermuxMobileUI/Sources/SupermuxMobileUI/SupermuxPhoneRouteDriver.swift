public import SupermuxMobileKit
public import SwiftUI

extension View {
    /// Runs the phone's route model (`SupermuxPhoneRouteModel`, injected at
    /// the app's composition root) whenever the app is active, whatever
    /// screen is shown: each connected Mac's route for the Projects list,
    /// and the fetch of each Mac's direct addresses that the phone's direct
    /// dials need. Attach once, on the shell's root view; a terminal opened
    /// straight from a notification or a restored workspace never shows the
    /// Projects list, and its Mac's addresses must still be fetched.
    ///
    /// - Parameter seams: The shell's per-Mac seams, read in the driver's
    ///   own body so only it re-evaluates when they change.
    @MainActor
    public func supermuxPhoneRoutes(seams: @escaping @MainActor () -> [SupermuxMacSeam]) -> some View {
        background {
            SupermuxPhoneRouteDriver(seams: seams)
        }
    }
}

/// The hidden view whose task runs the route model.
private struct SupermuxPhoneRouteDriver: View {
    let seams: @MainActor () -> [SupermuxMacSeam]
    /// Absent in previews and on the Mac.
    @Environment(SupermuxPhoneRouteModel.self) private var routes: SupermuxPhoneRouteModel?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let macs = seams().filter { $0.status == .connected }.map(SupermuxPhoneRouteMac.init(seam:))
        let key = SupermuxRouteTaskKey(macs: Set(macs.map(\.identity)), isActive: scenePhase == .active)
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: key) {
                guard let routes, key.isActive else { return }
                await routes.run(macs: macs)
            }
    }
}

/// What restarts the route model's sampling: the connected Macs' connections
/// and whether the app is active.
private struct SupermuxRouteTaskKey: Hashable {
    let macs: Set<SupermuxPhoneRouteMac.Identity>
    let isActive: Bool
}

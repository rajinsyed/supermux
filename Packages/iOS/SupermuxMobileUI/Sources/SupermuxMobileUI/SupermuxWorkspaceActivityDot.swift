public import SupermuxMobileCore
public import SwiftUI

/// A compact agent-activity indicator for workspace rows, mirroring the Mac's
/// `SupermuxAgentActivityIndicator` visual language and palette:
///
/// - ``SupermuxWorkspaceActivityDTO/working``: the Mac's amber braille
///   spinner (`⠋⠙⠹…`), ported frame-for-frame so a working agent reads the
///   same on the phone as in the sidebar (m6-f2 row parity).
/// - ``SupermuxWorkspaceActivityDTO/needsInput``: a red dot with a looping
///   "ping" halo — the most attention-grabbing state.
/// - ``SupermuxWorkspaceActivityDTO/ready``: a steady green dot.
/// - `nil` (idle / unknown): renders nothing.
public struct SupermuxWorkspaceActivityDot: View {
    private let activity: SupermuxWorkspaceActivityDTO?
    private let size: CGFloat

    /// Creates the indicator.
    /// - Parameters:
    ///   - activity: The state to render; `nil` renders nothing.
    ///   - size: Diameter of the dot. Defaults to 8.
    public init(activity: SupermuxWorkspaceActivityDTO?, size: CGFloat = 8) {
        self.activity = activity
        self.size = size
    }

    public var body: some View {
        switch activity {
        case .working:
            SupermuxMobileBrailleSpinner(size: size)
                .accessibilityLabel(Self.label(for: .working))
        case .needsInput:
            SupermuxMobilePulsingDot(color: SupermuxMobileActivityPalette.needsInput, size: size)
                .accessibilityLabel(Self.label(for: .needsInput))
        case .ready:
            Circle()
                .fill(SupermuxMobileActivityPalette.ready)
                .frame(width: size, height: size)
                .accessibilityLabel(Self.label(for: .ready))
        case nil:
            EmptyView()
        }
    }

    /// The localized accessibility description of an activity state (same
    /// wording as the Mac indicator's tooltip).
    static func label(for activity: SupermuxWorkspaceActivityDTO) -> String {
        switch activity {
        case .working:
            String(localized: "supermux.activity.working", defaultValue: "Agent working", bundle: .module)
        case .needsInput:
            String(localized: "supermux.activity.needsInput", defaultValue: "Needs your input", bundle: .module)
        case .ready:
            String(localized: "supermux.activity.ready", defaultValue: "Ready for review", bundle: .module)
        }
    }
}

extension View {
    /// Overlays a workspace row with its agent-activity dot (bottom-trailing,
    /// under the row's timestamp column). The fenced call site in the shell's
    /// `WorkspaceListView` passes the raw `supermux_activity` wire value;
    /// `nil` or an unknown spelling overlays nothing.
    /// - Parameter rawActivity: The row's `supermux_activity` raw value.
    public func supermuxWorkspaceActivityDot(rawActivity: String?) -> some View {
        overlay(alignment: .bottomTrailing) {
            SupermuxWorkspaceActivityDot(
                activity: rawActivity.flatMap(SupermuxWorkspaceActivityDTO.init(rawValue:))
            )
            .padding(.trailing, 2)
            .padding(.bottom, 12)
        }
    }
}

/// Shared activity colors, matched to the Mac's `SupermuxActivityPalette`
/// (superset's amber/red/green status palette).
/// lint:allow namespace-enum — color-constant table mirroring the Mac's SupermuxActivityPalette; stateless, nothing to instantiate.
enum SupermuxMobileActivityPalette {
    /// amber-500 — agent working.
    static let working = Color(red: 0.96, green: 0.62, blue: 0.04)
    /// red-500 — needs input.
    static let needsInput = Color(red: 0.94, green: 0.27, blue: 0.27)
    /// green-500 — ready for review.
    static let ready = Color(red: 0.13, green: 0.77, blue: 0.37)
}

/// The Mac's amber braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`), ported from
/// `SupermuxBrailleSpinner` in SupermuxKit so a working agent animates
/// identically on both devices.
///
/// Same CPU-safety posture as the Mac original: the schedule is
/// `.animation(minimumInterval:paused:)` capped at ~12.5fps, it pauses
/// entirely while the scene is not active (a backgrounded phone never
/// redraws), and `TimelineView` confines redraws to this leaf `Text` so a
/// tick never re-evaluates the row or the list.
struct SupermuxMobileBrailleSpinner: View {
    let size: CGFloat

    @Environment(\.scenePhase) private var scenePhase

    private static let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let frameInterval: TimeInterval = 0.08

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: scenePhase != .active)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let index = Int(elapsed / Self.frameInterval) % Self.frames.count
            Text(Self.frames[(index + Self.frames.count) % Self.frames.count])
                .font(.system(size: size * 1.7, weight: .semibold, design: .monospaced))
                .foregroundStyle(SupermuxMobileActivityPalette.working)
        }
        // Reserve the dot's footprint so rows don't shift between states.
        .frame(width: size, height: size)
        .fixedSize()
    }
}

/// A solid dot with a looping "ping" halo behind it (Tailwind `animate-ping`),
/// ported from the Mac's `SupermuxPulsingDot` for the needs-input state.
/// Like the Mac original, the halo is only mounted while the scene is
/// active — a backgrounded phone schedules no animation at all; the solid
/// dot always shows.
struct SupermuxMobilePulsingDot: View {
    let color: Color
    let size: CGFloat

    @Environment(\.scenePhase) private var scenePhase
    @State private var pinging = false

    var body: some View {
        ZStack {
            if scenePhase == .active {
                Circle()
                    .fill(color)
                    .opacity(pinging ? 0 : 0.7)
                    .scaleEffect(pinging ? 2.3 : 1)
                    .onAppear {
                        pinging = false
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            pinging = true
                        }
                    }
                    .onDisappear { pinging = false }
            }
            Circle()
                .fill(color)
        }
        .frame(width: size, height: size)
    }
}

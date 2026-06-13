public import SwiftUI

/// A compact, animated indicator for a workspace's agent activity, shared by
/// the sidebar rows and tabs so every surface speaks the same visual language
/// (mirrors piggycode/superset):
///
/// - ``SupermuxWorkspaceActivity/working``: an amber braille spinner.
/// - ``SupermuxWorkspaceActivity/needsInput``: a red pulsing dot (a "ping" halo
///   behind a solid dot) — the most attention-grabbing state.
/// - ``SupermuxWorkspaceActivity/ready``: a steady green dot.
/// - ``SupermuxWorkspaceActivity/idle``: renders nothing.
public struct SupermuxAgentActivityIndicator: View {
    private let activity: SupermuxWorkspaceActivity
    private let size: CGFloat

    /// Creates an indicator.
    /// - Parameters:
    ///   - activity: The state to render.
    ///   - size: Diameter of the dot (the spinner scales from it). Defaults to 7.
    public init(activity: SupermuxWorkspaceActivity, size: CGFloat = 7) {
        self.activity = activity
        self.size = size
    }

    public var body: some View {
        Group {
            switch activity {
            case .working:
                SupermuxBrailleSpinner(size: size)
            case .needsInput:
                SupermuxPulsingDot(color: SupermuxActivityPalette.needsInput, size: size)
            case .ready:
                SupermuxStatusDot(color: SupermuxActivityPalette.ready, size: size)
            case .idle:
                EmptyView()
            }
        }
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        switch activity {
        case .working:
            return String(localized: "supermux.activity.working", defaultValue: "Agent working")
        case .needsInput:
            return String(localized: "supermux.activity.needsInput", defaultValue: "Needs your input")
        case .ready:
            return String(localized: "supermux.activity.ready", defaultValue: "Ready for review")
        case .idle:
            return ""
        }
    }
}

/// Shared activity colors, tuned to read well on the sidebar's dark chrome and
/// matched to superset's amber/red/green status palette.
enum SupermuxActivityPalette {
    /// amber-500 — agent working.
    static let working = Color(red: 0.96, green: 0.62, blue: 0.04)
    /// red-500 — needs input.
    static let needsInput = Color(red: 0.94, green: 0.27, blue: 0.27)
    /// green-500 — ready for review.
    static let ready = Color(red: 0.13, green: 0.77, blue: 0.37)
}

/// An amber braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) ported from piggycode's
/// `AsciiSpinner`.
///
/// CPU-safety (this is a terminal app where main-thread time is precious):
/// - The schedule is `.animation(minimumInterval:paused:)`, capped at ~12.5fps
///   — it never redraws faster than the frame interval regardless of a 120Hz
///   ProMotion display.
/// - It **pauses entirely when the app is inactive** (`controlActiveState`), so a
///   long-running background agent doesn't burn cycles redrawing an unseen view.
/// - `TimelineView` confines redraws to this leaf subtree (a single `Text`), so a
///   tick never re-evaluates the row, the sidebar list, or any ancestor.
/// - The indicator is only mounted for actively-working rows (call sites gate on
///   `isVisible`) and the sidebar list is lazy, so off-screen rows stop ticking.
struct SupermuxBrailleSpinner: View {
    let size: CGFloat

    @Environment(\.controlActiveState) private var controlActiveState

    private static let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let frameInterval: TimeInterval = 0.08

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: controlActiveState == .inactive)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let index = Int(elapsed / Self.frameInterval) % Self.frames.count
            Text(Self.frames[(index + Self.frames.count) % Self.frames.count])
                .font(.system(size: size * 1.7, weight: .semibold, design: .monospaced))
                .foregroundStyle(SupermuxActivityPalette.working)
        }
        // Reserve the dot's footprint so rows don't shift between states.
        .frame(width: size, height: size)
        .fixedSize()
    }
}

/// A solid dot with a looping "ping" halo behind it (Tailwind `animate-ping`),
/// for the attention-grabbing needs-input state.
///
/// The halo uses a Core Animation `repeatForever` animation (render-server
/// driven, so it costs almost nothing — and Core Animation already stops
/// compositing non-visible windows). As a belt-and-suspenders measure the halo
/// is only mounted while the app is active; when inactive only the solid dot
/// remains, so no animation is scheduled at all. The solid dot always shows.
struct SupermuxPulsingDot: View {
    let color: Color
    let size: CGFloat

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var pinging = false

    var body: some View {
        ZStack {
            if controlActiveState != .inactive {
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

/// A steady, filled status dot.
struct SupermuxStatusDot: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

public import SupermuxMobileCore
public import SwiftUI

/// A compact agent-activity indicator for workspace rows, mirroring the Mac's
/// `SupermuxAgentActivityIndicator` — including WHICH states it draws.
///
/// Only ``SupermuxWorkspaceActivityDTO/working`` renders: the Mac's amber
/// braille spinner (`⠋⠙⠹…`), ported frame-for-frame so a working agent reads
/// the same on the phone as in the sidebar (m6-f2 row parity).
///
/// The needs-input red dot and the ready green dot are deliberately absent.
/// The Mac sidebar dropped them (`SupermuxOpenWorkspaceRowView` draws the
/// working indicator and nothing else) because a column of always-on status
/// dots is noise: every settled workspace showed one, so the signal that
/// actually matters — an agent currently doing work — stopped standing out.
/// One indicator per row, nothing when the agent is settled.
public struct SupermuxWorkspaceActivityDot: View {
    private let activity: SupermuxWorkspaceActivityDTO?
    private let size: CGFloat

    /// Creates the indicator.
    /// - Parameters:
    ///   - activity: The state to render; anything but
    ///     ``SupermuxWorkspaceActivityDTO/working`` renders nothing.
    ///   - size: Diameter of the dot. Defaults to 8.
    public init(activity: SupermuxWorkspaceActivityDTO?, size: CGFloat = 8) {
        self.activity = activity
        self.size = size
    }

    public var body: some View {
        if activity == .working {
            SupermuxMobileBrailleSpinner(size: size)
                .accessibilityLabel(Self.label(for: .working))
        }
    }

    /// The localized accessibility description of an activity state (same
    /// wording as the Mac indicator's tooltip).
    ///
    /// Still covers every state, including the two this view no longer draws.
    /// Callers read it for a row's `accessibilityValue`, and dropping a dot for
    /// being visual noise is not a reason to stop TELLING a VoiceOver user that
    /// an agent needs input — the sighted reading of a quiet row is "nothing
    /// urgent", which only holds if the spoken one says the same.
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

/// Shared activity colors, matched to the Mac's `SupermuxActivityPalette`.
/// Only the working amber remains — the needs-input red and ready green went
/// with the dots they tinted.
/// lint:allow namespace-enum — color-constant table mirroring the Mac's SupermuxActivityPalette; stateless, nothing to instantiate.
enum SupermuxMobileActivityPalette {
    /// amber-500 — agent working.
    static let working = Color(red: 0.96, green: 0.62, blue: 0.04)
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

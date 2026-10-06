import Foundation

/// How long a device mirror holds typing while its link is down
/// (``SupermuxTerminalInputPipeline/replayWindow``), counted in awake time.
///
/// willSleep takes every link down, so a hold that ran on the wall clock ran
/// out while the Mac slept and the first keys after the wake were dropped
/// until the re-attach started (second review #3). The hold sleeps on the
/// suspending clock, does not run out while the Mac is dark (a DarkWake runs
/// the process, and that clock, for 2–35 s at a time), and starts over at a
/// full wake (``restartAfterWake()``, from ``SupermuxSystemPower``), after
/// dropping what was held from before the sleep (`onWake`): a key must not
/// land hours after it was typed.
@MainActor
final class SupermuxMirrorInputHold {
    private struct Running {
        weak var hold: SupermuxMirrorInputHold?
    }

    /// Holds not yet run out or cancelled.
    private static var running: [ObjectIdentifier: Running] = [:]

    private let window: Duration
    private let isDark: @MainActor () -> Bool
    private let onWake: @MainActor () -> Void
    private let onExpired: @MainActor () -> Void
    private var timer: Task<Void, Never>?

    /// - Parameters:
    ///   - window: How long the hold lasts, in awake time.
    ///   - isDark: Whether this Mac is between willSleep and a full wake.
    ///   - onWake: Drops what was held from before the sleep.
    ///   - onExpired: The hold ran out.
    init(
        window: Duration = SupermuxTerminalInputPipeline.replayWindow,
        isDark: @escaping @MainActor () -> Bool = { SupermuxComposition.systemPower.isDark },
        onWake: @escaping @MainActor () -> Void,
        onExpired: @escaping @MainActor () -> Void
    ) {
        self.window = window
        self.isDark = isDark
        self.onWake = onWake
        self.onExpired = onExpired
    }

    /// Starts the hold, a whole window from now.
    func start() {
        Self.running[ObjectIdentifier(self)] = Running(hold: self)
        timer?.cancel()
        timer = Task { [weak self, window] in
            guard (try? await Task.sleep(for: window, tolerance: nil, clock: .suspending)) != nil,
                  let self else { return }
            // A DarkWake ran the clock out: the full wake starts it over.
            guard !self.isDark() else { return }
            self.cancel()
            self.onExpired()
        }
    }

    /// Ends the hold without running out.
    func cancel() {
        timer?.cancel()
        timer = nil
        Self.running[ObjectIdentifier(self)] = nil
    }

    /// A full wake: every hold drops what it held from before the sleep and
    /// runs a whole window from now, so the first keys after the wake wait
    /// for the redial.
    static func restartAfterWake() {
        for hold in running.values.compactMap(\.hold) {
            hold.onWake()
            hold.start()
        }
    }
}

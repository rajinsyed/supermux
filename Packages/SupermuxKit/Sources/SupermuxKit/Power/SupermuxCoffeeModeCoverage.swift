import Foundation

/// Which power source the Mac is currently running on.
///
/// This matters for Coffee Mode because the deep-sleep layer
/// (``SupermuxKeepAwakeLayer/systemSleep``) is AC-only: `powerd` marks
/// `PreventSystemSleep` as `kAssertionTypeNotValidOnBatt`, and `caffeinate(8)`
/// documents `-s` as "valid only when system is running on AC power".
public enum SupermuxPowerSource: String, Sendable, Equatable, CaseIterable {
    case ac
    case battery
    /// Power source could not be read.
    case unknown

    /// Only confirmed AC gets the AC-only layer.
    ///
    /// `.unknown` must NOT opt in: `IOPMAssertionCreateWithName` returns
    /// success and a valid ID even for a layer `powerd` marks
    /// `kAssertionTypeNotValidOnBatt`, so an inert assertion is
    /// indistinguishable from a working one at the call site. Guessing AC on a
    /// battery Mac whose power read failed would therefore report deep-sleep
    /// coverage that does not exist — and a desktop Mac, the other `.unknown`
    /// case, never needs that layer anyway since it has no lid and no battery.
    public var allowsSystemSleepAssertion: Bool {
        self == .ac
    }
}

/// The individual power assertions Coffee Mode holds. Each is requested
/// independently so a partial failure degrades honestly instead of claiming
/// more coverage than the Mac actually has.
public enum SupermuxKeepAwakeLayer: String, Sendable, Equatable, CaseIterable {
    /// `PreventUserIdleSystemSleep` — stops idle system sleep. Valid on battery.
    case idleSystemSleep
    /// `PreventUserIdleDisplaySleep` — stops the display sleeping. Valid on battery.
    case idleDisplaySleep
    /// `PreventSystemSleep` — what `caffeinate -s` holds. The idle assertions
    /// above have "no effect if the system is in Dark Wake" (IOPMLib.h), so
    /// this covers the gap where the Mac dark-wakes mid-agent-run and would
    /// otherwise fall straight back to sleep.
    ///
    /// It does **not** prevent lid-close sleep — see
    /// ``SupermuxCoffeeModeCoverage`` for why. AC only, and deprecated in the
    /// SDK since 10.9 (though `caffeinate -s` and `powerd` still implement it
    /// in shipping macOS), so it is strictly best-effort: if it ever stops
    /// being granted, the two idle layers still hold and the UI says so.
    case systemSleep

    public var assertionTypeName: String {
        switch self {
        case .idleSystemSleep: return "PreventUserIdleSystemSleep"
        case .idleDisplaySleep: return "PreventUserIdleDisplaySleep"
        case .systemSleep: return "PreventSystemSleep"
        }
    }

    /// Layers worth attempting for a given power source. On battery the
    /// AC-only layer is skipped rather than requested and silently ignored, so
    /// `heldLayers` always reflects real coverage.
    public static func requested(for powerSource: SupermuxPowerSource) -> [SupermuxKeepAwakeLayer] {
        powerSource.allowsSystemSleepAssertion
            ? [.idleSystemSleep, .idleDisplaySleep, .systemSleep]
            : [.idleSystemSleep, .idleDisplaySleep]
    }
}

/// What Coffee Mode is actually delivering right now, derived from the layers
/// that were successfully acquired plus the current power source.
///
/// The point of this type is honesty: the tooltip must never promise coverage
/// the Mac does not have. It is pure so the wording is unit-testable without
/// touching IOKit.
///
/// **Lid close is deliberately never claimed.** No unprivileged assertion can
/// prevent clamshell sleep: `powerd`'s `setClamshellSleepState()` counts only
/// assertions carrying `kAssertionLidStateModifier`, and setting the
/// `kIOPMAssertionAppliesOnLidClose` property that sets that bit is gated on
/// the private `com.apple.private.iokit.assertonlidclose` entitlement
/// (`PMAssertions.c`, the `auditTokenHasEntitlement` check). A plain
/// `PreventSystemSleep` assertion is created successfully and still lets the
/// Mac sleep when the lid shuts, so promising otherwise would be a lie that
/// costs the user an overnight agent run.
public struct SupermuxCoffeeModeCoverage: Sendable, Equatable {
    public let isActive: Bool
    public let powerSource: SupermuxPowerSource
    public let heldLayers: Set<SupermuxKeepAwakeLayer>

    public init(
        isActive: Bool,
        powerSource: SupermuxPowerSource,
        heldLayers: Set<SupermuxKeepAwakeLayer>
    ) {
        self.isActive = isActive
        self.powerSource = powerSource
        self.heldLayers = heldLayers
    }

    public static let off = SupermuxCoffeeModeCoverage(
        isActive: false,
        powerSource: .unknown,
        heldLayers: []
    )

    /// True when the Mac will not idle-sleep — the baseline promise of the mode.
    public var keepsSystemAwake: Bool {
        isActive && heldLayers.contains(.idleSystemSleep)
    }

    /// True when the AC-only `PreventSystemSleep` layer is held, which also
    /// covers the dark-wake gap the idle assertions leave open. This is NOT
    /// lid-close coverage — see the type's note.
    public var preventsDarkWakeSleep: Bool {
        isActive && heldLayers.contains(.systemSleep)
    }

    /// Active, but not one assertion was acquired — the mode is on in name
    /// only, and the UI must not present it as working.
    public var isDegraded: Bool {
        isActive && !keepsSystemAwake
    }

    /// Tooltip text. States the lid-close caveat outright rather than glossing
    /// it, because a user who believes the lid is covered loses the agent run
    /// they left the Mac running for.
    public var tooltip: String {
        guard isActive else {
            return String(
                localized: "supermux.coffee.tooltip.off",
                defaultValue: "Coffee Mode — keep this Mac awake for running agents"
            )
        }
        if isDegraded {
            return String(
                localized: "supermux.coffee.tooltip.unavailable",
                defaultValue: "Coffee Mode — unavailable, macOS refused the keep-awake request"
            )
        }
        // One wording for every active state, deliberately. The extra
        // `PreventSystemSleep` layer closes a dark-wake gap the user cannot
        // observe, and `IOPSGetProvidingPowerSourceType` reports AC on internal
        // read failures (Apple's IOPowerSources.c falls back to
        // `CFSTR(kIOPMACPowerKey)` rather than failing), so a per-layer message
        // could confidently describe the wrong thing. Both claims that matter —
        // stays awake while open, still sleeps on lid close — hold either way.
        return String(
            localized: "supermux.coffee.tooltip.on",
            defaultValue: "Coffee Mode on — Mac stays awake while open (closing the lid still sleeps it)"
        )
    }
}

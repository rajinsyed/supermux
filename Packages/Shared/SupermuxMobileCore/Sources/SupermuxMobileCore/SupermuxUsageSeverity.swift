/// Shared coloring thresholds for usage bars and the footer/toolbar gauge.
///
/// Lives in the shared package so the Mac popover and the iOS usage screen
/// bucket the same percent identically — a limit that reads amber on the
/// sidebar must never read green on the phone.
public enum SupermuxUsageSeverity: Sendable, Equatable, Comparable {
    case normal
    case warning
    case critical

    public init(percent: Double) {
        switch percent {
        case ..<70: self = .normal
        case ..<90: self = .warning
        default: self = .critical
        }
    }
}

public import Foundation

/// cswap-style two-unit countdowns for reset times: the two most significant
/// nonzero units, compact ("5d 17h", "4h 39m", "12m"). The system relative
/// formatter rounds to a single coarse unit ("in 6 days"), which reads
/// imprecise next to a percent that moves hourly.
///
/// Shared between the Mac popover and the iOS usage screen so both spell a
/// reset the same way.
/// lint:allow namespace-enum — pure shared formatting policy with no runtime dependency.
public enum SupermuxUsageCountdown {
    /// Formats the remaining time from `now` to `date`. `date` must be in the
    /// future (callers gate on it); a past/now date yields "0m".
    public static func text(until date: Date, now: Date = Date()) -> String {
        let remaining = max(0, date.timeIntervalSince(now))
        let totalMinutes = Int((remaining / 60).rounded(.up))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}

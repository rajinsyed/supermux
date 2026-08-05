import Foundation

/// Validates provider-reported utilization at the parsing boundary.
///
/// A missing/null percentage must NOT become 0: the tracker's whole job is
/// distinguishing "no quota used" from "we don't know", and a fabricated 0
/// reads as fresh quota in both the bar row and the footer gauge.
enum SupermuxUsagePercent {
    /// `nil` when the provider reported no usable number (absent, null,
    /// non-finite, or negative). Values above 100 are real ("over quota")
    /// and clamp to 100 so severity stays `.critical`.
    static func normalized(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return min(100, raw)
    }
}

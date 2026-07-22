import Foundation

/// Returns one stable lowercase spelling for a UUID device identifier.
///
/// Device identifiers outside the UUID grammar are opaque protocol values and
/// are returned byte-for-byte, including their original case and whitespace.
// SUPERMUX:begin lint-allow-upstream-debt
// SUPERMUX:end lint-allow-upstream-debt (lint:allow free-function — upstream debt at the 0.64.20 merge; conventions gate runs only on the fork while upstream CI is paused)
public func cmxCanonicalDeviceID(_ deviceID: String) -> String {
    guard let uuid = UUID(uuidString: deviceID) else { return deviceID }
    return uuid.uuidString.lowercased()
}

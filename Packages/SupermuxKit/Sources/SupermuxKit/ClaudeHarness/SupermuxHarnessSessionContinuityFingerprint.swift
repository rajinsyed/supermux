import Foundation

/// A digest covering every byte of the previously indexed prefix.
struct SupermuxHarnessSessionContinuityFingerprint: Sendable {
    let observedSize: UInt64
    let digest: Data

    var byteCost: Int {
        32 + digest.count
    }
}

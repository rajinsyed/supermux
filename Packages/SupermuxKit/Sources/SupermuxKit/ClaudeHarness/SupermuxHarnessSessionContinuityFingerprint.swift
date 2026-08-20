import Foundation

/// Exact bounded samples from the previously indexed prefix.
struct SupermuxHarnessSessionContinuityFingerprint: Sendable {
    struct Sample: Sendable {
        let offset: UInt64
        let bytes: Data
    }

    let observedSize: UInt64
    let samples: [Sample]

    var byteCost: Int {
        32 + samples.reduce(0) { $0 + $1.bytes.count + 24 }
    }
}

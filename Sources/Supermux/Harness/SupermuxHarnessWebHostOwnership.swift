import Foundation

/// Generation seam for one retained renderer moving among transient NSView hosts.
@MainActor
final class SupermuxHarnessWebHostOwnership {
    private(set) var latestIssuedGeneration: UInt64 = 0
    private(set) weak var owner: AnyObject?
    private(set) var ownerGeneration: UInt64 = 0

    func issueGeneration() -> UInt64 {
        latestIssuedGeneration &+= 1
        return latestIssuedGeneration
    }

    func claim(_ candidate: AnyObject, generation: UInt64) -> Bool {
        owner = candidate
        ownerGeneration = generation
        return true
    }

    func release(_ candidate: AnyObject, generation: UInt64) -> Bool {
        guard owner === candidate else { return false }
        owner = nil
        ownerGeneration = 0
        return true
    }
}

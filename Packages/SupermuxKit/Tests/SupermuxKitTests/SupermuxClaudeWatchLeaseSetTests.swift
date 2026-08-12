import Foundation
@testable import SupermuxKit
import Testing

@Suite("Claude mobile watcher leases")
struct SupermuxClaudeWatchLeaseSetTests {
    @Test("holders renew independently and the last release disables the watch")
    func holderRefcounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        var leases = SupermuxClaudeWatchLeaseSet()

        let firstExpiration = leases.renew(clientID: "phone-a", now: now)
        _ = leases.renew(clientID: "phone-b", now: now)
        #expect(firstExpiration == now.addingTimeInterval(120))
        #expect(leases.isActive)

        leases.release(clientID: "phone-a")
        #expect(leases.isActive)
        leases.release(clientID: "phone-b")
        #expect(!leases.isActive)
    }

    @Test("heartbeat renewal survives the older holder deadline")
    func heartbeatAndExpiry() {
        let start = Date(timeIntervalSince1970: 2_000)
        var leases = SupermuxClaudeWatchLeaseSet()
        _ = leases.renew(clientID: "phone", now: start)
        _ = leases.renew(clientID: "phone", now: start.addingTimeInterval(60))

        leases.sweep(now: start.addingTimeInterval(121))
        #expect(leases.isActive)
        leases.sweep(now: start.addingTimeInterval(181))
        #expect(!leases.isActive)
    }
}

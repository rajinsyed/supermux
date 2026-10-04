import CMUXMobileCore
import Foundation

extension LivenessHostRouter {
    // SUPERMUX:begin mobile-startup-parallel-secondary
    static func attachTicketObject(
        macDeviceID: String = "test-mac",
        macDisplayName: String = "Test Mac",
        port: Int = 56584
    ) throws -> Any {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "live-workspace",
            terminalID: "live-terminal",
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName,
    // SUPERMUX:end mobile-startup-parallel-secondary
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: Date().addingTimeInterval(3600)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(ticket))
    }
}

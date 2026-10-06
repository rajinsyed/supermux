import Foundation
import Testing

@testable import CmuxIrxTransport

@Suite struct IrxJournalTests {
    @Test func endpointIDsAreRedactedBeforeRetentionAndRendering() throws {
        let endpoint = V2IdentityKey().endpointID
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("irx-private-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "privacy", journalFileURL: file)
        journal.record("endpoint", "bound", ["endpoint_id": endpoint, "error": "peer \(endpoint) closed", "generation": "3"])
        let event = try #require(journal.tail().first)
        #expect(!event.attributes.values.contains { $0.contains(endpoint) })
        #expect(!IrxJournal.render(event).contains(endpoint))
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(endpoint))
        #expect(event.attributes["generation"] == "3")
        let external = IrxJournalEvent(wallTime: Date(), monotonicMs: 0, component: "endpoint", event: "bound",
            attributes: ["endpoint_id": endpoint.uppercased()])
        #expect(!IrxJournal.render(external).contains(endpoint.uppercased()))
    }

    @Test func terminalTraceEventsAreRateLimitedBeforeRetention() {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "terminal-trace")

        for index in 0...120 {
            journal.record(
                "terminal-trace",
                "phase-\(index)",
                ["trace_id": "0000000000000001"]
            )
        }

        #expect(journal.tail(200).count == 120)
        #expect(journal.counterSnapshot()["terminal_trace_dropped"] == 1)
    }

    // SUPERMUX:begin irx-journal-link-history
    // MARK: - The link history `cmux iroh-diag` shows
    //
    // Failure modes, listed before the code:
    // 1. A flood of keepalive pongs, engine states and terminal traces evicts
    //    the route and reconnect events the report must show (the shared ring
    //    holds about half an hour of them).
    // 2. A route, device-link, power or connection event never reaches it.
    // 3. A chatty component (keepalive, engine, terminal-trace, control-plane)
    //    enters it and evicts it itself.
    // 4. It grows without bound.
    // 5. An endpoint key reaches it unredacted.
    // 6. It is not oldest first, or `count` does not take the newest.

    @Test func linkEventsSurviveAFloodOfChattyEvents() {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "link-history")
        journal.record("route", "changed", ["kind": "relay", "relay_id": "apne1", "rtt_ms": "241"])
        journal.record("device-link", "connected", ["device": "8f6d9357"])
        journal.record("power", "will-sleep", [:])
        journal.record("connection", "closed-locally", ["reason": "idle"])
        for index in 0..<(IrxJournal.ringCapacity * 4) {
            journal.record("keepalive", "pong", ["rtt_ms": String(index % 9)])
            journal.record("engine", "state", ["state": "ready"])
            journal.record("control-plane", "pong-sent", [:])
        }
        for index in 0..<100 {
            journal.record("terminal-trace", "host_received", ["trace_id": String(index)])
        }
        #expect(!journal.tail(IrxJournal.ringCapacity).contains { $0.component == "route" })
        let history = journal.supermuxLinkHistory()
        #expect(history.map(\.component) == ["route", "device-link", "power", "connection"])
        #expect(history.first?.attributes["relay_id"] == "apne1")
    }

    @Test func linkHistoryIsBoundedOldestFirstAndRedacted() throws {
        let journal = IrxJournal(subsystem: "dev.cmux.tests", category: "link-history")
        let endpoint = V2IdentityKey().endpointID
        let total = IrxJournal.supermuxLinkHistoryCapacity + 10
        for index in 0..<total {
            journal.record("route", "changed", ["seq": String(index), "peer": endpoint])
        }
        let history = journal.supermuxLinkHistory()
        #expect(history.count == IrxJournal.supermuxLinkHistoryCapacity)
        #expect(history.first?.attributes["seq"] == "10")
        #expect(history.last?.attributes["seq"] == String(total - 1))
        #expect(!history.contains { $0.attributes.values.contains { $0.contains(endpoint) } })
        let newest = journal.supermuxLinkHistory(3)
        #expect(newest.map { $0.attributes["seq"] } == [String(total - 3), String(total - 2), String(total - 1)])
    }
    // SUPERMUX:end irx-journal-link-history
}

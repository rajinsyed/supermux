import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized)
struct SupermuxHarnessSessionRepositoryConcurrencyTests {
    @Test func concurrentRequestsForOneCanonicalPathCoalesceIntoOnePhysicalScan() async throws {
        let gate = SupermuxHarnessSessionRepositoryScanGate()
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "coalesce",
            scanObserver: { _ in await gate.arriveAndWait() }
        )
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "ai-title", "aiTitle": "Coalesced"],
        ])

        async let first = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        await gate.waitForArrivals(1)
        async let second = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        let didCoalesce = await SupermuxHarnessSessionRepositorySandbox.waitUntil {
            await sandbox.repository.debugMetrics(for: fileURL).coalescedRequestCount == 1
        }
        await gate.release()

        #expect(didCoalesce)
        #expect(await first == "Coalesced")
        #expect(await second == "Coalesced")
        let metrics = await sandbox.repository.debugMetrics(for: fileURL)
        #expect(metrics.scanCount == 1)
        #expect(metrics.coalescedRequestCount == 1)
        #expect(await gate.arrivalCount() == 1)
    }

    @Test func fileChangeDuringScanMarksDirtyAndRerunsBeforeCompletingWaiters() async throws {
        let gate = SupermuxHarnessSessionRepositoryScanGate()
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "dirty-rerun",
            scanObserver: { _ in await gate.arriveAndWait() }
        )
        defer { sandbox.remove() }
        let fileURL = try sandbox.writeSession(id: "session", records: [
            ["type": "ai-title", "aiTitle": "Old title"],
        ])

        async let olderRequest = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        await gate.waitForArrivals(1)
        try sandbox.append(
            SupermuxHarnessSessionRepositorySandbox.jsonLine([
                "type": "ai-title",
                "aiTitle": "Newest title",
            ]),
            to: fileURL
        )
        async let newerRequest = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "session"
        )
        let didMarkDirty = await SupermuxHarnessSessionRepositorySandbox.waitUntil {
            let metrics = await sandbox.repository.debugMetrics(for: fileURL)
            return metrics.coalescedRequestCount == 1 && metrics.dirtyRerunRequestCount == 1
        }
        await gate.release()

        #expect(didMarkDirty)
        #expect(await olderRequest == "Newest title")
        #expect(await newerRequest == "Newest title")
        let metrics = await sandbox.repository.debugMetrics(for: fileURL)
        #expect(metrics.scanCount == 2)
        #expect(metrics.coalescedRequestCount == 1)
        #expect(metrics.dirtyRerunRequestCount == 1)
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let finalSize = try #require((finalAttributes[.size] as? NSNumber)?.uint64Value)
        #expect(metrics.indexBytesRead == finalSize)
    }

    @Test func independentCanonicalPathsMayScanConcurrently() async throws {
        let gate = SupermuxHarnessSessionRepositoryScanGate()
        let sandbox = try SupermuxHarnessSessionRepositorySandbox(
            name: "parallel-files",
            scanObserver: { _ in await gate.arriveAndWait() }
        )
        defer { sandbox.remove() }
        _ = try sandbox.writeSession(id: "one", records: [
            ["type": "ai-title", "aiTitle": "One"],
        ])
        _ = try sandbox.writeSession(id: "two", records: [
            ["type": "ai-title", "aiTitle": "Two"],
        ])

        async let one = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "one"
        )
        async let two = sandbox.repository.sessionTitle(
            for: sandbox.workingDirectoryURL,
            sessionID: "two"
        )
        await gate.waitForArrivals(2)
        #expect(await gate.maximumConcurrentWaitingScans() == 2)
        await gate.release()

        #expect(await one == "One")
        #expect(await two == "Two")
    }
}

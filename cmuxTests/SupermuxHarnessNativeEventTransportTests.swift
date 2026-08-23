import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SupermuxHarnessNativeEventTransportTests {
    private final class Host {}

    @Test
    func eventRemainsBackloggedUntilMatchingAcknowledgement() throws {
        let transport = makeTransport()
        #expect(transport.enqueue(event(id: "first")) == .accepted)

        let envelope = try #require(transport.nextEnvelope())
        #expect(envelope.firstSequence == 1)
        #expect(envelope.highestSequence == 1)
        #expect(transport.pendingEventCount == 1)
        #expect(transport.hasInFlightEnvelope)

        let stale = try acknowledgement(epoch: "stale-document", highestSequence: 1)
        #expect(!transport.acknowledge(stale))
        #expect(transport.pendingEventCount == 1)

        let matching = try acknowledgement(
            epoch: envelope.documentEpoch,
            highestSequence: envelope.highestSequence
        )
        #expect(transport.acknowledge(matching))
        #expect(transport.pendingEventCount == 0)
        #expect(!transport.hasInFlightEnvelope)
    }

    @Test
    func failedDeliveryRetriesTheIdenticalEnvelope() throws {
        let transport = makeTransport()
        #expect(transport.enqueue(event(id: "retry")) == .accepted)
        let firstAttempt = try #require(transport.nextEnvelope())

        transport.deliveryFailed()

        let retry = try #require(transport.nextEnvelope())
        #expect(retry.documentEpoch == firstAttempt.documentEpoch)
        #expect(retry.firstSequence == firstAttempt.firstSequence)
        #expect(retry.highestSequence == firstAttempt.highestSequence)
        #expect(retry.events.count == 1)
        #expect(retry.events.first?["id"] as? String == "retry")
    }

    @Test
    func staleAcknowledgementsCannotDeleteNewerEvents() throws {
        let transport = makeTransport(maximumEventCountPerBatch: 1)
        #expect(transport.enqueue(event(id: "first")) == .accepted)
        #expect(transport.enqueue(event(id: "second")) == .accepted)
        let first = try #require(transport.nextEnvelope())

        let future = try acknowledgement(
            epoch: first.documentEpoch,
            highestSequence: first.highestSequence + 1
        )
        #expect(!transport.acknowledge(future))
        #expect(transport.pendingEventCount == 2)

        let matching = try acknowledgement(
            epoch: first.documentEpoch,
            highestSequence: first.highestSequence
        )
        #expect(transport.acknowledge(matching))
        let second = try #require(transport.nextEnvelope())
        #expect(second.firstSequence == 2)
        #expect(second.highestSequence == 2)
        #expect(second.events.first?["id"] as? String == "second")
    }

    @Test
    func navigationRequeuesInFlightEventsInOriginalOrderWithFreshSequences() throws {
        var epochs = ["document-one", "document-two"].makeIterator()
        let transport = SupermuxHarnessNativeEventTransport(
            configuration: configuration(maximumEventCountPerBatch: 1),
            epochGenerator: { epochs.next() ?? "unexpected-document" }
        )
        #expect(transport.enqueue(event(id: "first")) == .accepted)
        #expect(transport.enqueue(event(id: "second")) == .accepted)
        let oldEnvelope = try #require(transport.nextEnvelope())
        #expect(oldEnvelope.events.first?["id"] as? String == "first")

        let nextEpoch = transport.beginDocumentNavigation()

        #expect(nextEpoch == "document-two")
        let replay = try #require(transport.nextEnvelope())
        #expect(replay.documentEpoch == "document-two")
        #expect(replay.firstSequence == 1)
        #expect(replay.highestSequence == 1)
        #expect(replay.events.first?["id"] as? String == "first")
        #expect(transport.pendingEventCount == 2)
    }

    @Test
    func batchRespectsCountAndEncodedByteLimits() throws {
        let epoch = "document-one"
        let firstEvent = event(id: "first", payload: String(repeating: "a", count: 80))
        let secondEvent = event(id: "other", payload: String(repeating: "b", count: 80))
        let singleEventBytes = try #require(
            SupermuxHarnessNativeEventEnvelope(
                documentEpoch: epoch,
                firstSequence: 1,
                highestSequence: 1,
                events: [firstEvent]
            ).encodedData?.count
        )
        let transport = SupermuxHarnessNativeEventTransport(
            configuration: configuration(
                maximumEventCountPerBatch: 8,
                maximumEncodedBatchBytes: singleEventBytes
            ),
            epochGenerator: { epoch }
        )
        #expect(transport.enqueue(firstEvent) == .accepted)
        #expect(transport.enqueue(secondEvent) == .accepted)

        let envelope = try #require(transport.nextEnvelope())
        let encoded = try #require(envelope.encodedData)
        #expect(envelope.events.count == 1)
        #expect(encoded.count <= singleEventBytes)
    }

    @Test
    func backlogBudgetIncludesTheInFlightEnvelopeAndRejectsOverflow() throws {
        let firstEvent = event(id: "first", payload: String(repeating: "a", count: 48))
        let encodedEventBytes = try JSONSerialization.data(
            withJSONObject: firstEvent,
            options: [.sortedKeys]
        ).count
        let transport = SupermuxHarnessNativeEventTransport(
            configuration: configuration(maximumBacklogBytes: encodedEventBytes),
            epochGenerator: { "document-one" }
        )
        #expect(transport.enqueue(firstEvent) == .accepted)
        _ = try #require(transport.nextEnvelope())

        #expect(transport.backlogByteCount == encodedEventBytes)
        #expect(transport.enqueue(event(id: "overflow")) == .recoveryRequired)
        #expect(transport.pendingEventCount == 1)
    }

    @Test
    func permanentlyOversizedEventIsNotReportedAsRecoverableBackpressure() {
        let transport = SupermuxHarnessNativeEventTransport(
            configuration: configuration(
                maximumEncodedBatchBytes: 128,
                maximumBacklogBytes: 1024 * 1024
            ),
            epochGenerator: { "document-one" }
        )

        #expect(
            transport.enqueue(event(id: "oversized", payload: String(repeating: "x", count: 512)))
                != .recoveryRequired
        )
        #expect(transport.pendingEventCount == 0)
    }

    @Test
    func newestHostGenerationCannotBeStolenOrReleasedByAStaleHost() {
        let ownership = SupermuxHarnessWebHostOwnership()
        let staleHost = Host()
        let newestHost = Host()
        let staleGeneration = ownership.issueGeneration()
        let newestGeneration = ownership.issueGeneration()

        #expect(ownership.claim(newestHost, generation: newestGeneration))
        #expect(!ownership.claim(staleHost, generation: staleGeneration))
        #expect(ownership.owner === newestHost)
        #expect(ownership.ownerGeneration == newestGeneration)

        #expect(!ownership.release(newestHost, generation: staleGeneration))
        #expect(ownership.owner === newestHost)
        #expect(ownership.release(newestHost, generation: newestGeneration))
        #expect(ownership.owner == nil)

        let churnOwnership = SupermuxHarnessWebHostOwnership()
        let attachedHost = Host()
        let attachedGeneration = churnOwnership.issueGeneration()
        #expect(churnOwnership.claim(attachedHost, generation: attachedGeneration))
        _ = churnOwnership.issueGeneration()
        #expect(!churnOwnership.release(attachedHost, generation: attachedGeneration))
        #expect(churnOwnership.owner === attachedHost)
    }

#if canImport(cmux_DEV) || canImport(cmux)
    @Test
    func retainedShellAllowsFragmentsButRejectsDocumentReplacementAfterFinish() throws {
        let shell = URL(fileURLWithPath: "/tmp/supermux-harness/index.html")
        let fragment = try #require(URL(string: "\(shell.absoluteString)#turn-1"))
        let external = try #require(URL(string: "https://example.com"))

        #expect(SupermuxHarnessWebRendererCoordinator.shouldAllowShellNavigation(
            fragment,
            currentURL: shell,
            expected: shell,
            hasFinishedNavigation: true
        ) == true)
        #expect(SupermuxHarnessWebRendererCoordinator.shouldAllowShellNavigation(
            shell,
            currentURL: shell,
            expected: shell,
            hasFinishedNavigation: true
        ) == false)
        #expect(SupermuxHarnessWebRendererCoordinator.shouldAllowShellNavigation(
            shell,
            currentURL: nil,
            expected: shell,
            hasFinishedNavigation: false
        ) == true)
        #expect(SupermuxHarnessWebRendererCoordinator.shouldAllowShellNavigation(
            external,
            currentURL: shell,
            expected: shell,
            hasFinishedNavigation: true
        ) == nil)
    }
#endif

    private func makeTransport(
        maximumEventCountPerBatch: Int = 64
    ) -> SupermuxHarnessNativeEventTransport {
        SupermuxHarnessNativeEventTransport(
            configuration: configuration(maximumEventCountPerBatch: maximumEventCountPerBatch),
            epochGenerator: { "document-one" }
        )
    }

    private func configuration(
        maximumEventCountPerBatch: Int = 64,
        maximumEncodedBatchBytes: Int = 256 * 1024,
        maximumBacklogBytes: Int = 8 * 1024 * 1024
    ) -> SupermuxHarnessNativeEventTransportConfiguration {
        SupermuxHarnessNativeEventTransportConfiguration(
            maximumEventCountPerBatch: maximumEventCountPerBatch,
            maximumEncodedBatchBytes: maximumEncodedBatchBytes,
            maximumBacklogBytes: maximumBacklogBytes
        )
    }

    private func event(id: String, payload: String = "") -> [String: Any] {
        ["kind": "test", "id": id, "payload": payload]
    }

    private func acknowledgement(
        epoch: String,
        highestSequence: UInt64
    ) throws -> SupermuxHarnessNativeEventAcknowledgement {
        try #require(SupermuxHarnessNativeEventAcknowledgement(body: [
            "version": SupermuxHarnessNativeEventEnvelope.currentVersion,
            "documentEpoch": epoch,
            "highestSequence": highestSequence,
        ]))
    }
}

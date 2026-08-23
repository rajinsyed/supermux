public import Foundation

/// Starts a short-lived Claude process, performs only initialize, and returns its account catalog.
@MainActor
public final class SupermuxHarnessModelCatalogProbe {
    private enum ProbeEvent: Sendable {
        case protocolLine(SupermuxHarnessDecodedLine)
        case lifecycle(SupermuxHarnessProcessLifecycleEvent)
        case timeout
    }

    private let timeout: TimeInterval
    private let terminationTimeout: TimeInterval

    /// Creates a short-lived model catalog probe.
    ///
    /// - Parameters:
    ///   - timeout: Seconds allowed for the initialize response. Production uses 15 seconds.
    ///   - terminationTimeout: Seconds allowed for graceful cleanup before hard kill.
    public init(timeout: TimeInterval = 15, terminationTimeout: TimeInterval = 2) {
        self.timeout = max(0, timeout)
        self.terminationTimeout = max(0, terminationTimeout)
    }

    /// Spawns the supplied launch plan, sends initialize, and terminates without a model request.
    ///
    /// - Parameter plan: A normal Claude stream-json launch plan.
    /// - Returns: The account-specific initialize catalog.
    /// - Throws: A process, encoding, writing, cancellation, or probe lifecycle error.
    public func probe(plan: SupermuxHarnessLaunchPlan) async throws -> SupermuxHarnessInitializeCatalog {
        let streamPair = AsyncStream.makeStream(
            of: ProbeEvent.self,
            bufferingPolicy: .unbounded
        )
        let session = SupermuxHarnessProcessSession(
            protocolLineSink: { line in
                streamPair.continuation.yield(.protocolLine(line))
            },
            stderrSink: { _ in },
            lifecycleSink: { event in
                streamPair.continuation.yield(.lifecycle(event))
            }
        )
        let started = try session.start(plan: plan)
        let requestID = UUID().uuidString
        let timeoutTask = Task { [timeout] in
            let nanoseconds = Int64(timeout * 1_000_000_000)
            try? await ContinuousClock().sleep(for: .nanoseconds(nanoseconds))
            guard !Task.isCancelled else { return }
            streamPair.continuation.yield(.timeout)
        }

        do {
            let initialize = try SupermuxHarnessProtocolEncoder()
                .initializeControlRequest(requestID: requestID)
            try await session.send(initialize, forRunID: started.runID)
            for await event in streamPair.stream {
                try Task.checkCancellation()
                switch event {
                case .protocolLine(let line):
                    guard case .controlResponse(let response)? = line.frame,
                          response.requestID == requestID else {
                        continue
                    }
                    switch response.subtype {
                    case .success:
                        let payload: SupermuxHarnessJSONObject
                        if let responsePayload = response.response {
                            payload = responsePayload
                        } else {
                            payload = try SupermuxHarnessJSONObject(rawValue: [:])
                        }
                        let catalog = SupermuxHarnessInitializeCatalog(response: payload)
                        timeoutTask.cancel()
                        streamPair.continuation.finish()
                        await terminateForCleanup(session)
                        return catalog
                    case .error:
                        let message = response.response?.string(forKey: "error")
                            ?? response.rawObject.object(forKey: "response")?.string(forKey: "error")
                        throw SupermuxHarnessModelCatalogProbeError.initializeFailed(message)
                    }
                case .lifecycle(.started):
                    continue
                case .lifecycle(.exited(let runID, let status)):
                    guard runID == started.runID else { continue }
                    throw SupermuxHarnessModelCatalogProbeError.processExited(status)
                case .timeout:
                    throw SupermuxHarnessModelCatalogProbeError.timedOut
                }
            }
            try Task.checkCancellation()
            throw SupermuxHarnessModelCatalogProbeError.incomplete
        } catch {
            timeoutTask.cancel()
            streamPair.continuation.finish()
            await terminateForCleanup(session)
            throw error
        }
    }

    private func terminateForCleanup(_ session: SupermuxHarnessProcessSession) async {
        guard session.isRunning else { return }
        _ = try? await session.terminateAndWait(timeout: terminationTimeout)
    }
}

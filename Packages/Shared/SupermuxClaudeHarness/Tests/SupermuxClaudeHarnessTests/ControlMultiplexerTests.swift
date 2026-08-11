import Foundation
import Testing
@testable import SupermuxClaudeHarness

/// Multiplexer behavior: correlation, out-of-order, duplicate, late, timeout,
/// exit-fails-all, and exactly-once resumption.
struct ControlMultiplexerTests {
    /// Collects written lines and exposes their request IDs.
    private actor WrittenLines {
        var lines: [ClaudeJSONValue] = []

        func append(_ data: Data) throws {
            lines.append(try JSONDecoder().decode(ClaudeJSONValue.self, from: data))
        }

        func requestID(at index: Int) -> String? {
            guard lines.indices.contains(index) else { return nil }
            return lines[index]["request_id"]?.stringValue
        }

        func waitForCount(_ count: Int) async {
            while lines.count < count {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func response(
        requestID: String,
        payload: ClaudeJSONValue? = nil,
        subtype: String = "success"
    ) -> ClaudeStreamLine {
        var inner: [String: ClaudeJSONValue] = [
            "subtype": .string(subtype),
            "request_id": .string(requestID),
        ]
        if let payload { inner["response"] = payload }
        let object: [String: ClaudeJSONValue] = [
            "type": .string("control_response"),
            "response": .object(inner),
        ]
        return ClaudeStreamLine.decode(.object(object))
    }

    private func makeMultiplexer(
        timeouts: ClaudeControlMultiplexer.Timeouts = .init(),
        diagnostics: (@Sendable (ClaudeHarnessDiagnostic) -> Void)? = nil
    ) -> (ClaudeControlMultiplexer, WrittenLines) {
        let written = WrittenLines()
        let multiplexer = ClaudeControlMultiplexer(
            requestPrefix: "smx-test",
            timeouts: timeouts,
            writeLine: { data in try await written.append(data) },
            diagnostic: diagnostics ?? { _ in }
        )
        return (multiplexer, written)
    }

    @Test func roundTripResolvesPendingRequest() async throws {
        let (multiplexer, written) = makeMultiplexer()
        async let sending = multiplexer.send(.listModels)
        await written.waitForCount(1)
        let requestID = try #require(await written.requestID(at: 0))
        await multiplexer.handleLine(response(
            requestID: requestID,
            payload: .object(["models": .array([])])
        ))
        let envelope = try await sending
        #expect(envelope.isSuccess)
        #expect(envelope.payload?["models"]?.arrayValue?.isEmpty == true)
        #expect(await multiplexer.pendingCount == 0)
    }

    @Test func outOfOrderResponsesResolveTheRightRequests() async throws {
        let (multiplexer, written) = makeMultiplexer()
        async let first = multiplexer.send(.setModel("a"))
        await written.waitForCount(1)
        async let second = multiplexer.send(.setModel("b"))
        await written.waitForCount(2)
        let id1 = try #require(await written.requestID(at: 0))
        let id2 = try #require(await written.requestID(at: 1))
        #expect(id1 != id2)

        // Answer the second request first.
        await multiplexer.handleLine(response(requestID: id2, payload: .object(["k": .string("2")])))
        await multiplexer.handleLine(response(requestID: id1, payload: .object(["k": .string("1")])))
        let e1 = try await first
        let e2 = try await second
        #expect(e1.payload?["k"]?.stringValue == "1")
        #expect(e2.payload?["k"]?.stringValue == "2")
    }

    @Test func duplicateResponseIsIgnoredAndDiagnosed() async throws {
        let diagnostics = Diagnostics()
        let (multiplexer, written) = makeMultiplexer(diagnostics: { diagnostics.record($0) })
        async let sending = multiplexer.send(.interrupt)
        await written.waitForCount(1)
        let requestID = try #require(await written.requestID(at: 0))
        let consumed1 = await multiplexer.handleLine(response(requestID: requestID))
        let consumed2 = await multiplexer.handleLine(response(requestID: requestID))
        _ = try await sending
        #expect(consumed1)
        #expect(!consumed2)
        #expect(diagnostics.snapshot().contains { diagnostic in
            if case .unmatchedControlResponse(let id) = diagnostic { return id == requestID }
            return false
        })
    }

    @Test func lateAndUnknownResponsesAreDiagnosed() async {
        let diagnostics = Diagnostics()
        let (multiplexer, _) = makeMultiplexer(diagnostics: { diagnostics.record($0) })
        let consumed = await multiplexer.handleLine(response(requestID: "never-sent"))
        #expect(!consumed)
        #expect(diagnostics.snapshot().count == 1)
    }

    @Test func timeoutFailsTheRequest() async {
        let (multiplexer, _) = makeMultiplexer(
            timeouts: .init(
                ordinary: .milliseconds(30),
                cold: .milliseconds(30),
                interrupt: .milliseconds(30)
            )
        )
        await #expect(throws: ClaudeControlError.timedOut(subtype: "set_model")) {
            _ = try await multiplexer.send(.setModel("x"))
        }
        #expect(await multiplexer.pendingCount == 0)
    }

    @Test func processExitFailsAllPendingExactlyOnce() async throws {
        let (multiplexer, written) = makeMultiplexer()
        let first = Task { try await multiplexer.send(.listModels) }
        await written.waitForCount(1)
        let second = Task { try await multiplexer.send(.setFastMode(true)) }
        await written.waitForCount(2)
        await multiplexer.failAll()

        await #expect(throws: ClaudeControlError.processExited(subtype: "list_models")) {
            _ = try await first.value
        }
        await #expect(throws: ClaudeControlError.processExited(subtype: "apply_flag_settings")) {
            _ = try await second.value
        }
        // Sends after failure fail fast.
        await #expect(throws: ClaudeControlError.processExited(subtype: "interrupt")) {
            _ = try await multiplexer.send(.interrupt)
        }
    }

    @Test func errorResponseThrowsRejected() async throws {
        let (multiplexer, written) = makeMultiplexer()
        let sending = Task { try await multiplexer.send(.setModel("bogus")) }
        await written.waitForCount(1)
        let requestID = try #require(await written.requestID(at: 0))
        var inner: [String: ClaudeJSONValue] = [
            "subtype": .string("error"),
            "request_id": .string(requestID),
            "error": .string("unknown model"),
        ]
        inner["response"] = nil
        await multiplexer.handleLine(ClaudeStreamLine.decode(.object([
            "type": .string("control_response"),
            "response": .object(inner),
        ])))
        await #expect(throws: ClaudeControlError.rejected(subtype: "set_model", message: "unknown model")) {
            _ = try await sending.value
        }
    }

    @Test func inboundControlRequestIsInertAndDiagnosed() async {
        let diagnostics = Diagnostics()
        let (multiplexer, written) = makeMultiplexer(diagnostics: { diagnostics.record($0) })
        let line = ClaudeStreamLine.decode(.object([
            "type": .string("control_request"),
            "request_id": .string("prov-1"),
            "request": .object(["subtype": .string("can_use_tool")]),
        ]))
        let consumed = await multiplexer.handleLine(line)
        #expect(!consumed)
        #expect(diagnostics.snapshot().contains { diagnostic in
            if case .inboundControlRequestIgnored(let subtype, let id) = diagnostic {
                return subtype == "can_use_tool" && id == "prov-1"
            }
            return false
        })
        // Nothing was ever written back — no answer path exists.
        #expect(await written.requestID(at: 0) == nil)
    }

    @Test func callerCancellationReleasesThePendingContinuation() async throws {
        let (multiplexer, written) = makeMultiplexer(
            timeouts: .init(
                ordinary: .seconds(60), cold: .seconds(60), interrupt: .seconds(60)
            )
        )
        let sending = Task { try await multiplexer.send(.listModels) }
        await written.waitForCount(1)
        #expect(await multiplexer.pendingCount == 1)
        sending.cancel()
        // The continuation resumes with CancellationError and the entry is
        // removed immediately — not held until timeout or failAll.
        await #expect(throws: CancellationError.self) {
            _ = try await sending.value
        }
        var remaining = await multiplexer.pendingCount
        for _ in 0..<200 where remaining != 0 {
            try? await Task.sleep(for: .milliseconds(5))
            remaining = await multiplexer.pendingCount
        }
        #expect(remaining == 0)
    }

    @Test func integerJSONValuesRoundTripLosslessly() throws {
        // Regression: 9007199254740993 (2^53 + 1) corrupts through Double.
        let input = Data(#"{"big":9007199254740993,"neg":-9223372036854775808}"#.utf8)
        let value = try JSONDecoder().decode(ClaudeJSONValue.self, from: input)
        #expect(value["big"] == .integer(9_007_199_254_740_993))
        let encoded = try JSONEncoder().encode(value)
        let reDecoded = try JSONDecoder().decode(ClaudeJSONValue.self, from: encoded)
        #expect(reDecoded == value)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("9007199254740993"))
        // Non-integral numbers still decode as doubles.
        let fraction = try JSONDecoder().decode(
            ClaudeJSONValue.self, from: Data(#"{"f":0.5}"#.utf8)
        )
        #expect(fraction["f"] == .number(0.5))
        #expect(fraction["f"]?.numberValue == 0.5)
    }

    @Test func encodedRequestLineMatchesWireShape() throws {
        let data = ClaudeOutboundControl.setMaxThinkingTokens(4096)
            .encodedLine(requestID: "smx-1")
        let value = try JSONDecoder().decode(ClaudeJSONValue.self, from: data)
        #expect(value["type"]?.stringValue == "control_request")
        #expect(value["request_id"]?.stringValue == "smx-1")
        #expect(value["request"]?["subtype"]?.stringValue == "set_max_thinking_tokens")
        #expect(value["request"]?["max_thinking_tokens"]?.intValue == 4096)
    }
}

/// Thread-safe diagnostic recorder for sink callbacks.
private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClaudeHarnessDiagnostic] = []

    func record(_ diagnostic: ClaudeHarnessDiagnostic) {
        lock.lock()
        items.append(diagnostic)
        lock.unlock()
    }

    func snapshot() -> [ClaudeHarnessDiagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

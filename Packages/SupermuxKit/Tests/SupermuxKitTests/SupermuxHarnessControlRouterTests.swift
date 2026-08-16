import Foundation
import Testing

@testable import SupermuxKit

@Suite(.serialized) @MainActor
struct SupermuxHarnessControlRouterTests {
    private enum SenderError: Error, Equatable {
        case rejected
    }

    @MainActor
    private final class FrameRecorder {
        var frames: [SupermuxHarnessEncodedFrame] = []
        var error: (any Error)?
        private var queued: [SupermuxHarnessEncodedFrame] = []
        private var waiters: [CheckedContinuation<SupermuxHarnessEncodedFrame, Never>] = []

        func send(_ frame: SupermuxHarnessEncodedFrame) async throws {
            frames.append(frame)
            if let error { throw error }
            if waiters.isEmpty {
                queued.append(frame)
            } else {
                waiters.removeFirst().resume(returning: frame)
            }
        }

        func next() async -> SupermuxHarnessEncodedFrame {
            if !queued.isEmpty { return queued.removeFirst() }
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    @Test func issueSendsGeneratedIDAndResolvesOnlyMatchingSuccess() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["request-1"])
        let operation = Task { try await router.issue(.getContextUsage) }
        let sent = await recorder.next()
        #expect(try sent.jsonObject().string(forKey: "request_id") == "request-1")

        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "unmatched",
                "response": ["ignored": true],
            ],
        ]))
        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "request-1",
                "response": ["totalTokens": 123],
            ],
        ]))

        let response = try await operation.value
        #expect(response.integer(forKey: "totalTokens") == 123)
    }

    @Test func payloadlessSuccessReturnsEmptyObject() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["request"])
        let operation = Task { try await router.issue(.interrupt(cancelQueued: true)) }
        _ = await recorder.next()
        router.consume(try frame([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": "request"],
        ]))
        #expect(try await operation.value.rawValue.isEmpty)
    }

    @Test func errorResponseFailsMatchingRequestWithMessage() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["request"])
        let operation = Task { try await router.issue(.renameSession(title: "name")) }
        _ = await recorder.next()
        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": "request",
                "response": ["error": "rename failed"],
            ],
        ]))

        do {
            _ = try await operation.value
            Issue.record("Expected request failure")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .requestFailed(requestID: "request", message: "rename failed"))
        }
    }

    @Test func directEnvelopeErrorMessageIsPreserved() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["request"])
        let operation = Task { try await router.issue(.getContextUsage) }
        _ = await recorder.next()
        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "error",
                "request_id": "request",
                "error": "direct failure",
            ],
        ]))
        do {
            _ = try await operation.value
            Issue.record("Expected request failure")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .requestFailed(requestID: "request", message: "direct failure"))
        }
    }

    @Test func senderFailureFailsIssuedRequestAndRemovesIt() async throws {
        let recorder = FrameRecorder()
        recorder.error = SenderError.rejected
        let router = makeRouter(recorder: recorder, requestIDs: ["request"])
        do {
            _ = try await router.issue(.getContextUsage)
            Issue.record("Expected sender failure")
        } catch let error as SenderError {
            #expect(error == .rejected)
        }

        recorder.error = nil
        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "request",
                "response": ["late": true],
            ],
        ]))
    }

    @Test func permissionRequestsAreOrderedDeduplicatedAndCancelled() throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: [])
        let first = try permissionFrame(requestID: "first", toolName: "Bash")
        let duplicate = try permissionFrame(requestID: "first", toolName: "Edit")
        let second = try permissionFrame(requestID: "second", toolName: "Read")

        router.consume(first)
        router.consume(duplicate)
        router.consume(second)
        #expect(router.pendingPermissionRequests.map(\.requestID) == ["first", "second"])
        #expect(router.pendingPermissionRequests.first?.toolName == "Bash")

        router.consume(try frame([
            "type": "control_cancel_request",
            "request_id": "first",
        ]))
        #expect(router.pendingPermissionRequests.map(\.requestID) == ["second"])
    }

    @Test func respondToPermissionSendsAllowExactlyOnce() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: [])
        router.consume(try permissionFrame(requestID: "permission", toolName: "Bash"))
        let updatedInput = try SupermuxHarnessJSONObject(rawValue: ["command": "pwd"])
        let selected = try SupermuxHarnessJSONObject(rawValue: ["type": "addRules"])

        try await router.respondToPermission(
            requestID: "permission",
            decision: .allow(updatedInput: updatedInput, updatedPermissions: [selected])
        )
        #expect(router.pendingPermissionRequests.isEmpty)
        let sent = try #require(try recorder.frames.first?.jsonObject())
        let envelope = try #require(sent.object(forKey: "response"))
        let response = try #require(envelope.object(forKey: "response"))
        #expect(envelope.string(forKey: "request_id") == "permission")
        #expect(response.string(forKey: "behavior") == "allow")
        #expect(response.object(forKey: "updatedInput") == updatedInput)
        #expect(response.objects(forKey: "updatedPermissions") == [selected])

        do {
            try await router.respondToPermission(
                requestID: "permission",
                decision: .deny(message: "again", interrupt: false)
            )
            Issue.record("Expected one-shot response rejection")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .permissionRequestNotFound("permission"))
        }
    }

    @Test func failedPermissionSendRestoresRequestForRetry() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: [])
        router.consume(try permissionFrame(requestID: "permission", toolName: "Edit"))
        recorder.error = SenderError.rejected

        do {
            try await router.respondToPermission(
                requestID: "permission",
                decision: .deny(message: "no", interrupt: true)
            )
            Issue.record("Expected sender failure")
        } catch let error as SenderError {
            #expect(error == .rejected)
        }
        #expect(router.pendingPermissionRequests.map(\.requestID) == ["permission"])

        recorder.error = nil
        try await router.respondToPermission(
            requestID: "permission",
            decision: .deny(message: "not approved", interrupt: true)
        )
        #expect(router.pendingPermissionRequests.isEmpty)
        #expect(recorder.frames.count == 2)
    }

    @Test func initializeReplaysAllSupportedPendingPermissionShapesAndDeduplicates() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["initialize"])
        let operation = Task { try await router.issue(.initialize) }
        _ = await recorder.next()
        let nestedRequest: [String: Any] = [
            "subtype": "can_use_tool",
            "tool_name": "Edit",
            "input": ["file_path": "a"],
        ]
        router.consume(try frame([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "initialize",
                "response": [
                    "current_permission_mode": "default",
                    "pending_permission_requests": [
                        [
                            "type": "control_request",
                            "request_id": "full",
                            "request": [
                                "subtype": "can_use_tool",
                                "tool_name": "Bash",
                                "input": ["command": "pwd"],
                            ],
                        ],
                        ["request_id": "nested", "request": nestedRequest],
                        [
                            "request_id": "flat",
                            "subtype": "can_use_tool",
                            "tool_name": "Read",
                            "input": ["file_path": "b"],
                        ],
                        ["request_id": "nested", "request": nestedRequest],
                        ["request_id": "ignored", "subtype": "future"],
                    ],
                ],
            ],
        ]))

        let response = try await operation.value
        #expect(response.string(forKey: "current_permission_mode") == "default")
        #expect(router.pendingPermissionRequests.map(\.requestID) == ["full", "nested", "flat"])
        #expect(router.pendingPermissionRequests.map(\.toolName) == ["Bash", "Edit", "Read"])
    }

    @Test func consumeDecodedLineIgnoresUnknownAndRegistersKnownFrames() throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: [])
        let decoder = SupermuxHarnessProtocolDecoder()
        router.consume(try decoder.decodeLine(#"{"type":"future"}"#))
        router.consume(try decoder.decodeLine(
            #"{"type":"control_request","request_id":"known","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#
        ))
        #expect(router.pendingPermissionRequests.map(\.requestID) == ["known"])
    }

    @Test func closeFailsClientRequestsAndAttemptsEveryPermissionDenial() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["client"])
        let operation = Task { try await router.issue(.getContextUsage) }
        _ = await recorder.next()
        router.consume(try permissionFrame(requestID: "one", toolName: "Bash"))
        router.consume(try permissionFrame(requestID: "two", toolName: "Edit"))

        recorder.error = SenderError.rejected
        await router.close(denialMessage: "Session closed")
        #expect(router.isClosed)
        #expect(router.pendingPermissionRequests.isEmpty)
        #expect(recorder.frames.count == 3)
        for frame in recorder.frames.dropFirst() {
            let object = try frame.jsonObject()
            let response = object.object(forKey: "response")?.object(forKey: "response")
            #expect(response?.string(forKey: "behavior") == "deny")
            #expect(response?.string(forKey: "message") == "Session closed")
            #expect(response?.bool(forKey: "interrupt") == false)
        }
        do {
            _ = try await operation.value
            Issue.record("Expected close to fail pending client request")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .closed)
        }

        await router.close(denialMessage: "ignored")
        #expect(recorder.frames.count == 3)
    }

    @Test func closedRouterRejectsNewRequestsAndPermissionResponses() async throws {
        let recorder = FrameRecorder()
        let router = makeRouter(recorder: recorder, requestIDs: ["unused"])
        await router.close(denialMessage: "closed")
        do {
            _ = try await router.issue(.getContextUsage)
            Issue.record("Expected closed error")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .closed)
        }
        do {
            try await router.respondToPermission(
                requestID: "missing",
                decision: .deny(message: "no", interrupt: false)
            )
            Issue.record("Expected closed error")
        } catch let error as SupermuxHarnessControlRouterError {
            #expect(error == .closed)
        }
    }

    private func makeRouter(
        recorder: FrameRecorder,
        requestIDs: [String]
    ) -> SupermuxHarnessControlRouter {
        var ids = requestIDs
        return SupermuxHarnessControlRouter(
            requestIDGenerator: { ids.removeFirst() },
            sender: { frame in try await recorder.send(frame) }
        )
    }

    private func frame(_ object: [String: Any]) throws -> SupermuxHarnessFrame {
        let json = try SupermuxHarnessJSONObject(rawValue: object)
        return try #require(SupermuxHarnessProtocolDecoder().decodeObject(json))
    }

    private func permissionFrame(
        requestID: String,
        toolName: String
    ) throws -> SupermuxHarnessFrame {
        try frame([
            "type": "control_request",
            "request_id": requestID,
            "request": [
                "subtype": "can_use_tool",
                "tool_name": toolName,
                "input": ["value": requestID],
            ],
        ])
    }
}

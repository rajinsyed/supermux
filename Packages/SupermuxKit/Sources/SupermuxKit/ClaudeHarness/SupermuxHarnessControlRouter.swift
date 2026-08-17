public import Foundation

/// Matches bidirectional control requests, tracks permissions, and fails safe on session close.
@MainActor
public final class SupermuxHarnessControlRouter {
    /// The currently unanswered CLI-issued permission requests in arrival order.
    public var pendingPermissionRequests: [SupermuxHarnessPermissionRequest] {
        permissionOrder.compactMap { pendingPermissions[$0] }
    }

    /// Whether the router has permanently closed.
    public private(set) var isClosed = false

    private struct PendingClientRequest {
        let command: SupermuxHarnessControlCommand
        let continuation: CheckedContinuation<SupermuxHarnessJSONObject, any Error>
    }

    private struct InFlightPermissionResponse {
        let request: SupermuxHarnessPermissionRequest
        let originalOrderIndex: Int
        var isCancelled = false
    }

    private let encoder: SupermuxHarnessProtocolEncoder
    private let decoder: SupermuxHarnessProtocolDecoder
    private let requestIDGenerator: SupermuxHarnessRequestIDGenerator
    private let sender: SupermuxHarnessControlFrameSender
    private var pendingClientRequests: [String: PendingClientRequest] = [:]
    private var issuedClientRequestIDs: Set<String> = []
    private var pendingPermissions: [String: SupermuxHarnessPermissionRequest] = [:]
    private var permissionOrder: [String] = []
    private var inFlightPermissionResponses: [String: InFlightPermissionResponse] = [:]

    /// Creates a router bound to one process session.
    ///
    /// - Parameters:
    ///   - encoder: The client-frame encoder.
    ///   - decoder: The tolerant frame decoder used for replayed initialize permissions.
    ///   - requestIDGenerator: A unique ID source; injected for deterministic tests.
    ///   - sender: The serialized process writer.
    public init(
        encoder: SupermuxHarnessProtocolEncoder = SupermuxHarnessProtocolEncoder(),
        decoder: SupermuxHarnessProtocolDecoder = SupermuxHarnessProtocolDecoder(),
        requestIDGenerator: @escaping SupermuxHarnessRequestIDGenerator = { UUID().uuidString },
        sender: @escaping SupermuxHarnessControlFrameSender
    ) {
        self.encoder = encoder
        self.decoder = decoder
        self.requestIDGenerator = requestIDGenerator
        self.sender = sender
    }

    /// Issues a client control request and suspends until its matching response arrives.
    ///
    /// - Parameter command: The control operation to issue.
    /// - Returns: The nested response payload, or an empty object for a payload-less success.
    /// - Throws: Encoding, sending, close, or CLI response errors.
    public func issue(_ command: SupermuxHarnessControlCommand) async throws -> SupermuxHarnessJSONObject {
        guard !isClosed else { throw SupermuxHarnessControlRouterError.closed }
        let requestID = reserveClientRequestID()
        let frame = try encoder.controlRequest(command, requestID: requestID)

        return try await withCheckedThrowingContinuation { continuation in
            pendingClientRequests[requestID] = PendingClientRequest(
                command: command,
                continuation: continuation
            )
            Task { @MainActor [weak self] in
                guard let self,
                      !isClosed,
                      pendingClientRequests[requestID] != nil else {
                    return
                }
                do {
                    try await sender(frame)
                } catch {
                    failClientRequest(requestID: requestID, error: error)
                }
            }
        }
    }

    /// Consumes a recognized incoming frame and updates matching request state.
    ///
    /// - Parameter frame: A frame decoded from process stdout.
    public func consume(_ frame: SupermuxHarnessFrame) {
        switch frame {
        case .controlRequest(let request):
            registerPermission(request.permissionRequest)
        case .controlResponse(let response):
            resolveClientRequest(response)
        case .controlCancelRequest(let cancellation):
            cancelPermission(requestID: cancellation.requestID)
        default:
            break
        }
    }

    /// Consumes the recognized portion of a decoded stdout line.
    ///
    /// - Parameter line: A decoded protocol line; unknown frames are ignored.
    public func consume(_ line: SupermuxHarnessDecodedLine) {
        guard let frame = line.frame else { return }
        consume(frame)
    }

    /// Answers one pending CLI permission request exactly once.
    ///
    /// - Parameters:
    ///   - requestID: The CLI-issued request identifier.
    ///   - decision: The allow or deny payload.
    /// - Throws: ``SupermuxHarnessControlRouterError`` or a writer error.
    public func respondToPermission(
        requestID: String,
        decision: SupermuxHarnessPermissionDecision
    ) async throws {
        guard !isClosed else { throw SupermuxHarnessControlRouterError.closed }
        guard pendingPermissions[requestID] != nil else {
            throw SupermuxHarnessControlRouterError.permissionRequestNotFound(requestID)
        }
        let frame: SupermuxHarnessEncodedFrame
        switch decision {
        case .allow(let updatedInput, let updatedPermissions):
            frame = try encoder.canUseToolAllowResponse(
                requestID: requestID,
                updatedInput: updatedInput,
                updatedPermissions: updatedPermissions
            )
        case .deny(let message, let interrupt):
            frame = try encoder.canUseToolDenyResponse(
                requestID: requestID,
                message: message,
                interrupt: interrupt
            )
        }
        guard let pending = takePermission(requestID: requestID) else {
            throw SupermuxHarnessControlRouterError.permissionRequestNotFound(requestID)
        }
        inFlightPermissionResponses[requestID] = InFlightPermissionResponse(
            request: pending.request,
            originalOrderIndex: pending.orderIndex
        )

        do {
            try await sender(frame)
            inFlightPermissionResponses.removeValue(forKey: requestID)
        } catch {
            let inFlight = inFlightPermissionResponses.removeValue(forKey: requestID)
            if let inFlight,
               !isClosed,
               !inFlight.isCancelled,
               pendingPermissions[requestID] == nil {
                pendingPermissions[requestID] = inFlight.request
                permissionOrder.insert(
                    requestID,
                    at: min(inFlight.originalOrderIndex, permissionOrder.count)
                )
            }
            throw error
        }
    }

    /// Denies every pending permission and fails every waiting client request before closing.
    ///
    /// The router attempts all denials even if an earlier write fails. Each pending permission is
    /// removed before its response is sent, so close can never answer one request twice.
    ///
    /// - Parameter denialMessage: The model-visible reason for the fail-safe denials.
    public func close(denialMessage: String) async {
        guard !isClosed else { return }
        isClosed = true

        let clientRequests = Array(pendingClientRequests.values)
        pendingClientRequests.removeAll()
        for request in clientRequests {
            request.continuation.resume(throwing: SupermuxHarnessControlRouterError.closed)
        }

        let requests = pendingPermissionRequests
        pendingPermissions.removeAll()
        permissionOrder.removeAll()
        for requestID in Array(inFlightPermissionResponses.keys) {
            inFlightPermissionResponses[requestID]?.isCancelled = true
        }
        for request in requests {
            guard let frame = try? encoder.canUseToolDenyResponse(
                requestID: request.requestID,
                message: denialMessage,
                interrupt: false
            ) else {
                continue
            }
            try? await sender(frame)
        }
    }

    private func registerPermission(_ permission: SupermuxHarnessPermissionRequest) {
        guard !isClosed,
              pendingPermissions[permission.requestID] == nil,
              inFlightPermissionResponses[permission.requestID] == nil else {
            return
        }
        pendingPermissions[permission.requestID] = permission
        permissionOrder.append(permission.requestID)
    }

    private func cancelPermission(requestID: String) {
        _ = removePermission(requestID: requestID)
        inFlightPermissionResponses[requestID]?.isCancelled = true
    }

    @discardableResult
    private func removePermission(requestID: String) -> SupermuxHarnessPermissionRequest? {
        takePermission(requestID: requestID)?.request
    }

    private func takePermission(
        requestID: String
    ) -> (request: SupermuxHarnessPermissionRequest, orderIndex: Int)? {
        guard let request = pendingPermissions.removeValue(forKey: requestID) else { return nil }
        let orderIndex = permissionOrder.firstIndex(of: requestID) ?? permissionOrder.endIndex
        permissionOrder.removeAll { $0 == requestID }
        return (request, orderIndex)
    }

    private func reserveClientRequestID() -> String {
        let preferred = requestIDGenerator()
        if !preferred.isEmpty, issuedClientRequestIDs.insert(preferred).inserted {
            return preferred
        }

        var fallback = UUID().uuidString
        while !issuedClientRequestIDs.insert(fallback).inserted {
            fallback = UUID().uuidString
        }
        return fallback
    }

    private func resolveClientRequest(_ response: SupermuxHarnessControlResponseFrame) {
        guard let pending = pendingClientRequests.removeValue(forKey: response.requestID) else {
            return
        }
        switch response.subtype {
        case .success:
            let payload = response.response ?? SupermuxHarnessJSONObject(parsedObject: [:])
            if pending.command == .initialize {
                replayPendingPermissions(from: payload)
            }
            pending.continuation.resume(returning: payload)
        case .error:
            let message = response.response?.string(forKey: "error")
                ?? response.rawObject.object(forKey: "response")?.string(forKey: "error")
            pending.continuation.resume(throwing: SupermuxHarnessControlRouterError.requestFailed(
                requestID: response.requestID,
                message: message
            ))
        }
    }

    private func failClientRequest(requestID: String, error: any Error) {
        guard let pending = pendingClientRequests.removeValue(forKey: requestID) else { return }
        pending.continuation.resume(throwing: error)
    }

    private func replayPendingPermissions(from initializeResponse: SupermuxHarnessJSONObject) {
        guard let entries = initializeResponse["pending_permission_requests"] as? [Any] else { return }
        for entry in entries {
            guard let raw = entry as? [String: Any],
                  let normalized = normalizedPendingPermission(raw),
                  let object = try? SupermuxHarnessJSONObject(rawValue: normalized),
                  case .controlRequest(let frame)? = decoder.decodeObject(object) else {
                continue
            }
            registerPermission(frame.permissionRequest)
        }
    }

    private func normalizedPendingPermission(_ raw: [String: Any]) -> [String: Any]? {
        if raw["type"] as? String == "control_request" {
            return raw
        }
        guard let requestID = raw["request_id"] as? String else { return nil }
        if let request = raw["request"] as? [String: Any] {
            return [
                "type": "control_request",
                "request_id": requestID,
                "request": request,
            ]
        }
        guard raw["subtype"] as? String == "can_use_tool" else { return nil }
        var request = raw
        request.removeValue(forKey: "request_id")
        return [
            "type": "control_request",
            "request_id": requestID,
            "request": request,
        ]
    }
}

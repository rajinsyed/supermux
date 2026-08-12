import Foundation
import Testing
@testable import SupermuxMobileCore

@Suite struct SupermuxClaudeWireDTOTests {
    private let support = WireCodingTestSupport()

    @Test func sessionSnapshotRoundTripsWithExactSnakeCaseKeys() throws {
        let session = Self.sampleSession

        #expect(try support.roundTrip(session) == session)
        #expect(try support.encodedKeys(of: session) == [
            "session_id",
            "claude_session_id",
            "title",
            "cwd",
            "project_id",
            "launcher",
            "model",
            "effort",
            "fast_mode",
            "thinking_budget",
            "state",
            "cost",
            "queued_count",
            "last_activity_at",
            "version",
        ])

        let data = try JSONEncoder().encode(session)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let launcher = try #require(object["launcher"] as? [String: String])
        #expect(launcher == ["custom": "/opt/homebrew/bin/claude-custom"])
        #expect(object["permission_mode"] == nil)
        #expect(object["pending_permission"] == nil)
    }

    @Test func createRequestContainsNoPermissionAuthorizationFields() throws {
        let request = SupermuxClaudeSessionCreateRequestDTO(
            cwd: "/repo",
            projectID: "project-1",
            launcher: .ccx,
            model: "sonnet",
            effort: "high",
            fastMode: true,
            thinkingBudget: 8_000,
            initialPrompt: "Fix the failing test"
        )

        #expect(try support.roundTrip(request) == request)
        let keys = try support.encodedKeys(of: request)
        #expect(keys.contains("fast_mode"))
        #expect(keys.contains("thinking_budget"))
        #expect(keys.contains("initial_prompt"))
        #expect(!keys.contains("permission_mode"))
        #expect(!keys.contains("permission"))
    }

    @Test func sendRequestUsesTextAndOptionalAttachments() throws {
        let request = SupermuxClaudeSendRequestDTO(
            sessionID: "session-1",
            text: "Explain this screenshot",
            attachments: [
                SupermuxClaudeAttachmentDTO(data: Data([0x89, 0x50, 0x4E, 0x47]), format: .png),
            ]
        )

        #expect(try support.roundTrip(request) == request)
        #expect(try support.encodedKeys(of: request) == ["session_id", "text", "attachments"])
        let withoutAttachments = SupermuxClaudeSendRequestDTO(sessionID: "session-1", text: "/cost")
        #expect(try support.encodedKeys(of: withoutAttachments) == ["session_id", "text"])
    }

    @Test func compactEventsRoundTripAllV1Semantics() throws {
        let message = Self.sampleMessage
        let events: [SupermuxClaudeChatEvent] = [
            .append([message]),
            .update([message]),
            .state(.working),
            .reset,
        ]

        for event in events {
            #expect(try support.roundTrip(event) == event)
        }

        let frame = SupermuxClaudeEventFrame(sessionID: "session-1", eventNo: 42, frame: .append([message]))
        #expect(try support.roundTrip(frame) == frame)
        #expect(try support.encodedKeys(of: frame) == ["session_id", "event_no", "frame"])
    }

    @Test func compactEventsPreserveUnknownKindsWithoutDroppingTheFrame() throws {
        let json = """
        {
          "session_id": "session-1",
          "event_no": 43,
          "frame": {"kind": "future_event", "payload": {"new": true}}
        }
        """

        let frame = try support.decode(SupermuxClaudeEventFrame.self, from: json)
        #expect(frame == SupermuxClaudeEventFrame(
            sessionID: "session-1",
            eventNo: 43,
            frame: .unknown("future_event")
        ))
    }

    @Test func messageRoleAndKindPreserveUnknownRawValues() throws {
        #expect(try support.roundTrip(SupermuxClaudeChatRole.unknown("developer")) == .unknown("developer"))
        #expect(try support.roundTrip(SupermuxClaudeChatMessageKind.unknown("artifact")) == .unknown("artifact"))
    }

    @Test func historyUsesBeforeSequenceAndMobileChatEnvelopeKeys() throws {
        let request = SupermuxClaudeHistoryRequestDTO(sessionID: "session-1", beforeSeq: 100, limit: 50)
        let page = SupermuxClaudeHistoryPageDTO(messages: [Self.sampleMessage], hasMore: true)

        #expect(try support.roundTrip(request) == request)
        #expect(try support.encodedKeys(of: request) == ["session_id", "before_seq", "limit"])
        #expect(try support.roundTrip(page) == page)
        #expect(try support.encodedKeys(of: page) == ["messages", "has_more"])
    }

    @Test func optionsRoundTripAdvertisedModelsEffortFastModeCommandsAndLaunchers() throws {
        let options = SupermuxClaudeOptionsDTO(
            models: [
                SupermuxClaudeModelOptionDTO(
                    value: "sonnet",
                    resolvedModel: "claude-sonnet-5",
                    displayName: "Sonnet",
                    description: "Balanced",
                    supportedEffortLevels: ["low", "medium", "high"],
                    supportsFastMode: true
                ),
            ],
            supportedEffortLevels: ["low", "medium", "high"],
            supportsFastMode: true,
            slashCommands: ["/compact", "/cost"],
            launchers: [
                SupermuxClaudeLauncherAvailabilityDTO(
                    launcher: .claude,
                    available: true,
                    displayName: "Claude"
                ),
                SupermuxClaudeLauncherAvailabilityDTO(
                    launcher: .ccx,
                    available: false,
                    displayName: "ccx",
                    unavailableReason: "Not installed"
                ),
            ]
        )

        #expect(try support.roundTrip(options) == options)
        #expect(try support.encodedKeys(of: options) == [
            "models",
            "supported_effort_levels",
            "supports_fast_mode",
            "slash_commands",
            "launchers",
        ])
    }

    @Test func toolPayloadChunksEnforceThreeMiBRawLimit() throws {
        let maximum = SupermuxClaudeToolPayloadChunkDTO.maximumDataBytes
        let chunk = try SupermuxClaudeToolPayloadChunkDTO(
            data: Data(repeating: 0xA5, count: maximum),
            offset: 0,
            totalSize: Int64(maximum),
            eof: true
        )

        #expect(chunk.data.count == 3 * 1024 * 1024)
        #expect(try support.roundTrip(chunk) == chunk)
        #expect(try support.encodedKeys(of: chunk) == ["data_b64", "offset", "total_size", "eof"])
        #expect(throws: SupermuxClaudeToolPayloadChunkError.chunkTooLarge(actualBytes: maximum + 1)) {
            try SupermuxClaudeToolPayloadChunkDTO(
                data: Data(repeating: 0, count: maximum + 1),
                offset: 0,
                totalSize: Int64(maximum + 1),
                eof: true
            )
        }
    }

    @Test func toolPayloadAndWatchRequestsUseTheContractKeys() throws {
        let payloadRequest = SupermuxClaudeToolPayloadRequestDTO(
            sessionID: "session-1",
            messageID: "message-1",
            offset: 64
        )
        #expect(try support.roundTrip(payloadRequest) == payloadRequest)
        #expect(try support.encodedKeys(of: payloadRequest) == ["session_id", "message_id", "offset"])

        let watch = SupermuxClaudeWatchRequestDTO(enable: true, clientID: "phone-1")
        #expect(try support.roundTrip(watch) == watch)
        #expect(try support.encodedKeys(of: watch) == ["enable", "client_id"])
    }

    @Test func setOptionValuesUseJsonScalarsAndExcludePermissionMode() throws {
        let supported: [(SupermuxClaudeOption, SupermuxClaudeOptionValue)] = [
            (.model, .string("opus")),
            (.effort, .string("high")),
            (.fastMode, .bool(true)),
            (.thinkingBudget, .integer(16_000)),
        ]

        #expect(SupermuxClaudeOption.allCases.count == 4)
        for (option, value) in supported {
            let request = SupermuxClaudeSetOptionRequestDTO(
                sessionID: "session-1",
                option: option,
                value: value
            )
            #expect(try support.roundTrip(request) == request)
            let result = SupermuxClaudeSetOptionResultDTO(appliedValue: value)
            #expect(try support.roundTrip(result) == result)
            #expect(try support.encodedKeys(of: result) == ["applied_value"])
        }
        #expect(SupermuxClaudeOption(rawValue: "permission_mode") == nil)
    }

    private static let sampleSession = SupermuxClaudeSessionDTO(
        sessionID: "session-1",
        claudeSessionID: "claude-session-1",
        title: "Fix tests",
        cwd: "/repo",
        projectID: "project-1",
        launcher: .custom(path: "/opt/homebrew/bin/claude-custom"),
        model: "sonnet",
        effort: "high",
        fastMode: true,
        thinkingBudget: 8_000,
        state: .working,
        cost: SupermuxClaudeCostDTO(totalUSD: 1.25, turns: 3, durationMS: 12_500),
        queuedCount: 2,
        lastActivityAt: 1_786_500_000,
        version: 9
    )

    private static let sampleMessage = SupermuxClaudeChatMessageDTO(
        id: "message-1",
        seq: 99,
        role: .assistant,
        timestamp: 1_786_500_000,
        kind: .tool,
        tool: SupermuxClaudeToolDTO(
            toolUseID: "tool-1",
            name: "Read",
            title: "Read file",
            inputSummary: "/repo/README.md",
            outputSummary: "120 lines",
            isError: false,
            isComplete: true
        )
    )
}

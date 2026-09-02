import Foundation
import Testing
@testable import SupermuxMobileCore

/// Wire-shape tests for the agent-launch DTOs: snake_case keys, lenient
/// decoding of partial payloads, and tolerant parsing of Claude Code's raw
/// `initialize` model objects.
@Suite struct SupermuxAgentLaunchDTOCodingTests {
    private let coding = WireCodingTestSupport()

    @Test func modelEncodesSnakeCaseKeysAndRoundTrips() throws {
        let model = SupermuxAgentModelDTO(
            value: "claude-opus-5",
            displayName: "Claude Opus 5",
            description: "Most capable",
            supportsEffort: true,
            supportedEffortLevels: ["low", "medium", "high"],
            defaultEffortLevel: "medium"
        )
        #expect(try coding.encodedKeys(of: model) == [
            "value", "display_name", "description", "supports_effort",
            "supported_effort_levels", "default_effort_level",
        ])
        #expect(try coding.roundTrip(model) == model)
    }

    @Test func modelDecodesMinimalPayloadWithDefaults() throws {
        let model = try coding.decode(SupermuxAgentModelDTO.self, from: #"{"value":"gpt-5.6-sol"}"#)
        #expect(model.value == "gpt-5.6-sol")
        #expect(model.displayName == "gpt-5.6-sol")
        #expect(model.supportsEffort == false)
        #expect(model.supportedEffortLevels.isEmpty)
        #expect(model.defaultEffortLevel == nil)
    }

    @Test func modelParsesRawInitializeObjectInEitherKeyStyle() {
        let camel = SupermuxAgentModelDTO(initializeModel: [
            "value": "claude-sonnet-5",
            "displayName": "Claude Sonnet 5",
            "supportsEffort": true,
            "supportedEffortLevels": ["low", "high"],
            "defaultEffortLevel": "high",
        ])
        #expect(camel == SupermuxAgentModelDTO(
            value: "claude-sonnet-5",
            displayName: "Claude Sonnet 5",
            supportsEffort: true,
            supportedEffortLevels: ["low", "high"],
            defaultEffortLevel: "high"
        ))
        let snake = SupermuxAgentModelDTO(initializeModel: [
            "value": "x",
            "display_name": "X",
            "supported_effort_levels": ["max"],
        ])
        #expect(snake?.displayName == "X")
        // Levels without an explicit flag still mean effort is supported.
        #expect(snake?.supportsEffort == true)
        #expect(SupermuxAgentModelDTO(initializeModel: ["displayName": "no selector"]) == nil)
        #expect(SupermuxAgentModelDTO(initializeModel: ["value": "  "]) == nil)
    }

    @Test func optionsEncodeSnakeCaseKeysAndRoundTrip() throws {
        let options = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude", "cc"],
            selectedCommand: "cc",
            models: [SupermuxAgentModelDTO(value: "opus")],
            modelsSource: .probe,
            modelsError: nil,
            lastModel: "opus",
            lastEffort: "high"
        )
        #expect(try coding.encodedKeys(of: options) == [
            "commands", "selected_command", "models", "models_source", "last_model", "last_effort",
        ])
        #expect(try coding.roundTrip(options) == options)
    }

    @Test func optionsDecodeLenientlyFromAnOlderHost() throws {
        let options = try coding.decode(
            SupermuxAgentLaunchOptionsDTO.self,
            from: #"{"commands":["claude"],"models_source":"weird"}"#
        )
        #expect(options.selectedCommand == "claude")
        #expect(options.models.isEmpty)
        #expect(options.modelsSource == .unavailable)
    }
}

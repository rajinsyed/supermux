import Foundation
import Testing
@testable import SupermuxMobileCore

/// Ways the additive `ai_naming_configured` field on `agent.options` could fail
/// (written before the field existed):
/// 1. An older host that omits the field decodes as "configured" (or "not
///    configured") instead of unknown, so the viewer Mac shows a wrong hint.
/// 2. The field travels under a camelCase key an older phone or Mac ignores
///    inconsistently, or is emitted as `null` when unknown.
/// 3. An explicit `false` is lost on a round trip (reads back as unknown).
/// 4. Adding the field breaks decoding of the rest of an older payload.
struct SupermuxAgentOptionsAINamingTests {
    private let coding = WireCodingTestSupport()

    @Test func olderHostWithoutTheFieldDecodesAsUnknown() throws {
        let options = try coding.decode(
            SupermuxAgentLaunchOptionsDTO.self,
            from: #"{"commands":["claude"],"selected_command":"claude","models":[],"models_source":"cache"}"#
        )
        #expect(options.aiNamingConfigured == nil)
        #expect(options.commands == ["claude"])
        #expect(options.modelsSource == .cache)
    }

    @Test func fieldUsesTheSnakeCaseKeyAndIsOmittedWhenUnknown() throws {
        var options = SupermuxAgentLaunchOptionsDTO(
            commands: ["claude"],
            selectedCommand: "claude",
            models: [],
            modelsSource: .cache
        )
        #expect(try !coding.encodedKeys(of: options).contains("ai_naming_configured"))
        options.aiNamingConfigured = true
        #expect(try coding.encodedKeys(of: options).contains("ai_naming_configured"))
    }

    @Test func explicitValuesRoundTrip() throws {
        for value in [true, false] {
            var options = SupermuxAgentLaunchOptionsDTO(
                commands: ["cc"],
                selectedCommand: "cc",
                models: [],
                modelsSource: .unavailable,
                modelsError: "no catalog"
            )
            options.aiNamingConfigured = value
            let decoded = try coding.roundTrip(options)
            #expect(decoded.aiNamingConfigured == value)
            #expect(decoded == options)
        }
    }
}

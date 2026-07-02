import Testing

@testable import CmuxSettingsUI

/// SUPERMUX — pins the card's side of the contract with
/// `SupermuxKit.SupermuxAIConfig` (which cannot be imported here; the reverse
/// dependency is why the four literals are duplicated in the card at all).
///
/// `SupermuxAIConfigTests` in SupermuxKit pins the same literals on the other
/// side, so renaming either copy alone fails CI instead of silently making
/// Settings write the API key to one file while the AI client reads another.
@Suite("SupermuxAISettingsCard contract literals")
struct SupermuxAISettingsCardContractTests {
    @Test @MainActor func literalsMatchSupermuxAIConfigContract() {
        #expect(SupermuxAISettingsCard.secretKeyID == "supermux.ai.gatewayApiKey")
        #expect(SupermuxAISettingsCard.secretFileName == "supermux-ai-gateway-key")
        #expect(SupermuxAISettingsCard.modelDefaultsKey == "supermux.ai.model")
        #expect(SupermuxAISettingsCard.defaultModelPlaceholder == "openai/gpt-5.4-mini")
    }
}

import Foundation
import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxAIConfig/currentModel(defaults:)``.
struct SupermuxAIConfigTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "supermux.ai.config.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func usesDefaultWhenUnset() {
        #expect(SupermuxAIConfig.currentModel(defaults: freshDefaults()) == SupermuxAIConfig.defaultModel)
    }

    @Test func usesOverrideWhenSet() {
        let defaults = freshDefaults()
        defaults.set("anthropic/claude-haiku-4.5", forKey: SupermuxAIConfig.modelDefaultsKey)
        #expect(SupermuxAIConfig.currentModel(defaults: defaults) == "anthropic/claude-haiku-4.5")
    }

    @Test func fallsBackOnBlankOverride() {
        let defaults = freshDefaults()
        defaults.set("   ", forKey: SupermuxAIConfig.modelDefaultsKey)
        #expect(SupermuxAIConfig.currentModel(defaults: defaults) == SupermuxAIConfig.defaultModel)
    }

    /// Pins the literal contract shared with `SupermuxAISettingsCard`
    /// (CmuxSettingsUI), which duplicates these strings because it cannot
    /// import this package. `SupermuxAISettingsCardContractTests` pins the
    /// card's copy; a rename on either side fails CI instead of silently
    /// splitting the Settings write path from the AI-client read path.
    @Test func contractLiteralsMatchSettingsCard() {
        #expect(SupermuxAIConfig.secretKeyID == "supermux.ai.gatewayApiKey")
        #expect(SupermuxAIConfig.secretFileName == "supermux-ai-gateway-key")
        #expect(SupermuxAIConfig.modelDefaultsKey == "supermux.ai.model")
        #expect(SupermuxAIConfig.defaultModel == "openai/gpt-5.4-mini")
    }
}

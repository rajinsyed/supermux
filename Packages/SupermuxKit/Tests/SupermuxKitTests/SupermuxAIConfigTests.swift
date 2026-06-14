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
}

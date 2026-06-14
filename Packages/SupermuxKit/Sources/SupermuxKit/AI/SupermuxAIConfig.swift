public import Foundation

/// Shared constants and resolution for supermux's AI integration.
///
/// The on-disk secret file name and the UserDefaults model-override key are a
/// **contract** shared with the Settings UI card (`SupermuxAISettingsCard` in
/// the `CmuxSettingsUI` package). That card cannot import this package, so it
/// duplicates these two strings literally — keep them in sync.
///
/// The API key itself is never stored here: it lives in a `0600` secret file
/// read by the app composition root (see `SupermuxComposition` in
/// `SupermuxAppGlue.swift`), which injects a key-provider closure into
/// ``SupermuxAIGatewayClient``. This package therefore needs no settings or
/// keychain dependency.
public enum SupermuxAIConfig {
    /// OpenAI-compatible base URL for the Vercel AI Gateway.
    public static let baseURLString = "https://ai-gateway.vercel.sh/v1"

    /// Dotted identifier for the API-key secret (matches other cmux secret keys).
    public static let secretKeyID = "supermux.ai.gatewayApiKey"

    /// Bare file name of the `0600` secret under the cmux state directory.
    /// Shared contract with `SupermuxAISettingsCard`.
    public static let secretFileName = "supermux-ai-gateway-key"

    /// `UserDefaults` key holding the optional model-slug override.
    /// Shared contract with `SupermuxAISettingsCard`.
    public static let modelDefaultsKey = "supermux.ai.model"

    /// Lightweight default model used when the user has not chosen one. A small,
    /// fast, inexpensive chat model that the gateway exposes for quick tasks
    /// like branch names and commit messages. Override it in Settings → AI.
    public static let defaultModel = "openai/gpt-5.4-mini"

    /// The model slug to use for AI features: the user's override when set,
    /// otherwise ``defaultModel``.
    /// - Parameter defaults: User defaults to read; injectable for tests.
    public static func currentModel(defaults: UserDefaults = .standard) -> String {
        let raw = (defaults.string(forKey: modelDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? defaultModel : raw
    }
}

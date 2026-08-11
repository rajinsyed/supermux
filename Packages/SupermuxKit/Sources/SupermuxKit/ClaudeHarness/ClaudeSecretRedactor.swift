import Foundation

/// Strips secrets from text before it is persisted or surfaced.
///
/// Applied to stderr tails and diagnostics; never persist unredacted child
/// output. Redacts `ANTHROPIC_*`-style env assignments and token-looking
/// strings (`sk-...`, long bearer-ish blobs).
public enum ClaudeSecretRedactor {
    /// Order matters: value-shaped patterns (`sk-…`, `Bearer …`) run before
    /// key-shaped ones so a serialized `"authorization":"bearer xyz"` cannot
    /// leave its token behind after a partial key match.
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            // Anthropic-style API keys anywhere in the text.
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            // Bearer tokens, case-insensitive (headers serialize lowercase).
            #"(?i)\bBearer\s+[A-Za-z0-9._\-]{8,}"#,
            // ANTHROPIC_*/CCX_API_KEY in env (`K=v`, `K: v`) or JSON
            // (`"K":"v"`) form.
            #"(?i)"?ANTHROPIC_[A-Z_]+"?\s*[=:]\s*"?[^"\s,}]+"?"#,
            #"(?i)"?CCX_API_KEY"?\s*[=:]\s*"?[^"\s,}]+"?"#,
            // Generic credentials after common key names, quoted or bare.
            #"(?i)"?(api[_-]?key|auth[_-]?token|access[_-]?token|token|secret|password|authorization|credentials?)"?\s*[=:]\s*"?[^"\s,}]+"?"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Returns `text` with all secret-looking spans replaced by `[redacted]`.
    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[redacted]"
            )
        }
        return result
    }
}

public import Foundation

/// Errors raised by ``SupermuxAIGatewayClient`` when a completion cannot be
/// produced.
///
/// Feature services (``SupermuxAIBranchNamer``, ``SupermuxAICommitMessenger``)
/// translate these into a `nil` result so a missing key or a transient failure
/// degrades gracefully (random branch name / disabled AI commit) instead of
/// surfacing a raw error. The localized descriptions exist for the few call
/// sites that do show the error directly.
public enum SupermuxAIError: Error, Equatable, Sendable {
    /// No API key is configured.
    case notConfigured
    /// The request never reached the gateway (network/URL error).
    case transport(String)
    /// The gateway returned a non-2xx status; carries the parsed error message.
    case requestFailed(status: Int, message: String?)
    /// The response body could not be decoded into the expected shape.
    case decodingFailed
    /// The gateway returned a 2xx response with no usable content.
    case emptyResponse
}

extension SupermuxAIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return String(
                localized: "supermux.ai.error.notConfigured",
                defaultValue: "Add a Vercel AI Gateway API key in Settings to use AI features."
            )
        case .transport(let detail):
            return String(
                localized: "supermux.ai.error.transport",
                defaultValue: "Couldn’t reach the AI gateway: \(detail)"
            )
        case .requestFailed(let status, let message):
            if let message, !message.isEmpty {
                return String(
                    localized: "supermux.ai.error.requestFailedMessage",
                    defaultValue: "AI request failed (\(status)): \(message)"
                )
            }
            return String(
                localized: "supermux.ai.error.requestFailed",
                defaultValue: "AI request failed with status \(status)."
            )
        case .decodingFailed:
            return String(
                localized: "supermux.ai.error.decoding",
                defaultValue: "The AI gateway returned an unexpected response."
            )
        case .emptyResponse:
            return String(
                localized: "supermux.ai.error.empty",
                defaultValue: "The AI gateway returned an empty response."
            )
        }
    }
}

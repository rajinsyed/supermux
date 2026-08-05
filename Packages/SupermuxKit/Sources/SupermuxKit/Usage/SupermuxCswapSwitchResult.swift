public import Foundation

/// Outcome of a `cswap switch <slot> --json` invocation.
public enum SupermuxCswapSwitchResult: Sendable, Equatable {
    /// The active Claude Code login is now the target account.
    case switched(toEmail: String)
    /// The target was already the active account.
    case alreadyActive(email: String)
    /// cswap refused or failed; `message` is its human-readable reason.
    case failed(message: String)

    /// Parses cswap's switch JSON envelope
    /// (`{"switched": Bool, "to": {"number", "email"}, "reason", "message"}`),
    /// or its error envelope (`{"error": {"type", "message"}}`).
    public static func parse(jsonData: Data) -> SupermuxCswapSwitchResult? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: jsonData) else { return nil }
        if let error = payload.error {
            return .failed(message: error.message ?? error.type ?? "cswap switch failed")
        }
        guard let switched = payload.switched else { return nil }
        let email = payload.to?.email ?? ""
        if switched {
            return .switched(toEmail: email)
        }
        if payload.reason == "already-active" {
            return .alreadyActive(email: email)
        }
        // Not switched for any other reason (rate-limited target under a
        // strategy, no-op guard, …): surface cswap's message.
        return .failed(message: payload.message ?? "cswap did not switch")
    }

    private struct Payload: Decodable {
        let switched: Bool?
        let to: Ref?
        let reason: String?
        let message: String?
        let error: ErrorBody?

        struct Ref: Decodable {
            let number: Int?
            let email: String?
        }

        struct ErrorBody: Decodable {
            let type: String?
            let message: String?
        }
    }
}

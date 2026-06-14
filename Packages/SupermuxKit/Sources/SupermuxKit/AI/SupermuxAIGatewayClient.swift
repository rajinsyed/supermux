public import Foundation

/// Single-turn chat completion against an OpenAI-compatible endpoint.
///
/// Abstracted as a protocol so feature services depend on the capability, not
/// the concrete HTTP client, and tests can inject a fake.
public protocol SupermuxAICompleting: Sendable {
    /// Whether a usable API key is currently configured.
    func isConfigured() async -> Bool

    /// Sends a system + user prompt and returns the assistant's text.
    /// - Parameters:
    ///   - model: Model slug (e.g. `openai/gpt-5.4-mini`).
    ///   - system: System instructions.
    ///   - user: User content.
    ///   - maxOutputTokens: Upper bound on the response length.
    /// - Returns: The trimmed assistant text.
    /// - Throws: ``SupermuxAIError`` on missing key, transport, HTTP, or decode failure.
    func complete(model: String, system: String, user: String, maxOutputTokens: Int) async throws -> String
}

/// Talks to the Vercel AI Gateway's OpenAI-compatible Chat Completions API.
///
/// The API key is read lazily through an injected provider closure (wired to
/// the secure `0600` secret file by the app composition root), so a key pasted
/// in Settings is picked up on the next request without reconstructing the
/// client. Networking goes through an injected `URLSession` for testability.
public actor SupermuxAIGatewayClient: SupermuxAICompleting {
    private let apiKeyProvider: @Sendable () async -> String?
    private let session: URLSession
    private let endpoint: URL
    /// Per-request deadline. AI features are interactive (branch names, commit
    /// messages), so cap requests well under URLSession's 60s default rather
    /// than letting a stalled gateway block the UI for a minute.
    private let requestTimeout: TimeInterval = 30

    /// Creates a client.
    /// - Parameters:
    ///   - apiKeyProvider: Returns the current API key, or `nil`/empty when unset.
    ///   - session: URL session used for requests; defaults to `.shared`.
    ///   - baseURLString: Gateway base URL; defaults to ``SupermuxAIConfig/baseURLString``.
    public init(
        apiKeyProvider: @escaping @Sendable () async -> String?,
        session: URLSession = .shared,
        baseURLString: String = SupermuxAIConfig.baseURLString
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        let base = URL(string: baseURLString) ?? URL(string: SupermuxAIConfig.baseURLString)!
        self.endpoint = base.appendingPathComponent("chat/completions")
    }

    public func isConfigured() async -> Bool {
        guard let key = await apiKeyProvider() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func complete(model: String, system: String, user: String, maxOutputTokens: Int) async throws -> String {
        guard let key = await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw SupermuxAIError.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ChatRequest(
            model: model,
            messages: [
                ChatRequest.Message(role: "system", content: system),
                ChatRequest.Message(role: "user", content: user),
            ],
            maxTokens: maxOutputTokens,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupermuxAIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupermuxAIError.transport("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupermuxAIError.requestFailed(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw SupermuxAIError.decodingFailed
        }
        let content = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw SupermuxAIError.emptyResponse }
        return content
    }

    /// Best-effort extraction of a human-readable message from an error body.
    private static func errorMessage(from data: Data) -> String? {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message, !message.isEmpty {
            return message
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }

    // MARK: - Wire types

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let maxTokens: Int
        let stream: Bool

        struct Message: Encodable {
            let role: String
            let content: String
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
        struct ErrorBody: Decodable { let message: String? }
    }
}

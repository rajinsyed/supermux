import Foundation
import Testing
@testable import SupermuxKit

/// Unit tests for ``SupermuxAIGatewayClient`` using a `URLProtocol` stub.
///
/// Serialized because the stub shares process-global state (the canned handler
/// and captured request), which parallel cases would race on.
@Suite(.serialized)
struct SupermuxAIGatewayClientTests {
    @Test func throwsNotConfiguredWhenKeyMissing() async {
        let client = SupermuxAIGatewayClient(apiKeyProvider: { nil }, session: StubURLProtocol.session())
        await #expect(throws: SupermuxAIError.notConfigured) {
            try await client.complete(model: "m", system: "s", user: "u", maxOutputTokens: 10)
        }
    }

    @Test func postsToGatewayWithAuthAndParsesContent() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data(#"{"choices":[{"message":{"content":"hello-world"}}]}"#.utf8)
            return (response, body)
        }
        let client = SupermuxAIGatewayClient(apiKeyProvider: { "key123" }, session: StubURLProtocol.session())
        let output = try await client.complete(
            model: "openai/gpt-4o-mini", system: "s", user: "u", maxOutputTokens: 10
        )
        #expect(output == "hello-world")
        #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://ai-gateway.vercel.sh/v1/chat/completions")
        #expect(StubURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer key123")
    }

    @Test func throwsRequestFailedWithParsedMessage() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            let body = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
            return (response, body)
        }
        let client = SupermuxAIGatewayClient(apiKeyProvider: { "k" }, session: StubURLProtocol.session())
        await #expect(throws: SupermuxAIError.requestFailed(status: 401, message: "invalid api key")) {
            try await client.complete(model: "m", system: "s", user: "u", maxOutputTokens: 10)
        }
    }

    @Test func throwsEmptyResponseOnBlankContent() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8))
        }
        let client = SupermuxAIGatewayClient(apiKeyProvider: { "k" }, session: StubURLProtocol.session())
        await #expect(throws: SupermuxAIError.emptyResponse) {
            try await client.complete(model: "m", system: "s", user: "u", maxOutputTokens: 10)
        }
    }

    @Test func reportsConfiguredState() async {
        let configured = SupermuxAIGatewayClient(apiKeyProvider: { "k" }, session: StubURLProtocol.session())
        let unconfigured = SupermuxAIGatewayClient(apiKeyProvider: { "  " }, session: StubURLProtocol.session())
        #expect(await configured.isConfigured())
        #expect(await unconfigured.isConfigured() == false)
    }
}

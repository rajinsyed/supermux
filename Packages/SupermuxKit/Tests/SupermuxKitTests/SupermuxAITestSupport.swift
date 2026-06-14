import Foundation
@testable import SupermuxKit

/// In-memory ``SupermuxAICompleting`` for testing feature services without HTTP.
actor FakeAICompleting: SupermuxAICompleting {
    private let configured: Bool
    private let response: Result<String, SupermuxAIError>
    private(set) var lastModel: String?
    private(set) var lastSystem: String?
    private(set) var lastUser: String?
    private(set) var lastMaxTokens: Int?

    init(configured: Bool = true, response: Result<String, SupermuxAIError> = .success("")) {
        self.configured = configured
        self.response = response
    }

    func isConfigured() async -> Bool { configured }

    func complete(model: String, system: String, user: String, maxOutputTokens: Int) async throws -> String {
        lastModel = model
        lastSystem = system
        lastUser = user
        lastMaxTokens = maxOutputTokens
        switch response {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

/// `URLProtocol` stub that returns canned responses and captures the request,
/// so ``SupermuxAIGatewayClient`` can be tested without real networking.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

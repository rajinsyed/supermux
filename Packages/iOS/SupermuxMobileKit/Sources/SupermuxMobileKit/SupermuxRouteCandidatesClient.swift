public import CmuxMobileRPC
import Foundation
public import SupermuxMobileCore

/// The production ``SupermuxRouteCandidatesCalling``: one request over the
/// Mac's RPC connection. The Mac answers only an Iroh-admitted session.
public struct SupermuxRouteCandidatesClient: SupermuxRouteCandidatesCalling {
    private let client: MobileCoreRPCClient

    /// Creates the adapter.
    /// - Parameter client: The Mac's RPC client.
    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    public func routeCandidates() async throws -> SupermuxRouteCandidatesDTO {
        let request = try MobileCoreRPCClient.requestData(method: SupermuxMobileMethod.routeCandidates.rawValue)
        let result = try await client.sendRequest(request)
        return try JSONDecoder().decode(SupermuxRouteCandidatesDTO.self, from: result)
    }
}

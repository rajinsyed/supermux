import Foundation

struct GitHubPullRequestStub: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
    let gate: String?
    /// When set, the stub answers with a redirect to this absolute URL instead
    /// of delivering a body, reproducing GitHub's permanent redirect for a
    /// renamed repository (`/repos/owner/old-name/...` -> `/repositories/<id>/...`).
    let redirectLocation: String?

    init(
        statusCode: Int,
        headers: [String: String] = [:],
        data: Data = Data(),
        gate: String? = nil,
        redirectLocation: String? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
        self.gate = gate
        self.redirectLocation = redirectLocation
    }
}

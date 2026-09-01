import Foundation

/// Re-attaches the `Authorization` header when a GitHub API redirect stays on
/// GitHub's own API host.
///
/// **Why this exists.** A repository renamed on GitHub keeps answering its old
/// slug with a permanent redirect to the canonical `/repositories/<id>` path,
/// and a local git remote keeps the old name until someone runs
/// `git remote set-url` — so the probe queries the old slug indefinitely.
/// URLSession follows the redirect but drops the `Authorization` header while
/// building the follow-up request. For a PRIVATE repository the unauthenticated
/// follow-up answers `404` (GitHub returns 404 rather than 403 so it does not
/// disclose that the repo exists), and the probe maps that to "this branch has
/// no pull request" — so the sidebar badge silently never appears, for the life
/// of the checkout.
///
/// Carrying the credential across the redirect costs nothing: the redirect
/// already happens on every poll of a renamed repo, and this only stops the
/// follow-up from being wasted.
///
/// **Scope.** The header is re-added only when the redirect target is GitHub's
/// own API host, so credentials can never leak to another origin.
final class GitHubPullRequestRedirectAuthenticator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// GitHub's REST API host; the only host this delegate will re-authenticate.
    static let githubAPIHost = "api.github.com"

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            Self.authorizedRedirectRequest(
                previous: task.currentRequest,
                proposed: request
            )
        )
    }

    /// The request to follow a redirect with: `proposed`, plus the previous
    /// request's `Authorization` when the target is still GitHub's API host.
    ///
    /// Pure so the credential policy is testable without the loading system.
    /// - Parameters:
    ///   - previous: The request that received the redirect (carries the credential).
    ///   - proposed: The follow-up request URLSession built (credential stripped).
    /// - Returns: The request to issue.
    static func authorizedRedirectRequest(
        previous: URLRequest?,
        proposed: URLRequest
    ) -> URLRequest {
        guard proposed.value(forHTTPHeaderField: "Authorization") == nil,
              proposed.url?.host?.lowercased() == githubAPIHost,
              let authorization = previous?.value(forHTTPHeaderField: "Authorization"),
              !authorization.isEmpty else {
            return proposed
        }
        var authorized = proposed
        authorized.setValue(authorization, forHTTPHeaderField: "Authorization")
        return authorized
    }
}

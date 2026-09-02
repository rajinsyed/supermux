public import Foundation
public import CmuxFoundation

/// Errors from the on-demand GitHub REST client.
public enum SupermuxGitHubError: Error, Equatable, Sendable {
    /// No token in `GH_TOKEN`/`GITHUB_TOKEN` and `gh auth token` produced none.
    case notAuthenticated
    /// The directory has no GitHub remote.
    case notAGitHubRepository
    /// GitHub answered with a non-2xx status; `message` is its error text.
    case http(status: Int, message: String?)
    /// The response body could not be decoded.
    case invalidResponse
    /// The request could not be sent.
    case network(String)
}

extension SupermuxGitHubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(
                localized: "supermux.pullRequest.error.notAuthenticated",
                defaultValue: "Not signed in to GitHub. Run `gh auth login` or set GH_TOKEN."
            )
        case .notAGitHubRepository:
            return String(
                localized: "supermux.pullRequest.error.notGitHub",
                defaultValue: "This repository has no GitHub remote."
            )
        case .http(let status, let message):
            let statusText = String(status)
            if let message, !message.isEmpty {
                return String(
                    localized: "supermux.pullRequest.error.http",
                    defaultValue: "GitHub error \(statusText): \(message)"
                )
            }
            return String(localized: "supermux.pullRequest.error.httpStatus", defaultValue: "GitHub error \(statusText)")
        case .invalidResponse:
            return String(
                localized: "supermux.pullRequest.error.invalidResponse",
                defaultValue: "GitHub returned an unexpected response."
            )
        case .network(let detail):
            return detail
        }
    }
}

/// Authenticated GET against the GitHub REST API, abstracted so the PR detail
/// service can be tested with canned JSON instead of the network.
public protocol SupermuxGitHubRequesting: Sendable {
    /// Performs `GET https://api.github.com/<path>` and returns the body.
    /// - Throws: ``SupermuxGitHubError``.
    func get(path: String) async throws -> Data
}

/// The production GitHub client. Resolves credentials the same way cmux's
/// own PR probe does — `GH_TOKEN`/`GITHUB_TOKEN` from the environment, else
/// `gh auth token` — and never falls back to anonymous requests. The token
/// is resolved lazily on the first request and cached until GitHub rejects
/// it, so one refresh spawns `gh` at most once.
public actor SupermuxGitHubClient: SupermuxGitHubRequesting {
    private static let baseURL = URL(string: "https://api.github.com/")!
    private static let requestTimeout: TimeInterval = 15
    private static let ghTimeout: TimeInterval = 5

    private let session: URLSession
    private let commandRunner: any CommandRunning
    private let environment: [String: String]
    private var cachedToken: String?

    /// Creates a client.
    /// - Parameters:
    ///   - commandRunner: Runs `gh auth token`; tests pass a fake.
    ///   - session: Transport; tests pass a stubbed session.
    ///   - environment: Process environment to read tokens from.
    public init(
        commandRunner: any CommandRunning = CommandRunner(),
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.commandRunner = commandRunner
        self.session = session
        self.environment = environment
    }

    public func get(path: String) async throws -> Data {
        guard let token = await resolveToken() else {
            throw SupermuxGitHubError.notAuthenticated
        }
        guard let url = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw SupermuxGitHubError.invalidResponse
        }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SupermuxGitHubError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SupermuxGitHubError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                // The cached token is no longer valid; re-resolve next time.
                cachedToken = nil
            }
            throw SupermuxGitHubError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    private func resolveToken() async -> String? {
        if let cachedToken { return cachedToken }
        let token = await Self.resolveToken(environment: environment, runner: commandRunner)
        cachedToken = token
        return token
    }

    /// `GH_TOKEN`/`GITHUB_TOKEN` when set, else the GitHub CLI's stored token.
    static func resolveToken(environment: [String: String], runner: any CommandRunning) async -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        let output = await runner.runStandardOutput(
            directory: FileManager.default.currentDirectoryPath,
            executable: "gh",
            arguments: ["auth", "token"],
            timeout: ghTimeout
        )
        let token = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    /// Pulls GitHub's `message` out of an error body, when present.
    static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else {
            return nil
        }
        return message
    }
}

/// Generate & Commit for a device mirror's Changes panel: the Mac that owns
/// the workspace writes the message (`changes.generate_commit_message`) from
/// its own diff with its own AI key — no diff or key crosses the link.
///
/// Offered exactly when that Mac's own panel would offer it (its status
/// reports `ai_commit_configured`; a Mac too old to report it until it answers
/// `ai_unavailable`). The `forDiff` argument (the remote backend's status
/// fingerprint) only feeds the model's staleness guard and is not sent.
public struct SupermuxRemoteCommitMessenger: SupermuxAICommitMessaging {
    private let backend: SupermuxRemoteChangesBackend

    /// Creates the messenger for one remote backend.
    /// - Parameter backend: The mirror's remote Changes backend.
    public init(backend: SupermuxRemoteChangesBackend) {
        self.backend = backend
    }

    public func isConfigured() async -> Bool {
        await backend.isAICommitConfigured
    }

    public func generateMessage(forDiff diff: String) async -> String? {
        await backend.generateCommitMessage()
    }
}

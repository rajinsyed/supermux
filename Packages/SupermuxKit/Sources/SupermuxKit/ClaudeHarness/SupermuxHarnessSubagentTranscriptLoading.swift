/// Loads revisioned, bounded subagent-transcript updates.
public protocol SupermuxHarnessSubagentTranscriptLoading: Sendable {
    /// Loads the current transcript state or the delta after a known revision.
    ///
    /// - Parameters:
    ///   - address: The local-agent or workflow-agent transcript to read.
    ///   - afterRevision: The consumer's last applied logical revision, or `nil` for a replacement.
    /// - Returns: A replacement or incremental update at the latest logical revision.
    /// - Throws: A path-validation or file-reading error.
    func loadTranscript(
        at address: SupermuxHarnessSubagentTranscriptAddress,
        afterRevision: Int?
    ) async throws -> SupermuxHarnessSubagentTranscriptUpdate
}

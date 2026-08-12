/// Validation errors for bounded Claude tool-payload chunks.
public enum SupermuxClaudeToolPayloadChunkError: Error, Sendable, Equatable {
    /// The chunk exceeded ``SupermuxClaudeToolPayloadChunkDTO/maximumDataBytes``.
    case chunkTooLarge(actualBytes: Int)
}

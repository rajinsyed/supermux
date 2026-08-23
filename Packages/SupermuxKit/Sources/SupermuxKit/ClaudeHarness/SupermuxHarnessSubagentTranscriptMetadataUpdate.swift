/// A metadata change carried by an incremental subagent-transcript response.
public enum SupermuxHarnessSubagentTranscriptMetadataUpdate: Equatable, Sendable {
    /// The consumer keeps its existing metadata value.
    case unchanged
    /// Previously visible metadata was deleted or is no longer readable.
    case deleted
    /// The consumer replaces its metadata with this value.
    case value(SupermuxHarnessSubagentTranscriptMetadata)
}

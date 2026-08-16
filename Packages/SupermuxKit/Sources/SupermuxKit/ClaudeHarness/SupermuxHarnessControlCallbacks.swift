/// Asynchronously writes an encoded control frame to the active process.
public typealias SupermuxHarnessControlFrameSender = @MainActor @Sendable (SupermuxHarnessEncodedFrame) async throws -> Void
/// Generates unique client-issued control request identifiers.
public typealias SupermuxHarnessRequestIDGenerator = @MainActor @Sendable () -> String

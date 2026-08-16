/// Receives every valid JSON object parsed from Claude Code stdout.
public typealias SupermuxHarnessProtocolLineSink = @MainActor @Sendable (SupermuxHarnessDecodedLine) -> Void
/// Receives stderr text exactly as it is drained from the process line buffer.
public typealias SupermuxHarnessStderrSink = @MainActor @Sendable (String) -> Void
/// Receives process start and fully-drained exit events.
public typealias SupermuxHarnessLifecycleSink = @MainActor @Sendable (SupermuxHarnessProcessLifecycleEvent) -> Void

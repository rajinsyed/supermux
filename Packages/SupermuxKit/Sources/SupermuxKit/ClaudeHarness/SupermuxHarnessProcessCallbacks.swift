/// Receives every valid JSON object parsed from Claude Code stdout.
/// The process reader awaits completion before it drains the next line.
public typealias SupermuxHarnessProtocolLineSink = @MainActor @Sendable (SupermuxHarnessDecodedLine) async -> Void
/// Receives stderr text exactly as it is drained from the process line buffer.
/// The process reader awaits completion before it drains the next line.
public typealias SupermuxHarnessStderrSink = @MainActor @Sendable (String) async -> Void
/// Receives process start and fully-drained exit events.
public typealias SupermuxHarnessLifecycleSink = @MainActor @Sendable (SupermuxHarnessProcessLifecycleEvent) -> Void

/// Identifies a successfully launched subprocess.
public struct SupermuxHarnessStartedProcess: Equatable, Sendable {
    /// The harness-generated identifier for this run.
    public let runID: String
    /// The operating-system process identifier.
    public let processID: Int32

    /// Creates a started-process value.
    ///
    /// - Parameters:
    ///   - runID: The harness-generated run identifier.
    ///   - processID: The operating-system process identifier.
    public init(runID: String, processID: Int32) {
        self.runID = runID
        self.processID = processID
    }
}

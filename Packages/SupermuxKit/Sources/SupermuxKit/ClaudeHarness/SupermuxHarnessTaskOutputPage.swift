/// A bounded tail read from a Claude background-task output file.
public struct SupermuxHarnessTaskOutputPage: Equatable, Sendable {
    /// The UTF-8-decoded output tail.
    public let text: String
    /// Whether bytes before this tail were omitted.
    public let truncated: Bool
    /// Whether the validated output file does not currently exist.
    public let missing: Bool

    /// Creates a background-task output page.
    ///
    /// - Parameters:
    ///   - text: The decoded output tail.
    ///   - truncated: Whether earlier bytes were omitted.
    ///   - missing: Whether the output file is absent.
    public init(text: String, truncated: Bool, missing: Bool) {
        self.text = text
        self.truncated = truncated
        self.missing = missing
    }
}

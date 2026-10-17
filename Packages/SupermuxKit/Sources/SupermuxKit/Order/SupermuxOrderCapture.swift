/// Placeholder: the capture planner (design §3.2.3).
public struct SupermuxOrderCapture: Sendable {
    public init() {}

    public func plan<ID>(
        baseline: [SupermuxOrderPosition<ID>]?,
        rows: [SupermuxOrderCaptureRow<ID>],
        hinted: Set<ID>,
        programmatic: Set<ID>,
        known: [String],
        seed: String
    ) -> SupermuxOrderCapturePlan<ID> {
        SupermuxOrderCapturePlan()
    }
}

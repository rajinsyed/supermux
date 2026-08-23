/// Targeted range-read result for one stable file observation.
struct SupermuxHarnessSessionSelectedRead: Sendable {
    let before: SupermuxHarnessSessionFileObservation
    let after: SupermuxHarnessSessionFileObservation
    let pathAfter: SupermuxHarnessSessionFileObservation
    let prefixValidated: Bool
    let events: [SupermuxHarnessJSONObject]
    let recordCount: Int
    let bytesRead: UInt64
    let maximumReadChunkBytes: Int

    var isStable: Bool { before == after && after == pathAfter }

    func preservesPrefix(_ expected: SupermuxHarnessSessionFileObservation) -> Bool {
        prefixValidated
            && before.isSameOrAppend(of: expected)
            && after.isSameOrAppend(of: before)
            && pathAfter.isSameOrAppend(of: before)
    }
}

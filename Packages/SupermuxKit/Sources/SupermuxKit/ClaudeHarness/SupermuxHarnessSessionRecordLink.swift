/// Parent-chain metadata retained for one UUID-bearing session record.
struct SupermuxHarnessSessionRecordLink: Sendable {
    let parentUUID: String?
    let isVisible: Bool

    var byteCost: Int {
        32 + (parentUUID?.utf8.count ?? 0)
    }
}

/// Stable filesystem identity across path replacement and inode reuse.
struct SupermuxHarnessSessionFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

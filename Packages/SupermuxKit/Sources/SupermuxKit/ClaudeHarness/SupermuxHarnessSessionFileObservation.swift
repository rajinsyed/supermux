import Darwin
import Foundation

/// Filesystem observation used to validate a cached JSONL state.
struct SupermuxHarnessSessionFileObservation: Equatable, Sendable {
    let canonicalPath: String
    let identity: SupermuxHarnessSessionFileIdentity
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    func isSameOrAppend(of earlier: SupermuxHarnessSessionFileObservation) -> Bool {
        self == earlier || (
            canonicalPath == earlier.canonicalPath
                && identity == earlier.identity
                && size > earlier.size
        )
    }

    init(fileURL: URL, status: stat) {
        canonicalPath = SupermuxHarnessSessionPathPolicy.canonicalFileURL(fileURL).path
        identity = SupermuxHarnessSessionFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            birthSeconds: Int64(status.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(status.st_birthtimespec.tv_nsec)
        )
        size = UInt64(max(0, status.st_size))
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }
}

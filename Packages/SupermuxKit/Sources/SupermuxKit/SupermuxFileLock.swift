import Darwin
import Foundation

/// An exclusive cross-process `flock` on a sidecar `<document>.lock` file,
/// held around one read-modify-write of a JSON document that every build on
/// this Mac shares (stable, nightly and tagged DEV builds run side by side).
///
/// The lock lives on the sidecar, which is never renamed, because the
/// document itself is replaced by an atomic rename on every save, so an
/// `flock` on the document's fd would reference a dead inode after the first
/// write. Each ``acquire()`` opens its own descriptor, and `flock` locks on
/// separate descriptors conflict even inside one process, so concurrent
/// writers in this process are serialized too. The lock is taken
/// non-blockingly with a backoff retry, so a contended wait suspends the task
/// instead of pinning a cooperative-pool thread; holders only ever perform one
/// small read-decode-encode-write, so contention is brief.
///
/// ```swift
/// let lock = SupermuxFileLock(documentURL: fileURL)
/// let held = try await lock.acquire()
/// defer { lock.release(held) }
/// var document = read()   // re-read under the lock, then mutate and write
/// ```
struct SupermuxFileLock: Sendable {
    /// The document the lock guards; the lock file is `<document>.lock`.
    let documentURL: URL

    /// Waits for the exclusive lock and returns its descriptor for ``release(_:)``.
    /// - Throws: A POSIX error from opening or locking the lock file, or the
    ///   cancellation error when the task is cancelled while waiting.
    func acquire() async throws -> Int32 {
        let directory = documentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(documentURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Self.posixError("open", code: errno) }
        var delay: UInt64 = 10_000_000
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw Self.posixError("flock", code: code)
            }
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                close(fd)
                throw error
            }
            delay = min(delay * 2, 250_000_000)
        }
        return fd
    }

    /// Releases a lock taken by ``acquire()``.
    /// - Parameter fd: The descriptor ``acquire()`` returned.
    func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    private static func posixError(_ operation: String, code: Int32) -> any Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code)))"]
        )
    }
}

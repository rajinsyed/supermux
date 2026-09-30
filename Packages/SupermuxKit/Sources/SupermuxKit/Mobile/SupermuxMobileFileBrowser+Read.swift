import Darwin
public import Foundation
public import SupermuxMobileCore

/// `files.read`: one bounded chunk of a regular file inside the root, for
/// another Mac's read-only preview (it reads chunk after chunk until `eof`).
extension SupermuxMobileFileBrowser {
    /// The most bytes one chunk carries: 512 KiB, about 700 KB of base64 on
    /// the wire, far inside the device link's frame cap and reply deadline.
    public static let maxReadChunk = 512 * 1024

    /// Reads up to `length` bytes (clamped to ``maxReadChunk``; `0` or less
    /// asks for a full chunk) of the regular file at root-relative `path`,
    /// starting at `offset`.
    ///
    /// The path is confined like every other call, except that git internals
    /// are readable (the desktop panel shows them with hidden files on). The
    /// file actually opened is checked again through its descriptor, so a
    /// symlink swapped in between the check and the open cannot redirect the
    /// read outside the root.
    /// - Throws: ``SupermuxMobileFileBrowserError/pathOutsideRoot(path:)`` for
    ///   an escape; ``SupermuxMobileFileBrowserError/invalidPath(path:)`` for
    ///   the root, a directory or other non-regular file, or an offset outside
    ///   the file; ``SupermuxMobileFileBrowserError/notFound(path:)`` for a
    ///   missing entry.
    public func read(path: String, offset: Int, length: Int) throws -> SupermuxFileReadDTO {
        guard !path.isEmpty else { throw SupermuxMobileFileBrowserError.invalidPath(path: path) }
        let url = try resolveExisting(path, allowRoot: false, allowGitInternals: true)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT
                ? SupermuxMobileFileBrowserError.notFound(path: path)
                : SupermuxMobileFileBrowserError.invalidPath(path: path)
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw SupermuxMobileFileBrowserError.invalidPath(path: path)
        }
        guard let opened = Self.openedPath(descriptor), contains(opened) else {
            throw SupermuxMobileFileBrowserError.pathOutsideRoot(path: path)
        }
        let size = Int(info.st_size)
        guard offset >= 0, offset <= size else {
            throw SupermuxMobileFileBrowserError.invalidPath(path: path)
        }
        let wanted = length > 0 ? min(length, Self.maxReadChunk) : Self.maxReadChunk
        let data = try Self.read(descriptor, count: min(wanted, size - offset), at: offset, path: path)
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return SupermuxFileReadDTO(
            path: relativePath(of: url),
            size: size,
            modifiedAt: modified,
            offset: offset,
            length: data.count,
            eof: offset + data.count >= size,
            data: data.base64EncodedString()
        )
    }

    /// Whether an absolute path (in any spelling) resolves inside the root.
    private func contains(_ path: String) -> Bool {
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return canonical == rootPath || SupermuxFileSystemOperations.pathIsAncestor(rootPath, of: canonical)
    }

    /// The path the kernel opened for a descriptor (`F_GETPATH`).
    private static func openedPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) >= 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Up to `count` bytes at `offset`; fewer when the file shrank meanwhile.
    private static func read(_ descriptor: Int32, count: Int, at offset: Int, path: String) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        var filled = 0
        try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while filled < count {
                let read = pread(descriptor, base + filled, count - filled, off_t(offset + filled))
                if read < 0, errno == EINTR { continue }
                if read < 0 { throw SupermuxMobileFileBrowserError.invalidPath(path: path) }
                if read == 0 { break }
                filled += read
            }
        }
        buffer.count = filled
        return buffer
    }
}

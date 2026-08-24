import Darwin
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads supported project-local images without following filesystem symlinks.
public struct SupermuxHarnessImageReader: Sendable {
    private static let readChunkBytes = 64 * 1024

    private let rootURL: URL
    private let maximumBytes: Int

    /// Creates an image reader scoped to one trusted working directory.
    ///
    /// The root itself may arrive through a symlink, but every image path below its
    /// physical location must contain only direct directory and regular-file entries.
    ///
    /// - Parameters:
    ///   - rootURL: The pane's native working directory.
    ///   - maximumBytes: The file-size limit, capped at the shared 10 MiB image ceiling.
    public init(
        rootURL: URL,
        maximumBytes: Int = SupermuxHarnessAttachmentPolicy.maximumImageBytes
    ) {
        let resolved = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.rootURL = URL(
            fileURLWithPath: Self.physicalSystemAliasPath(resolved.path),
            isDirectory: true
        )
        self.maximumBytes = min(
            max(0, maximumBytes),
            SupermuxHarnessAttachmentPolicy.maximumImageBytes
        )
    }

    /// Reads one decoded relative POSIX path beneath the configured root.
    ///
    /// - Parameter relativePath: A URL-decoded project-relative image path.
    /// - Returns: The detected MIME type and base64-encoded file bytes.
    /// - Throws: ``SupermuxHarnessImageReaderError/unavailable`` for every rejection.
    public func read(relativePath: String) throws -> SupermuxHarnessImage {
        let components = try Self.validatedComponents(relativePath)
        let rootDescriptor = try Self.openRootDirectory(rootURL)
        defer { Darwin.close(rootDescriptor) }
        let descriptor = try Self.openRegularFile(
            beneath: rootDescriptor,
            components: components
        )
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size > 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw SupermuxHarnessImageReaderError.unavailable
        }

        let data = try readBounded(descriptor)
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let mediaType = Self.detectedMediaType(data) else {
            throw SupermuxHarnessImageReaderError.unavailable
        }
        return SupermuxHarnessImage(
            mediaType: mediaType,
            dataBase64: data.base64EncodedString()
        )
    }

    private func readBounded(_ descriptor: Int32) throws -> Data {
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let count = min(Self.readChunkBytes, remaining)
            var buffer = [UInt8](repeating: 0, count: count)
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw SupermuxHarnessImageReaderError.unavailable
            }
            if bytesRead == 0 { return data }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    private static func validatedComponents(_ relativePath: String) throws -> [Substring] {
        guard !relativePath.isEmpty,
              !relativePath.unicodeScalars.contains("\0"),
              relativePath.utf8.count < Int(PATH_MAX),
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\"),
              !relativePath.contains("?"),
              !relativePath.contains("#"),
              !hasURLScheme(relativePath) else {
            throw SupermuxHarnessImageReaderError.unavailable
        }

        var normalized = relativePath[...]
        while normalized.hasPrefix("./") {
            normalized = normalized.dropFirst(2)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({
                  !$0.isEmpty &&
                      $0 != "." &&
                      $0 != ".." &&
                      $0.utf8.count <= Int(NAME_MAX)
              }) else {
            throw SupermuxHarnessImageReaderError.unavailable
        }
        return components
    }

    private static func hasURLScheme(_ path: String) -> Bool {
        guard let colon = path.firstIndex(of: ":") else { return false }
        let prefix = path[..<colon]
        guard !prefix.isEmpty,
              prefix.first?.isASCII == true,
              prefix.first?.isLetter == true else {
            return false
        }
        return prefix.allSatisfy { character in
            character.isASCII &&
                (character.isLetter || character.isNumber || character == "+" ||
                    character == "-" || character == ".")
        }
    }

    private static func openRootDirectory(_ rootURL: URL) throws -> Int32 {
        guard rootURL.path.hasPrefix("/") else {
            throw SupermuxHarnessImageReaderError.unavailable
        }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw SupermuxHarnessImageReaderError.unavailable
        }

        for component in rootURL.pathComponents.dropFirst() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                )
            }
            Darwin.close(descriptor)
            guard nextDescriptor >= 0 else {
                throw SupermuxHarnessImageReaderError.unavailable
            }
            descriptor = nextDescriptor
        }
        return descriptor
    }

    private static func openRegularFile(
        beneath rootDescriptor: Int32,
        components: [Substring]
    ) throws -> Int32 {
        var parentDescriptor = rootDescriptor
        var ownsParentDescriptor = false
        defer {
            if ownsParentDescriptor { Darwin.close(parentDescriptor) }
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                throw SupermuxHarnessImageReaderError.unavailable
            }
            if ownsParentDescriptor { Darwin.close(parentDescriptor) }
            parentDescriptor = nextDescriptor
            ownsParentDescriptor = true
        }

        guard let fileName = components.last else {
            throw SupermuxHarnessImageReaderError.unavailable
        }
        let descriptor = fileName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw SupermuxHarnessImageReaderError.unavailable
        }
        return descriptor
    }

    private static func physicalSystemAliasPath(_ path: String) -> String {
        let aliases = ["/tmp", "/var", "/etc"]
        return aliases.contains(where: { alias in
            path == alias || path.hasPrefix("\(alias)/")
        }) ? "/private\(path)" : path
    }

    private static func detectedMediaType(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil,
              let identifier = CGImageSourceGetType(source) as String?,
              let mediaType = UTType(identifier)?.preferredMIMEType,
              SupermuxHarnessAttachmentPolicy.supportedMediaTypes.contains(mediaType) else {
            return nil
        }
        return mediaType
    }
}

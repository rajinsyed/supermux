// SUPERMUX:begin runtime-cloud-mutations-socket-fixture
import Darwin
import Foundation
import Testing

/// A real JSON-lines peer for the production persistent request channel.
actor RuntimeCloudMutationsSocket {
    nonisolated let path: String
    private let listener: Int32
    private let accepted: Task<Int32, Error>
    private var peer: Int32?

    init() throws {
        path = NSTemporaryDirectory() + "cm-\(UUID().uuidString.prefix(12)).sock"
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        let descriptor = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        address.sun_len = UInt8(2 + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(2 + bytes.count))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            let error = NSError(domain: "fixture.bind", code: Int(errno))
            Darwin.close(listener)
            throw error
        }
        accepted = Task {
            try await Self.performBlockingIO {
                let result = Darwin.accept(descriptor, nil, nil)
                guard result >= 0 else { throw NSError(domain: "fixture.accept", code: Int(errno)) }
                var noSignal: Int32 = 1
                setsockopt(result, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                return result
            }
        }
    }

    func next() async throws -> Data {
        let descriptor = try await accepted.value
        peer = descriptor
        return try await Self.performBlockingIO {
            var result = Data()
            var byte: UInt8 = 0
            while true {
                let count = Darwin.read(descriptor, &byte, 1)
                if count < 0, errno == EINTR { continue }
                guard count == 1 else {
                    throw NSError(domain: "fixture.read", code: count == 0 ? -1 : Int(errno))
                }
                if byte == 0x0A { return result }
                result.append(byte)
            }
        }
    }

    func reply(to request: Data, result: [String: String]) async throws {
        let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let id = try #require(object["id"] as? String)
        let response = try JSONSerialization.data(withJSONObject: [
            "id": id, "protocol": "cmux.protocol/2", "type": "response", "ok": true, "result": result
        ]) + Data([0x0A])
        let descriptor = try await accepted.value
        peer = descriptor
        try await Self.performBlockingIO {
            try response.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw NSError(domain: "fixture.write", code: Int(errno)) }
                    offset += written
                }
            }
        }
    }

    func close() {
        if let peer { Darwin.shutdown(peer, SHUT_RDWR); Darwin.close(peer); self.peer = nil }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(path)
    }

    private static func performBlockingIO<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            // POSIX calls must not block Swift's cooperative executor.
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
// SUPERMUX:end runtime-cloud-mutations-socket-fixture

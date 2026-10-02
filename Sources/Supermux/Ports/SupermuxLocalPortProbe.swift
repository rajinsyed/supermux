import Darwin
import Foundation

/// Whether something on this Mac already listens on a loopback port.
///
/// A port forward must never take a port in use here. Binding alone cannot
/// tell: an IPv4-specific bind of `127.0.0.1:P` can succeed while a dual-stack
/// `[::]:P` listener (Node's default) holds the port, and would then silently
/// steal that server's `127.0.0.1` traffic. So the probe connects instead, to
/// `127.0.0.1:P` and `[::1]:P`; a connection on either means the port is taken.
enum SupermuxLocalPortProbe {
    /// How long one connect may take before the port counts as free (a
    /// loopback refusal is immediate; this bounds a listener that never answers).
    static let timeoutMilliseconds: Int32 = 150

    /// Connects to the port on both loopback addresses, off the main thread.
    static func isInUse(_ port: Int) async -> Bool {
        await Task.detached(priority: .utility) {
            connects(ipv6: false, port: port) || connects(ipv6: true, port: port)
        }.value
    }

    /// One non-blocking connect to `127.0.0.1:port` or `[::1]:port`.
    private static func connects(ipv6: Bool, port: Int) -> Bool {
        guard let networkPort = UInt16(exactly: port) else { return false }
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = networkPort.bigEndian
            address.sin6_addr.__u6_addr.__u6_addr8.15 = 1 // ::1
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = networkPort.bigEndian
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian // 127.0.0.1
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, timeoutMilliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

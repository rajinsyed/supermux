// SUPERMUX:begin runtime-ssh-tmux-progress-fixture
#if RUNTIME_SSH_TMUX_HARNESS
import Darwin
import Foundation

// Only dependencies outside the owned reporter are substituted. The reporter's
// thread, polling, stop and print code are compiled from its full production file.
struct CMUXCLI {
    func sshAskpassExecShellScript(passwordFilePath: String, cleanupDirectory: String) throws -> String {
        throw CLIError(message: "Authentication is not exercised by this harness")
    }
    func setTerminalForegroundProcessGroup(_ group: pid_t) throws {
        throw CLIError(message: "TTY authentication is not exercised by this harness")
    }
}

#if !RUNTIME_SSH_TMUX_TUI_HARNESS
func cliRunProcess(_ process: Process) throws {
    throw CLIError(message: "Authentication is not exercised by this harness")
}
#endif

func withRuntimeUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    precondition(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func runtimeReadLine(_ fd: Int32) throws -> Data {
    var data = Data()
    while data.count < 8192 {
        var byte: UInt8 = 0
        guard Darwin.read(fd, &byte, 1) == 1 else { throw CLIError(message: "Fixture connection ended") }
        if byte == 10 { return data }
        data.append(byte)
    }
    throw CLIError(message: "Fixture frame exceeds bound")
}

final class SocketClient {
    private let path: String
    private var fd: Int32 = -1
    init(path: String) { self.path = path }
    func connect() throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0,
              withRuntimeUnixAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
            throw CLIError(message: "Fixture socket connection failed")
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func sendV2(method: String, params: [String: Any], responseTimeout: TimeInterval) throws -> [String: Any] {
        var data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        data.append(10)
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw CLIError(message: "Fixture write failed") }
        return try JSONSerialization.jsonObject(with: runtimeReadLine(fd)) as! [String: Any]
    }
}

actor RuntimeSshTmuxSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }
}

final class RuntimeSshTmuxProgressSocket: @unchecked Sendable {
    let path: String
    let requestReceived = RuntimeSshTmuxSignal()
    let completed = RuntimeSshTmuxSignal()
    let releaseReply = DispatchSemaphore(value: 0)
    private let root: URL
    private let fd: Int32
    private let lock = NSLock()
    private var requestMethod: String?
    private var requestParams: [String: Any] = [:]
    private var failure: String?

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("st-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        path = root.appendingPathComponent("p.sock").path
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, withRuntimeUnixAddress(path, { Darwin.bind(fd, $0, $1) }) == 0,
              listen(fd, 1) == 0 else { throw CLIError(message: "Fixture bind failed") }
    }

    func start() {
        Thread.detachNewThread { [self] in
            defer { Task { await completed.signal() } }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }
            defer { Darwin.close(connection) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            do {
                let request = try JSONSerialization.jsonObject(with: runtimeReadLine(connection)) as! [String: Any]
                lock.lock()
                requestMethod = request["method"] as? String
                requestParams = request["params"] as? [String: Any] ?? [:]
                lock.unlock()
                Task { await requestReceived.signal() }
                guard releaseReply.wait(timeout: .now() + 10) == .success else {
                    throw CLIError(message: "Fixture reply gate was never released")
                }
                let reply = Data("{\"attaching\":true,\"phase\":\"in_tmux\"}\n".utf8)
                let sent = reply.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
                guard sent == reply.count else { throw CLIError(message: "Fixture response write failed") }
                // EOF proves the reporter finished its post-reply print path.
                var byte: UInt8 = 0
                guard Darwin.read(connection, &byte, 1) == 0 else {
                    throw CLIError(message: "Reporter did not close after stop")
                }
            } catch {
                lock.lock()
                failure = String(describing: error)
                lock.unlock()
                Task { await requestReceived.signal() }
            }
        }
    }

    func result() -> (String?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (requestMethod, failure)
    }

    func parameters() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return requestParams
    }

    func cleanup() {
        releaseReply.signal()
        Darwin.close(fd)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-progress-fixture

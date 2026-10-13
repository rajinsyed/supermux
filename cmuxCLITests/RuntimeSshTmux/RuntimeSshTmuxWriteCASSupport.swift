// SUPERMUX:begin runtime-ssh-tmux-write-cas-fixture
#if RUNTIME_SSH_TMUX_HARNESS
import Foundation

// Compile the complete production CLI consumers; substitute only their socket
// transport, output sink and unrelated lifecycle/handle-resolution dependencies.
enum CLIIDFormat { case uuids }

final class SocketClient {
    let reply: (String, [String: Any]) throws -> [String: Any]
    init(reply: @escaping (String, [String: Any]) throws -> [String: Any]) { self.reply = reply }
    func sendV2(method: String, params: [String: Any] = [:], responseTimeout: TimeInterval = 5) throws -> [String: Any] {
        try reply(method, params)
    }
}

struct CMUXCLI {
    var payloadSink: ([String: Any]) -> Void = { _ in }
    func printV2Payload(_ payload: [String: Any], jsonOutput: Bool, idFormat: CLIIDFormat, fallbackText: String) {
        payloadSink(payload)
    }
    func resolvePath(_ path: String) -> String { (path as NSString).expandingTildeInPath }
    func intFromAny(_ value: Any?) -> Int? { value as? Int }
    func normalizeWindowHandle(_ raw: String?, client: SocketClient) throws -> String? { raw }
    func normalizePaneHandle(_ raw: String, client: SocketClient, workspaceHandle: String) throws -> String? { raw }
    func normalizeSurfaceHandle(_ raw: String, client: SocketClient, workspaceHandle: String) throws -> String? { raw }
    func listLocalTmuxSessions(registry: LocalTmuxSessionRegistry, builder: LocalTmuxCommandBuilder,
                               runner: LocalTmuxProcessRunner, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        throw CLIError(message: "List is outside the write-CAS harness")
    }
    func statusLocalTmuxSession(record: LocalTmuxSessionRecord, registry: LocalTmuxSessionRegistry,
                                builder: LocalTmuxCommandBuilder, runner: LocalTmuxProcessRunner,
                                jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        throw CLIError(message: "Status is outside the write-CAS harness")
    }
    func cleanupLocalTmuxSessions(registry: LocalTmuxSessionRegistry, builder: LocalTmuxCommandBuilder,
                                  runner: LocalTmuxProcessRunner, prune: Bool, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        throw CLIError(message: "Cleanup is outside the write-CAS harness")
    }
    func closeLocalTmuxSession(record: LocalTmuxSessionRecord, registry: LocalTmuxSessionRegistry,
                               builder: LocalTmuxCommandBuilder, runner: LocalTmuxProcessRunner,
                               jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        throw CLIError(message: "Close is outside the write-CAS harness")
    }
    func detachLocalTmuxSession(record: LocalTmuxSessionRecord, invocation: LocalTmuxInvocation,
                                registry: LocalTmuxSessionRegistry, builder: LocalTmuxCommandBuilder,
                                runner: LocalTmuxProcessRunner, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        throw CLIError(message: "Detach is outside the write-CAS harness")
    }
    func runLocalTmuxInteractiveAttach(session: LocalTmuxSessionIdentityResolver.LiveSession,
                                      builder: LocalTmuxCommandBuilder) throws {
        throw CLIError(message: "Interactive attach is outside the write-CAS harness")
    }
    func printLocalTmuxRecord(_ record: LocalTmuxSessionRecord, jsonOutput: Bool, idFormat: CLIIDFormat, state: String) {
        preconditionFailure("Lifecycle output is outside the write-CAS harness")
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-write-cas-fixture

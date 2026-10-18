// SUPERMUX:begin runtime-ssh-tmux-tui-fixture
#if RUNTIME_SSH_TMUX_TUI_HARNESS
import Foundation

struct VMDaemonWebSocketEndpoint {}
enum CLIIDFormat { case refs }

extension CMUXCLI {
    func applyWindowOrCallerContext(to params: inout [String: Any], client: SocketClient, windowRaw: String?) throws {}
    func printV2Payload(_ response: [String: Any], jsonOutput: Bool, idFormat: CLIIDFormat, fallbackText: String) {}
    func v2CreationSummary(_ response: [String: Any], idFormat: CLIIDFormat, kinds: [String]) -> String { "fixture result" }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-tui-fixture

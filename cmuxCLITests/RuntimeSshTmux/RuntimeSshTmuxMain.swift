// SUPERMUX:begin runtime-ssh-tmux-test-entrypoint
#if RUNTIME_SSH_TMUX_HARNESS
import Darwin
import Testing

@main struct RuntimeSshTmuxMain {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
#endif
// SUPERMUX:end runtime-ssh-tmux-test-entrypoint

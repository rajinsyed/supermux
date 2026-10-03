import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSimulator
import CmuxSimulatorWorker
import Darwin

/// Routes a re-executed cmux process into its requested isolated worker mode.
struct CmuxWorkerEntrypoint {
    private let arguments: [String]

    /// Creates a worker router for one process argument snapshot.
    init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Runs the requested worker instead of continuing normal app startup.
    func runIfRequested() {
        if arguments.contains(
            TerminalPastePreparationWorkerClient.workerModeArgument
        ) {
            exit(
                TerminalPastePreparationWorker().run(
                    arguments: arguments
                )
            )
        }
        if arguments.contains(SimulatorWorkerClient.workerModeArgument) {
            // SUPERMUX:begin worker-quit-forwarding (a quit sent to the app's bundle id that reaches this worker goes on to the app)
            SupermuxWorkerQuitForwarding.install()
            // SUPERMUX:end worker-quit-forwarding
            runSimulatorWorker()
        }
        if arguments.contains(RenderWorkerClient.workerModeArgument) {
            // SUPERMUX:begin worker-quit-forwarding (as above, for the other NSApplication worker)
            SupermuxWorkerQuitForwarding.install()
            // SUPERMUX:end worker-quit-forwarding
            runSidebarRenderWorker()
        }
        if arguments.contains(InterpreterClient.workerModeArgument) {
            runSidebarInterpreterWorker()
            exit(0)
        }
    }
}

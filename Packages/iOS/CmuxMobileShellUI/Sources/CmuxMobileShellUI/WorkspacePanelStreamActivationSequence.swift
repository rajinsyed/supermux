// SUPERMUX:begin supermux-mobile-selection-sync
/// Orders a streamed panel transition behind the Mac focus mutation that makes
/// the browser or Simulator source operable.
@MainActor
/// lint:allow namespace-enum — a stateless ordering policy shared by browser and Simulator flows.
enum WorkspacePanelStreamActivationSequence {
    static func run(
        focusTask: Task<Bool, Never>?,
        isSelectionCurrent: () -> Bool,
        stopPrevious: () async -> Void,
        abandonCurrent: () async -> Void,
        startCurrent: () async -> Void
    ) async {
        let focusSucceeded = await focusTask?.value ?? true
        // This transition captured ownership of the previous stream before the
        // new panel became active. Always settle that stream, even if a newer
        // selection superseded this transition while focus was in flight.
        await stopPrevious()
        // The stop suspends on a panel-scoped RPC chain. Recheck afterward so an
        // older transition can never start last and steal stream ownership.
        guard focusSucceeded, isSelectionCurrent() else {
            await abandonCurrent()
            return
        }
        await startCurrent()
    }
}
// SUPERMUX:end supermux-mobile-selection-sync

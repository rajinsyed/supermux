internal import GhosttyKit
#if DEBUG
internal import CMUXDebugLog
#endif

extension TerminalSurface {
    /// Applies one renderer/PTY size mutation through the observable owner boundary.
    @MainActor
    func applySurfaceSize(
        _ surface: ghostty_surface_t,
        width: UInt32,
        height: UInt32,
        caller: StaticString
    ) {
        let work = terminalWork.begin(.resizePublication, workspaceID: tabId)
        defer { work?.end() }
        // SUPERMUX:begin terminal-stream-grid-generation (upstream reads `previous` in DEBUG only)
        let previous = ghostty_surface_size(surface)
        // SUPERMUX:end terminal-stream-grid-generation

        ghostty_surface_set_size(surface, width, height)
        // SUPERMUX:begin terminal-stream-grid-generation
        let supermuxApplied = ghostty_surface_size(surface)
        if supermuxApplied.columns != previous.columns || supermuxApplied.rows != previous.rows {
            supermuxGridRequestGeneration &+= 1
        }
        // SUPERMUX:end terminal-stream-grid-generation

        #if DEBUG
        let applied = ghostty_surface_size(surface)
        logDebugEvent(
            "surface.size.apply surface=\(id.uuidString.prefix(8)) caller=\(caller) " +
            "grid=\(previous.columns)x\(previous.rows)->\(applied.columns)x\(applied.rows) " +
            "pixels=\(previous.width_px)x\(previous.height_px)->\(applied.width_px)x\(applied.height_px) " +
            "target=\(width)x\(height)"
        )
        #endif
    }
}

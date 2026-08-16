/// Creates a terminal surface and submits a Supermux command through its input queue.
///
/// Command surfaces start blank, then receive the command as explicit terminal input.
/// This uses the same ordered queue as socket sends, so a cold PTY cannot silently
/// drop startup input. If the surface cannot accept the input, the caller-provided
/// rollback removes the otherwise-empty terminal.
public struct SupermuxCommandSurfaceLaunch: Sendable {
    /// Creates the stateless command-surface launcher.
    public init() {}

    /// Creates a surface, submits `command`, and rolls the surface back on failure.
    ///
    /// - Parameters:
    ///   - command: Shell command to submit through the new surface's input path.
    ///   - createSurface: Creates a blank command surface.
    ///   - submitInput: Sends ordered terminal input to the created surface.
    ///   - discardSurface: Removes a created surface when input is rejected.
    /// - Returns: The created surface after its command was accepted, or `nil`.
    @MainActor
    public func launch<Surface>(
        command: String,
        createSurface: () -> Surface?,
        submitInput: (Surface, String) -> Bool,
        discardSurface: (Surface) -> Void
    ) -> Surface? {
        guard let surface = createSurface() else { return nil }
        guard submitInput(surface, SupermuxCommandLaunch.shellInput(for: command)) else {
            discardSurface(surface)
            return nil
        }
        return surface
    }
}

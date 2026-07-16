public import SwiftUI

/// The run indicator + start/stop control shared by project rows and the
/// project detail's Run section (one control, two mounts — shared-behavior
/// policy).
///
/// - Running: a steady green dot (the desktop `SupermuxRunIndicator`'s green,
///   `run.state`-driven) plus a stop button.
/// - Stopped, one run command: a play button that starts the default run
///   (no `command_id` — desktop ⌘G semantics).
/// - Stopped, several run commands: a play MENU offering "Run All" (no
///   `command_id`) and each non-blank command by its ORIGINAL 0-based index.
///
/// Pure value view below the `List` boundary: an immutable
/// ``SupermuxProjectRunState`` snapshot plus start/stop closures — no store
/// reference. Errors surface in a local alert, never silently.
public struct SupermuxProjectRunControl: View {
    private let projectID: String
    private let run: SupermuxProjectRunState
    private let runCommands: [String]
    private let startRun: @MainActor (_ projectID: String, _ commandID: Int?) async throws -> Void
    private let stopRun: @MainActor (_ projectID: String) async throws -> Void

    /// Whether a start/stop request is on the wire (control disabled).
    @State private var isBusy = false
    /// Error surface for a failed start/stop — never a silent no-op.
    @State private var errorMessage: String?

    /// Creates the control.
    /// - Parameters:
    ///   - projectID: The project's UUID string.
    ///   - run: The row's immutable run-state snapshot.
    ///   - runCommands: The project's RAW `run_commands` (DTO order —
    ///     `command_id` indexes exactly this array).
    ///   - startRun: `run.start` by project id + optional command index.
    ///   - stopRun: `run.stop` by project id.
    public init(
        projectID: String,
        run: SupermuxProjectRunState,
        runCommands: [String],
        startRun: @escaping @MainActor (_ projectID: String, _ commandID: Int?) async throws -> Void,
        stopRun: @escaping @MainActor (_ projectID: String) async throws -> Void
    ) {
        self.projectID = projectID
        self.run = run
        self.runCommands = runCommands
        self.startRun = startRun
        self.stopRun = stopRun
    }

    /// The non-blank commands with their ORIGINAL 0-based indexes (blank
    /// entries are skipped for display, never re-indexed — the index is the
    /// wire `command_id`).
    private var startableCommands: [(index: Int, command: String)] {
        runCommands.enumerated().compactMap { index, command in
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (index, trimmed)
        }
    }

    public var body: some View {
        HStack(spacing: 8) {
            if run.isRunning {
                SupermuxRunActiveDot()
            }
            control
        }
        .alert(
            String(
                localized: "supermux.run.failed.title",
                defaultValue: "Couldn’t Update Run",
                bundle: .module
            ),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            presenting: errorMessage
        ) { _ in
            Button(role: .cancel) {
                errorMessage = nil
            } label: {
                Text(String(localized: "supermux.common.ok", defaultValue: "OK", bundle: .module))
            }
        } message: { message in
            Text(message)
        }
        .accessibilityIdentifier("SupermuxRunControl-\(projectID)")
    }

    @ViewBuilder
    private var control: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else if run.isRunning {
            Button {
                perform { try await stopRun(projectID) }
            } label: {
                Image(systemName: "stop.circle")
                    .font(.body)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "supermux.run.stop",
                defaultValue: "Stop Run",
                bundle: .module
            ))
        } else if startableCommands.count > 1 {
            Menu {
                Button {
                    perform { try await startRun(projectID, nil) }
                } label: {
                    Text(String(
                        localized: "supermux.run.runAll",
                        defaultValue: "Run All Commands",
                        bundle: .module
                    ))
                }
                Divider()
                ForEach(startableCommands, id: \.index) { entry in
                    Button {
                        perform { try await startRun(projectID, entry.index) }
                    } label: {
                        Text(entry.command)
                    }
                }
            } label: {
                Image(systemName: "play.circle")
                    .font(.body)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "supermux.run.start",
                defaultValue: "Start Run",
                bundle: .module
            ))
        } else {
            Button {
                perform { try await startRun(projectID, nil) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.body)
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(
                localized: "supermux.run.start",
                defaultValue: "Start Run",
                bundle: .module
            ))
        }
    }

    /// Runs one start/stop request with the busy gate and the error alert.
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The steady green "running" dot: `run.state`-driven, matching the desktop
/// run indicator's green and the phone's activity-dot sizing.
struct SupermuxRunActiveDot: View {
    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .accessibilityLabel(String(
                localized: "supermux.run.running",
                defaultValue: "Running",
                bundle: .module
            ))
    }
}

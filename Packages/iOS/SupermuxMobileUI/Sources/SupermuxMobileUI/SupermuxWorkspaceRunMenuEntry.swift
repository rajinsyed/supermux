import SwiftUI

/// Start/stop control rendered inside the workspace title menu.
struct SupermuxWorkspaceRunMenuEntry: View {
    let session: SupermuxWorkspaceRunSession
    let projectID: String

    var body: some View {
        if let state = session.menuState(forProjectID: projectID) {
            if state.isRunning {
                Button {
                    perform { await session.stopRun(projectID: projectID) }
                } label: {
                    Label(
                        String(
                            localized: "supermux.run.stop",
                            defaultValue: "Stop Run",
                            bundle: .module
                        ),
                        systemImage: "stop.circle"
                    )
                }
                .disabled(state.isBusy)
                .accessibilityIdentifier("SupermuxWorkspaceRunMenuItem")
            } else if state.commands.count > 1 {
                Menu {
                    Button {
                        perform { await session.startRun(projectID: projectID, commandID: nil) }
                    } label: {
                        Text(String(
                            localized: "supermux.run.runAll",
                            defaultValue: "Run All Commands",
                            bundle: .module
                        ))
                    }
                    Divider()
                    ForEach(state.commands) { command in
                        Button {
                            perform {
                                await session.startRun(
                                    projectID: projectID,
                                    commandID: command.id
                                )
                            }
                        } label: {
                            Text(command.title)
                        }
                    }
                } label: {
                    Label(
                        String(
                            localized: "supermux.run.start",
                            defaultValue: "Start Run",
                            bundle: .module
                        ),
                        systemImage: "play.circle"
                    )
                }
                .disabled(state.isBusy)
                .accessibilityIdentifier("SupermuxWorkspaceRunMenuItem")
            } else {
                Button {
                    perform { await session.startRun(projectID: projectID, commandID: nil) }
                } label: {
                    Label(
                        String(
                            localized: "supermux.run.start",
                            defaultValue: "Start Run",
                            bundle: .module
                        ),
                        systemImage: "play.circle"
                    )
                }
                .disabled(state.isBusy)
                .accessibilityIdentifier("SupermuxWorkspaceRunMenuItem")
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Bool) {
        Task {
            if await operation() {
                SupermuxHaptics.success()
            }
        }
    }
}

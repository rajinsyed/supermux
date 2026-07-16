public import Foundation
internal import SupermuxMobileCore

/// A value snapshot of one live run (the ⌘G dev-server command) as
/// `SupermuxRunCoordinator` projects it for the mobile host.
///
/// This is the documented test seam between the GUI-coupled coordinator
/// (which owns terminal surfaces and cannot run in a windowless test) and the
/// package-tested wire projection below: the coordinator emits plain values,
/// everything downstream — payload building, the run observer's hash-diff —
/// consumes only these.
public struct SupermuxMobileRunSnapshot: Hashable, Sendable {
    /// The project the running workspace matched, or `nil` when the workspace
    /// directory no longer resolves to a registered project.
    public let projectId: UUID?
    /// The workspace hosting the run terminal.
    public let workspaceId: UUID
    /// The command the run surface is executing.
    public let command: String
    /// When the run was started.
    public let startedAt: Date

    /// Creates a snapshot.
    /// - Parameters:
    ///   - projectId: Matched project, when any.
    ///   - workspaceId: Hosting workspace.
    ///   - command: Running command.
    ///   - startedAt: Start time.
    public init(projectId: UUID?, workspaceId: UUID, command: String, startedAt: Date) {
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.command = command
        self.startedAt = startedAt
    }
}

/// Shared resolution rules for a project's run command, mirrored between the
/// desktop ⌘G toggle and the `mobile.supermux.run.start` handler so both
/// surfaces launch exactly the same thing.
public enum SupermuxMobileRunCommand {
    /// The desktop ⌘G rule: every configured run command, trimmed, blanks
    /// dropped, chained with `&&`.
    /// - Parameter commands: The project's `runCommands` in stored order.
    /// - Returns: The chained command, or the empty string when none remain.
    public static func joined(_ commands: [String]) -> String {
        commands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " && ")
    }

    /// One run command selected by index (`run.start {command_id}`): the
    /// 0-based position in the project's stored `run_commands` array, exactly
    /// as `projects.list` delivers it to the phone.
    /// - Parameters:
    ///   - commands: The project's `runCommands` in stored order.
    ///   - index: 0-based index into `commands`.
    /// - Returns: The trimmed command, or `nil` when the index is out of
    ///   range or names a blank entry.
    public static func selected(commands: [String], index: Int) -> String? {
        guard commands.indices.contains(index) else { return nil }
        let command = commands[index].trimmingCharacters(in: .whitespaces)
        return command.isEmpty ? nil : command
    }
}

/// Builds the `mobile.supermux.run.*` result payloads
/// (`{runs: [SupermuxRunStateDTO]}` / `{run: SupermuxRunStateDTO}`).
///
/// Lives in SupermuxKit (not the app target) so the wire shape is
/// package-unit-testable against value snapshots; the app handler stays a
/// thin pass-through reading `SupermuxComposition.runCoordinator`.
public struct SupermuxMobileRunPayloadBuilder: Sendable {
    /// Creates a builder. Stateless; construct wherever needed.
    public init() {}

    /// Encodes the `run.state` result: one row per registered project (in
    /// sidebar order, so the phone can paint run dots on every project row),
    /// folding in the live snapshot when the project is running.
    ///
    /// - Parameters:
    ///   - projects: Registered projects in sidebar order.
    ///   - snapshots: The coordinator's live-run projection.
    /// - Returns: The RPC result object (`{runs: [...]}`).
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func runState(
        projects: [SupermuxProject],
        snapshots: [SupermuxMobileRunSnapshot]
    ) throws -> [String: Any] {
        [
            "runs": try projects.map { project in
                try encodedRun(
                    projectId: project.id,
                    snapshot: representativeSnapshot(for: project.id, in: snapshots)
                )
            },
        ]
    }

    /// Encodes the single-project result the `run.start` / `run.stop`
    /// handlers return (`{run: SupermuxRunStateDTO}`).
    /// - Parameters:
    ///   - projectId: The project the request named.
    ///   - snapshot: The project's live run, or `nil` when stopped.
    /// - Returns: The RPC result object.
    /// - Throws: Any encoding failure from the shared wire bridge.
    public func runPayload(
        projectId: UUID,
        snapshot: SupermuxMobileRunSnapshot?
    ) throws -> [String: Any] {
        ["run": try encodedRun(projectId: projectId, snapshot: snapshot)]
    }

    /// The project's representative run when several workspaces run it at
    /// once: the oldest start wins (stable across refetches).
    /// - Parameters:
    ///   - projectId: The project to represent.
    ///   - snapshots: The live-run projection.
    /// - Returns: The representative snapshot, or `nil` when none match.
    public func representativeSnapshot(
        for projectId: UUID,
        in snapshots: [SupermuxMobileRunSnapshot]
    ) -> SupermuxMobileRunSnapshot? {
        snapshots
            .filter { $0.projectId == projectId }
            .min { ($0.startedAt, $0.workspaceId.uuidString) < ($1.startedAt, $1.workspaceId.uuidString) }
    }

    /// One run row's wire dictionary. `command`/`workspace_id`/`started_at`
    /// travel only while running (absent optionals stay off the wire).
    private func encodedRun(
        projectId: UUID,
        snapshot: SupermuxMobileRunSnapshot?
    ) throws -> [String: Any] {
        try SupermuxWireJSON().dictionary(from: SupermuxRunStateDTO(
            projectId: projectId.uuidString,
            isRunning: snapshot != nil,
            command: snapshot?.command,
            workspaceId: snapshot?.workspaceId.uuidString,
            startedAt: snapshot?.startedAt.timeIntervalSince1970
        ))
    }
}

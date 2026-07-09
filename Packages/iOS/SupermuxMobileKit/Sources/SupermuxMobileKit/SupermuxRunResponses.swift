public import SupermuxMobileCore

/// Typed response values for the run/launch/action namespace, decoding the
/// committed m4-f1 result payloads. All fields beyond identity are optional
/// so newer Macs can add fields without breaking older phones.

/// `mobile.supermux.run.state` result: `{runs: [SupermuxRunStateDTO]}` — one
/// row per registered project (`is_running` always present-in-practice;
/// `command`/`workspace_id`/`started_at` only while running).
public struct SupermuxRunStateResponse: Codable, Sendable, Equatable {
    /// One run-state row per registered project.
    public var runs: [SupermuxRunStateDTO]

    /// Creates the response (used by tests and fakes).
    /// - Parameter runs: One run-state row per registered project.
    public init(runs: [SupermuxRunStateDTO]) {
        self.runs = runs
    }
}

/// `mobile.supermux.run.start` / `run.stop` result:
/// `{run: SupermuxRunStateDTO}` — the project's state after the (idempotent)
/// transition.
public struct SupermuxRunWriteResponse: Codable, Sendable, Equatable {
    /// The project's run state after the transition.
    public var run: SupermuxRunStateDTO

    /// Creates the response (used by tests and fakes).
    /// - Parameter run: The project's run state after the transition.
    public init(run: SupermuxRunStateDTO) {
        self.run = run
    }
}

/// `mobile.supermux.preset.launch` result: `{workspace_id, terminal_id}` —
/// the workspace hosting the fresh preset terminal, for the phone to
/// navigate to.
public struct SupermuxPresetLaunchResponse: Codable, Sendable, Equatable {
    /// The workspace hosting the preset terminal.
    public var workspaceId: String?
    /// The spawned terminal panel's id.
    public var terminalId: String?

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - workspaceId: The hosting workspace's UUID string.
    ///   - terminalId: The spawned terminal panel's UUID string.
    public init(workspaceId: String? = nil, terminalId: String? = nil) {
        self.workspaceId = workspaceId
        self.terminalId = terminalId
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case terminalId = "terminal_id"
    }
}

/// `mobile.supermux.action.run` result — exactly two committed shapes:
/// `{kind: "open_url", url}` (nothing was executed Mac-side; the phone opens
/// the URL locally) or `{ok: true, kind: "command"}` (the action ran in a
/// fresh Mac terminal).
public struct SupermuxActionRunResponse: Codable, Sendable, Equatable {
    /// Whether a command action executed Mac-side.
    public var ok: Bool?
    /// The outcome kind (`"open_url"` / `"command"`).
    public var kind: String?
    /// The URL the phone opens locally (`open_url` outcomes only).
    public var url: String?

    /// The `open_url` outcome's wire kind.
    public static let openURLKind = "open_url"

    /// Whether this outcome is an `open_url` the phone must open locally
    /// (requires both the kind and a URL — a URL-less `open_url` is treated
    /// as inert rather than a crash).
    public var opensURLLocally: Bool {
        kind == Self.openURLKind && url?.isEmpty == false
    }

    /// Creates the response (used by tests and fakes).
    /// - Parameters:
    ///   - ok: Whether a command action executed Mac-side.
    ///   - kind: The outcome kind.
    ///   - url: The URL for `open_url` outcomes.
    public init(ok: Bool? = nil, kind: String? = nil, url: String? = nil) {
        self.ok = ok
        self.kind = kind
        self.url = url
    }
}

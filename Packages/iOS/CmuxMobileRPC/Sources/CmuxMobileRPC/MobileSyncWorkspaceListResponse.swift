public import CMUXMobileCore
public import Foundation

/// Typed decoder for the `workspace.list` / `mobile.workspace.list` RPC result.
///
/// The wire shape is snake_case (the Mac side of PR 5079 already emits it); the
/// `CodingKeys` map it onto camelCase Swift properties without changing the wire.
public struct MobileSyncWorkspaceListResponse: Decodable, Sendable {
    /// A workspace entry in the list response.
    public struct Workspace: Decodable, Sendable {
        /// Stable workspace identifier.
        public let id: String
        /// Stable Mac window identifier, when reported.
        public let windowID: String?
        /// User-facing workspace title.
        public let title: String
        /// Custom workspace description, when reported by the Mac.
        public let customDescription: String?
        /// Whether `customDescription` is a bounded projection of a longer Mac value.
        public let customDescriptionIsTruncated: Bool?
        /// Custom workspace accent color as `#RRGGBB`, when reported by the Mac.
        public let customColorHex: String?
        /// The workspace's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the Mac currently has this workspace selected.
        public let isSelected: Bool
        // SUPERMUX:begin supermux-mobile-selection-sync
        /// The focused terminal, browser, Simulator, or other panel in this workspace.
        public let focusedPanel: MobileWorkspaceFocusedPanel?
        // SUPERMUX:end supermux-mobile-selection-sync
        /// Whether this workspace is pinned, if the Mac reported it. `nil` when
        /// connected to a Mac old enough not to emit `is_pinned`.
        public let isPinned: Bool?
        /// The id of the group this workspace belongs to, if any. `nil` for
        /// ungrouped workspaces and for Macs old enough not to emit groups.
        public let groupID: String?
        /// A one-line, plain-text preview of the most recent activity (the latest
        /// notification body/title), shown under the row like an iMessage preview.
        /// `nil` when the workspace has no activity or the Mac is old enough not to
        /// emit it.
        public let preview: String?
        /// Unix epoch seconds of the preview's activity, for the row's relative
        /// time. `nil` when there is no preview.
        public let previewAt: Double?
        /// Unix epoch seconds of the workspace's last activity. The Mac stamps
        /// this on every workspace (latest notification, falling back to the
        /// workspace's creation/connect time). `nil` on Macs old enough not to
        /// emit it.
        public let lastActivityAt: Double?
        /// Whether the workspace has unread activity on the Mac. `nil` on Macs
        /// old enough not to emit it (the row then shows no unread dot).
        public let hasUnread: Bool?
        /// Terminals belonging to this workspace.
        public let terminals: [Terminal]
        /// All workspace surfaces. `nil` when an older Mac omits the field.
        public let surfaces: [Surface]?
        /// Simulator panes belonging to this workspace.
        public let simulators: [MobileSimulatorPanelDescriptor]
        // SUPERMUX:begin supermux-mobile-workspace-fields (additive §6 fields; absent on upstream Macs — see SUPERMUX-TOUCHPOINTS.md)
        /// The supermux project owning this workspace (UUID string); `nil` when unassociated or from upstream cmux.
        public let supermuxProjectID: String?
        /// Agent-activity raw value (`working`/`needs_input`/`ready`); `nil` when idle, unassociated, or from upstream cmux.
        public let supermuxActivity: String?
        /// The workspace's git branch (the mac sidebar row's subtitle); `nil` when unknown, unassociated, or from upstream cmux.
        public let supermuxBranch: String?
        /// The workspace branch's pull request; `nil` when none, unassociated, or from upstream cmux.
        public let supermuxPullRequest: SupermuxPullRequest?
        /// How many unread notifications the workspace has, so the badge can show the same
        /// numeral the Mac sidebar does. `nil` from an upstream cmux Mac (which sends only
        /// `has_unread`); the badge then renders its countless dot form. Travels for EVERY
        /// workspace, unlike the four project-gated fields above.
        public let supermuxUnreadCount: Int?
        /// Pane identifiers whose Mac unread indicator is visible. `nil` means
        /// the host does not support exact pane unread state; an empty array means
        /// it supports the field and no pane currently needs acknowledgment.
        public let supermuxUnreadPanelIDs: [String]?
        /// The `supermux_pull_request` object: same shape as the worktree DTO's `pull_request`
        /// (`{number, state, url, is_stale}`). Decoding is LOSSY on purpose: a malformed
        /// extension object (wrong types, not even an object) degrades to nil fields —
        /// "no badge" — and never fails the whole workspace-list decode.
        public struct SupermuxPullRequest: Decodable, Sendable, Equatable {
            /// The PR number (the `#1234` on the badge); consumers drop the badge when nil.
            public let number: Int?
            /// PR state string (`"open"`/`"merged"`/`"closed"`), when sent.
            public let state: String?
            /// The PR's web URL, when sent.
            public let url: String?
            /// Whether the badge is stale (mac dims it), when sent.
            public let isStale: Bool?

            private enum CodingKeys: String, CodingKey {
                case number, state, url
                case isStale = "is_stale"
            }

            public init(from decoder: any Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    number = nil; state = nil; url = nil; isStale = nil
                    return
                }
                number = (try? container.decodeIfPresent(Int.self, forKey: .number)) ?? nil
                state = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil
                url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? nil
                isStale = (try? container.decodeIfPresent(Bool.self, forKey: .isStale)) ?? nil
            }

            /// Memberwise construction for locally-synced sources: mobile state
            /// sync v2 projects `WorkspaceSyncRecord.SupermuxPullRequest` (same
            /// wire shape) through this type so both transports feed one apply
            /// path. Declaring `init(from:)` above suppresses the synthesized
            /// memberwise init, and a synthesized one would be internal anyway.
            public init(
                number: Int? = nil,
                state: String? = nil,
                url: String? = nil,
                isStale: Bool? = nil
            ) {
                self.number = number
                self.state = state
                self.url = url
                self.isStale = isStale
            }
        }
        // SUPERMUX:end supermux-mobile-workspace-fields

        private enum CodingKeys: String, CodingKey {
            case id
            case windowID = "window_id"
            case title
            case customDescription = "description"
            case customDescriptionIsTruncated = "description_truncated"
            case customColorHex = "custom_color"
            case currentDirectory = "current_directory"
            case isSelected = "is_selected"
            // SUPERMUX:begin supermux-mobile-selection-sync
            case focusedPanel = "focused_panel"
            // SUPERMUX:end supermux-mobile-selection-sync
            case isPinned = "is_pinned"
            case groupID = "group_id"
            case preview
            case previewAt = "preview_at"
            case lastActivityAt = "last_activity_at"
            case hasUnread = "has_unread"
            case terminals
            case surfaces
            case simulators
            // SUPERMUX:begin supermux-mobile-workspace-fields
            case supermuxProjectID = "supermux_project_id"
            case supermuxActivity = "supermux_activity"
            case supermuxBranch = "supermux_branch"
            case supermuxPullRequest = "supermux_pull_request"
            case supermuxUnreadCount = "supermux_unread_count"
            case supermuxUnreadPanelIDs = "supermux_unread_panel_ids"
            // SUPERMUX:end supermux-mobile-workspace-fields
        }

        /// Memberwise construction for callers that assemble a row from an
        /// already-synced local source (mobile state sync v2 projects its
        /// record mirror through the same apply path as the wire response).
        public init(
            id: String,
            windowID: String?,
            title: String,
            customDescription: String? = nil,
            customDescriptionIsTruncated: Bool? = nil,
            customColorHex: String? = nil,
            currentDirectory: String?,
            isSelected: Bool,
            // SUPERMUX:begin supermux-mobile-selection-sync
            focusedPanel: MobileWorkspaceFocusedPanel? = nil,
            // SUPERMUX:end supermux-mobile-selection-sync
            isPinned: Bool?,
            groupID: String?,
            preview: String?,
            previewAt: Double?,
            lastActivityAt: Double?,
            hasUnread: Bool?,
            terminals: [Terminal],
            surfaces: [Surface]? = nil,
            simulators: [MobileSimulatorPanelDescriptor] = [],
            // SUPERMUX:begin supermux-mobile-workspace-fields (additive §6 fields on upstream's
            // memberwise init; defaulted to nil so upstream call sites compile unchanged and an
            // upstream Mac's rows stay field-free — see SUPERMUX-TOUCHPOINTS.md)
            supermuxProjectID: String? = nil,
            supermuxActivity: String? = nil,
            supermuxBranch: String? = nil,
            supermuxPullRequest: SupermuxPullRequest? = nil,
            supermuxUnreadCount: Int? = nil,
            supermuxUnreadPanelIDs: [String]? = nil
            // SUPERMUX:end supermux-mobile-workspace-fields
        ) {
            self.id = id
            self.windowID = windowID
            self.title = title
            self.customDescription = customDescription
            self.customDescriptionIsTruncated = customDescriptionIsTruncated
            self.customColorHex = customColorHex
            self.currentDirectory = currentDirectory
            self.isSelected = isSelected
            // SUPERMUX:begin supermux-mobile-selection-sync
            self.focusedPanel = focusedPanel
            // SUPERMUX:end supermux-mobile-selection-sync
            self.isPinned = isPinned
            self.groupID = groupID
            self.preview = preview
            self.previewAt = previewAt
            self.lastActivityAt = lastActivityAt
            self.hasUnread = hasUnread
            self.terminals = terminals
            self.surfaces = surfaces
            self.simulators = simulators
            // SUPERMUX:begin supermux-mobile-workspace-fields
            self.supermuxProjectID = supermuxProjectID
            self.supermuxActivity = supermuxActivity
            self.supermuxBranch = supermuxBranch
            self.supermuxPullRequest = supermuxPullRequest
            self.supermuxUnreadCount = supermuxUnreadCount
            self.supermuxUnreadPanelIDs = supermuxUnreadPanelIDs
            // SUPERMUX:end supermux-mobile-workspace-fields
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            windowID = try container.decodeIfPresent(String.self, forKey: .windowID)
            title = try container.decode(String.self, forKey: .title)
            customDescription = try container.decodeIfPresent(String.self, forKey: .customDescription)
            customDescriptionIsTruncated = try container.decodeIfPresent(Bool.self, forKey: .customDescriptionIsTruncated)
            customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
            currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
            isSelected = try container.decode(Bool.self, forKey: .isSelected)
            // SUPERMUX:begin supermux-mobile-selection-sync
            focusedPanel = (
                try? container.decodeIfPresent(
                    MobileWorkspaceFocusedPanel.self,
                    forKey: .focusedPanel
                )
            ) ?? nil
            // SUPERMUX:end supermux-mobile-selection-sync
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
            groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
            preview = try container.decodeIfPresent(String.self, forKey: .preview)
            previewAt = try container.decodeIfPresent(Double.self, forKey: .previewAt)
            lastActivityAt = try container.decodeIfPresent(Double.self, forKey: .lastActivityAt)
            hasUnread = try container.decodeIfPresent(Bool.self, forKey: .hasUnread)
            terminals = try container.decode([Terminal].self, forKey: .terminals)
            surfaces = try container.decodeIfPresent([Surface].self, forKey: .surfaces)
            simulators = try container.decodeIfPresent(
                [MobileSimulatorPanelDescriptor].self,
                forKey: .simulators
            ) ?? []
            // SUPERMUX:begin supermux-mobile-workspace-fields (lenient: a malformed additive
            // field degrades to nil — "no badge / no fold" — and never fails the row decode)
            supermuxProjectID = (try? container.decodeIfPresent(String.self, forKey: .supermuxProjectID)) ?? nil
            supermuxActivity = (try? container.decodeIfPresent(String.self, forKey: .supermuxActivity)) ?? nil
            supermuxBranch = (try? container.decodeIfPresent(String.self, forKey: .supermuxBranch)) ?? nil
            supermuxPullRequest = (
                try? container.decodeIfPresent(SupermuxPullRequest.self, forKey: .supermuxPullRequest)
            ) ?? nil
            supermuxUnreadCount = (try? container.decodeIfPresent(Int.self, forKey: .supermuxUnreadCount)) ?? nil
            supermuxUnreadPanelIDs = (
                try? container.decodeIfPresent([String].self, forKey: .supermuxUnreadPanelIDs)
            ) ?? nil
            // SUPERMUX:end supermux-mobile-workspace-fields
        }
    }

    /// A Mac-rendered surface in workspace spatial order.
    public struct Surface: Decodable, Equatable, Sendable {
        /// Stable Mac-local surface identifier.
        public let surfaceID: String
        /// Open surface-kind wire value.
        public let kind: String
        /// User-facing surface title.
        public let title: String
        /// Whether the surface currently holds focus on the owning Mac.
        public let isFocused: Bool
        /// Backing path for file-oriented surfaces, when present.
        public let filePath: String?
        /// Bounded checklist/status payload for todo surfaces.
        public let todo: MobileTodoSnapshot?

        private enum CodingKeys: String, CodingKey {
            case surfaceID = "surface_id"
            case kind
            case title
            case isFocused = "is_focused"
            case filePath = "file_path"
            case todo
        }

        /// Creates a projected surface DTO.
        public init(
            surfaceID: String,
            kind: String,
            title: String,
            filePath: String?,
            todo: MobileTodoSnapshot? = nil,
            isFocused: Bool = false
        ) {
            self.surfaceID = surfaceID
            self.kind = kind
            self.title = title
            self.isFocused = isFocused
            self.filePath = filePath
            self.todo = todo
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            surfaceID = try container.decode(String.self, forKey: .surfaceID)
            kind = try container.decode(String.self, forKey: .kind)
            title = try container.decode(String.self, forKey: .title)
            isFocused = try container.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            todo = try container.decodeIfPresent(MobileTodoSnapshot.self, forKey: .todo)
        }
    }

    /// A workspace group section in the list response. Mirrors the iOS-facing
    /// subset the Mac emits (no v2 handle refs or color). Members are
    /// listed in the Mac's spatial (`tabs`) order. Absent on Macs old enough not
    /// to emit groups.
    public struct Group: Decodable, Sendable {
        /// Stable group identifier.
        public let id: String
        /// User-facing group name (shown as the section header label).
        public let name: String
        /// Whether the group is currently collapsed on the Mac.
        public let isCollapsed: Bool
        /// Whether the group is pinned on the Mac.
        public let isPinned: Bool
        /// SF Symbol rendered by the corresponding group row on the Mac.
        public let iconSymbol: String?
        /// The anchor workspace that owns this group. It is represented by the
        /// group header and never rendered as a separate row.
        public let anchorWorkspaceID: String

        // The Mac also emits `member_workspace_ids`, but membership is derived on
        // the client from each workspace's `group_id` (which preserves spatial
        // order), so the explicit member list is intentionally not decoded here.

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case isCollapsed = "is_collapsed"
            case isPinned = "is_pinned"
            case iconSymbol = "icon_symbol"
            case anchorWorkspaceID = "anchor_workspace_id"
        }

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            name: String,
            isCollapsed: Bool,
            isPinned: Bool,
            iconSymbol: String? = nil,
            anchorWorkspaceID: String
        ) {
            self.id = id
            self.name = name
            self.isCollapsed = isCollapsed
            self.isPinned = isPinned
            self.iconSymbol = iconSymbol
            self.anchorWorkspaceID = anchorWorkspaceID
        }
    }

    /// A terminal entry within a workspace.
    public struct Terminal: Decodable, Sendable {
        /// Stable terminal identifier.
        public let id: String
        /// User-facing terminal title.
        public let title: String
        /// The terminal's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the terminal currently holds focus.
        public let isFocused: Bool
        /// Whether the terminal surface is ready, if reported.
        public let isReady: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isFocused = "is_focused"
            case isReady = "is_ready"
        }

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            title: String,
            currentDirectory: String?,
            isFocused: Bool,
            isReady: Bool?
        ) {
            self.id = id
            self.title = title
            self.currentDirectory = currentDirectory
            self.isFocused = isFocused
            self.isReady = isReady
        }
    }

    /// The full workspace list.
    public let workspaces: [Workspace]
    /// Group sections, in section order. Empty when the Mac reports no groups or
    /// when an older payload omits the field.
    public let groups: [Group]
    /// Whether the decoded payload carried a `groups` field at all. Older or
    /// partial responses omit the field, and callers use that to preserve the
    /// last authoritative group headers across reconnect churn.
    public let groupsFieldWasPresent: Bool
    /// Identifier of a workspace created by the request, if any.
    public let createdWorkspaceID: String?
    /// Identifier of a terminal created by the request, if any.
    public let createdTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case groups
        case createdWorkspaceID = "created_workspace_id"
        case createdTerminalID = "created_terminal_id"
    }

    /// Decodes a workspace-list response, defaulting `groups` to empty so a Mac
    /// old enough not to emit the field still decodes (the grouped UI then stays
    /// flat). `created_workspace_id` / `created_terminal_id` are optional.
    /// - Parameter decoder: The decoder for the RPC result payload.
    /// - Throws: A decoding error if `workspaces` is missing or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        groupsFieldWasPresent = container.contains(.groups)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        createdWorkspaceID = try container.decodeIfPresent(String.self, forKey: .createdWorkspaceID)
        createdTerminalID = try container.decodeIfPresent(String.self, forKey: .createdTerminalID)
    }

    /// Decode a workspace-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncWorkspaceListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

// Memberwise construction for callers that assemble a list response from an
// already-synced local source (mobile state sync v2 projects its record mirror
// through the same apply path the decoded wire response uses).
extension MobileSyncWorkspaceListResponse {
    /// Memberwise construction for locally-synced sources (state sync v2
    /// projects its record mirror through the same apply path).
    public init(
        workspaces: [Workspace],
        groups: [Group],
        groupsFieldWasPresent: Bool = true,
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) {
        self.workspaces = workspaces
        self.groups = groups
        self.groupsFieldWasPresent = groupsFieldWasPresent
        self.createdWorkspaceID = createdWorkspaceID
        self.createdTerminalID = createdTerminalID
    }
}

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
        /// The workspace's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the Mac currently has this workspace selected.
        public let isSelected: Bool
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
        // SUPERMUX:begin supermux-mobile-workspace-fields (additive §6 fields; absent on upstream Macs — see SUPERMUX-TOUCHPOINTS.md)
        /// The supermux project owning this workspace (UUID string); `nil` when unassociated or from upstream cmux.
        public let supermuxProjectID: String?
        /// Agent-activity raw value (`working`/`needs_input`/`ready`); `nil` when idle, unassociated, or from upstream cmux.
        public let supermuxActivity: String?
        /// The workspace's git branch (the mac sidebar row's subtitle); `nil` when unknown, unassociated, or from upstream cmux.
        public let supermuxBranch: String?
        /// The workspace branch's pull request; `nil` when none, unassociated, or from upstream cmux.
        public let supermuxPullRequest: SupermuxPullRequest?
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
        }
        // SUPERMUX:end supermux-mobile-workspace-fields

        private enum CodingKeys: String, CodingKey {
            case id
            case windowID = "window_id"
            case title
            case currentDirectory = "current_directory"
            case isSelected = "is_selected"
            case isPinned = "is_pinned"
            case groupID = "group_id"
            case preview
            case previewAt = "preview_at"
            case lastActivityAt = "last_activity_at"
            case hasUnread = "has_unread"
            case terminals
            // SUPERMUX:begin supermux-mobile-workspace-fields
            case supermuxProjectID = "supermux_project_id"
            case supermuxActivity = "supermux_activity"
            case supermuxBranch = "supermux_branch"
            case supermuxPullRequest = "supermux_pull_request"
            // SUPERMUX:end supermux-mobile-workspace-fields
        }
    }

    /// A workspace group section in the list response. Mirrors the iOS-facing
    /// subset the Mac emits (no v2 handle refs, color, or icon). Members are
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
            case anchorWorkspaceID = "anchor_workspace_id"
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
    }

    /// The full workspace list.
    public let workspaces: [Workspace]
    /// Group sections, in section order. Empty on Macs old enough not to emit
    /// groups (the field is decoded with `decodeIfPresent`).
    public let groups: [Group]
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

import Foundation

/// Typed parameters for `mobile.browser.create`.
struct MobileBrowserCreateParameters: Encodable, Sendable {
    /// The Mac-local workspace identifier.
    let workspaceID: String
    // SUPERMUX:begin supermux-mobile-create-focus
    /// Whether the Mac must focus the created panel before replying.
    let focus: Bool
    // SUPERMUX:end supermux-mobile-create-focus

    /// Creates browser-create parameters.
    init(
        workspaceID: String,
        // SUPERMUX:begin supermux-mobile-create-focus
        focus: Bool = true
        // SUPERMUX:end supermux-mobile-create-focus
    ) {
        self.workspaceID = workspaceID
        // SUPERMUX:begin supermux-mobile-create-focus
        self.focus = focus
        // SUPERMUX:end supermux-mobile-create-focus
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        // SUPERMUX:begin supermux-mobile-create-focus
        case focus
        // SUPERMUX:end supermux-mobile-create-focus
    }
}

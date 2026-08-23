import Foundation

/// Persisted state for one Claude harness pane; every field is optional so
/// older snapshots and partially-known sessions decode without loss.
struct SessionSupermuxHarnessPanelSnapshot: Codable, Sendable {
    /// Permission mode used when a pane or an older snapshot has no explicit value.
    static let defaultPermissionMode = "bypassPermissions"

    var workingDirectory: String?
    var sessionId: String?
    var model: String?
    var effort: String?
    var permissionMode: String?
    var title: String?
    /// True when `title` came from an explicit rename rather than the CLI's
    /// auto-generated topic title; only a rename blocks later retitling.
    var titleIsCustom: Bool?
}

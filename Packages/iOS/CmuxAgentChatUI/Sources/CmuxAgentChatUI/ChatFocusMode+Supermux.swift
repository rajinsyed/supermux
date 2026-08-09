// SUPERMUX:begin agent-chat-focus-mode
//
// Fork-owned file inside an upstream package (same whole-file pattern as the
// other such rows in SUPERMUX-TOUCHPOINTS.md): it adds a transcript grouping
// seam without editing upstream logic.
//
// WHAT THIS IS FOR. A coding-agent session is mostly tool calls, and rendering
// each as its own row buries the handful of sentences the agent actually said.
// Focus mode folds consecutive runs of tool/thought/terminal/diff rows behind
// one expandable "Working" summary. The fold is a pure function over
// `[ChatTranscriptRow]`, supplied by the fork; upstream keeps owning the table,
// keyboard tracking, paging, and every individual row view.
//
// WHY A REGROUPER AND NOT A ROW RENDERER. The rows themselves are fine — the
// user wants FEWER of them, not different ones. So the seam maps the row array
// to a (possibly shorter) array of erased views, and expanded runs still call
// straight back into `ChatTranscriptRowView`.
//
// WHERE IT MUST BE APPLIED. `ChatTranscriptTableView` hosts each cell through
// `UIHostingConfiguration`, which starts a FRESH SwiftUI environment — values
// set above `ChatScreen` do NOT reach cells. Upstream already re-injects five
// values per cell for exactly this reason; this seam is instead consumed at
// `makeItems()` time (before cells exist), so it needs no re-injection, but the
// grouping identity DOES have to reach `shouldReload` or a toggle leaves stale
// cells on screen.
import CmuxAgentChat
import SwiftUI

/// Fork-supplied transcript grouping.
///
/// A value of closures rather than a protocol: a protocol with associated
/// `View` types cannot live in the environment without another erasure layer.
/// A `nil` grouping renders exactly upstream, so every host that does not opt
/// in — demos, previews, tests, an upstream-paired phone — is unaffected.
@MainActor
public struct ChatTranscriptGrouping {
    /// Maps the transcript's rows onto the entries to render.
    ///
    /// Returning one entry per row reproduces upstream exactly; returning
    /// fewer is what collapses runs of work rows.
    public var entries: ([ChatTranscriptRow], ChatRowActions, ChatAgentState) -> [Entry]

    /// Identity of the grouping's current configuration.
    ///
    /// Folded into the table's reload decision, so flipping the setting (which
    /// leaves the underlying rows value-identical) still re-renders.
    public var identity: String

    /// One rendered transcript entry.
    public struct Entry: Identifiable {
        /// Stable identity for table diffing and height caching.
        public let id: String
        /// The view for this entry.
        public let view: AnyView

        /// Creates an entry.
        public init(id: String, view: AnyView) {
            self.id = id
            self.view = view
        }
    }

    /// Creates a grouping.
    ///
    /// - Parameters:
    ///   - identity: Configuration identity, folded into reloads.
    ///   - entries: Maps rows onto entries.
    public init(
        identity: String,
        entries: @escaping ([ChatTranscriptRow], ChatRowActions, ChatAgentState) -> [Entry]
    ) {
        self.identity = identity
        self.entries = entries
    }
}

extension EnvironmentValues {
    /// The active fork transcript grouping; `nil` renders upstream's rows.
    @Entry public var chatTranscriptGrouping: ChatTranscriptGrouping?
}

public extension View {
    /// Installs a transcript grouping for the chat surface beneath this view.
    ///
    /// - Parameter grouping: The regrouper, or `nil` for upstream's behavior.
    /// - Returns: The modified view.
    func chatTranscriptGrouping(_ grouping: ChatTranscriptGrouping?) -> some View {
        environment(\.chatTranscriptGrouping, grouping)
    }
}
// SUPERMUX:end agent-chat-focus-mode

public import Foundation

/// One `cmux set-status` pill as a nested sidebar row shows it — the value the
/// flat rows draw as a metadata line.
public struct SupermuxRowStatusPill: Hashable, Sendable, Identifiable {
    /// The status key (last write per key wins).
    public let key: String
    /// The displayed text.
    public let text: String
    /// An SF Symbol name (optionally `sf:`-prefixed), `emoji:<characters>` or
    /// `text:<characters>`, as `cmux set-status --icon` takes it.
    public let icon: String?
    /// A hex color for the pill, if one was set.
    public let colorHex: String?
    /// Whether `text` is inline Markdown.
    public let isMarkdown: Bool

    public var id: String { key }

    /// Creates a pill.
    public init(key: String, text: String, icon: String? = nil, colorHex: String? = nil, isMarkdown: Bool = false) {
        self.key = key
        self.text = text
        self.icon = icon
        self.colorHex = colorHex
        self.isMarkdown = isMarkdown
    }
}

/// A `cmux set-progress` bar as a nested sidebar row shows it.
public struct SupermuxRowProgress: Hashable, Sendable {
    /// The fraction done, 0...1.
    public let value: Double
    /// The label under the bar, if any.
    public let label: String?

    /// Creates a progress value.
    public init(value: Double, label: String? = nil) {
        self.value = value
        self.label = label
    }
}

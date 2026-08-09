public import SwiftUI

/// The shared block surface for monospace content: code blocks, shell output,
/// and diffs.
///
/// One recipe for all three so they read as the same kind of object — a soft
/// elevated fill, a hairline, a 12pt radius, and an optional caption header
/// with trailing controls. Nothing here is dark-on-light "terminal chrome":
/// the surface follows the color scheme, because on a phone a black slab in a
/// white transcript reads as an error, not as a terminal.
public struct SupermuxChatCodeSurface<Header: View, Content: View>: View {
    private let header: Header
    private let content: Content

    @Environment(\.supermuxChatTheme) private var theme

    /// Creates a code surface.
    ///
    /// - Parameters:
    ///   - header: The caption row; pass `EmptyView()` for none.
    ///   - content: The monospace body.
    public init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.elevatedFill,
            in: .rect(cornerRadius: theme.cardCornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardCornerRadius, style: .continuous)
                .strokeBorder(theme.hairline, lineWidth: 0.5)
        }
    }
}

extension SupermuxChatCodeSurface where Header == EmptyView {
    /// Creates a headerless code surface.
    public init(@ViewBuilder content: () -> Content) {
        self.init(header: { EmptyView() }, content: content)
    }
}

/// The caption row used at the top of a ``SupermuxChatCodeSurface``.
public struct SupermuxChatCodeSurfaceHeader<Trailing: View>: View {
    private let title: String
    private let isMonospaced: Bool
    private let trailing: Trailing

    /// Creates a header.
    ///
    /// - Parameters:
    ///   - title: The caption (a language name, a file path, a command).
    ///   - isMonospaced: Whether the title is code-like (paths, commands).
    ///   - trailing: Controls pinned to the trailing edge.
    public init(
        title: String,
        isMonospaced: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.isMonospaced = isMonospaced
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(isMonospaced
                    ? .supermuxChatMono(size: 12)
                    : .supermuxChatFootnote(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(minHeight: 34)
    }
}

extension SupermuxChatCodeSurfaceHeader where Trailing == EmptyView {
    /// Creates a header with no trailing controls.
    public init(title: String, isMonospaced: Bool = false) {
        self.init(title: title, isMonospaced: isMonospaced) { EmptyView() }
    }
}

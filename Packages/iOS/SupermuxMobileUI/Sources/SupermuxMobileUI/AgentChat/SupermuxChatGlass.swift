public import SwiftUI

/// The one glass primitive every floating chat surface goes through.
///
/// On iOS 26 this is real Liquid Glass; below it, `.thinMaterial`. Routing
/// every floating control through a single helper is what keeps the composer,
/// its pills, and the scroll-to-bottom button changing character together
/// rather than drifting apart — and a tinted CTA paints its tint *directly* on
/// the fallback path, because a material would mute it.
///
/// The package's platform list includes macOS (for previews and the shared
/// screen types), where `Glass` does not exist below macOS 26; the whole glass
/// path is therefore iOS-only and macOS always takes the material fallback.
public extension View {
    /// Applies the chat surface's glass treatment.
    ///
    /// - Parameters:
    ///   - shape: The glass shape.
    ///   - isInteractive: Whether the glass should react to touch (iOS 26).
    ///   - tint: A CTA tint painted directly on the fallback path.
    /// - Returns: The glassed view.
    @ViewBuilder
    func supermuxChatGlass(
        in shape: some Shape,
        isInteractive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            glassEffect(
                supermuxResolvedGlass(tint: tint, isInteractive: isInteractive),
                in: shape
            )
        } else if let tint {
            background(tint, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
        #else
        if let tint {
            background(tint, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
        #endif
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private extension View {
    func supermuxResolvedGlass(tint: Color?, isInteractive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if isInteractive { glass = glass.interactive() }
        return glass
    }
}
#endif

/// Groups sibling glass surfaces so they merge instead of stacking edges.
public struct SupermuxChatGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    /// Creates a glass container.
    ///
    /// - Parameters:
    ///   - spacing: Merge distance between sibling glass surfaces.
    ///   - content: The glassed children.
    public init(spacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

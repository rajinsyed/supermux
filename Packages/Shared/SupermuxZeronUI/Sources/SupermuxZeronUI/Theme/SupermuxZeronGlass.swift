//
//  SupermuxZeronGlass.swift
//  SupermuxZeronUI
//
//  `isGlass` gating plus the platform backdrop blur. Spec 01 §8.4, plan §0.3
//  C13 and risk R3.
//
//  ── The platform split (plan §0.3 C13) ──
//
//  macOS is REAL glass: `NSVisualEffectView` with `.underWindowBackground` /
//  `.behindWindow` / `.active` blurs the desktop behind the window, and
//  `theme.glass()` (`#080808` @ 0.80 dark, `#FAFAFA` @ 0.80 light) is the tint
//  painted on top. That is what makes the transcript backdrop composite to the
//  `#060606` both zeron screenshots measure.
//
//  iOS is OPAQUE at the SHELL level: there is nothing behind an iOS app to blur,
//  so `isGlass == false` and `glass()` returns the opaque `surface`. iOS
//  floating CARDS still use `.ultraThinMaterial`, which blurs *app* content —
//  that is the right effect for an in-app popover over the transcript, and it is
//  a card-level decision, not a shell-level one.
//
//  ── Blur radius (risk R3) ──
//
//  zeron blurs the composer pill at sigma 16 and menus at 44.
//  `NSVisualEffectView` has NO radius knob and `.ultraThinMaterial` is a fixed
//  recipe, so the sigmas are unreachable without a private `CABackdropLayer`.
//  What is preserved is the RELATIVE difference — the pill reads lighter than a
//  menu — and, exactly, the tints on top, which are the precisely-specified
//  half. On a busy wallpaper the pill reads slightly sharper than zeron's; that
//  is the documented gap.
//

public import SwiftUI

#if canImport(AppKit)
internal import AppKit
#endif

// MARK: - Blur roles

/// Which backdrop recipe a surface wants.
///
/// The names are zeron's roles, not AppKit materials, so the mapping can change
/// per platform without call sites changing.
public enum SupermuxZeronBlurRole: Sendable, Equatable, Hashable, CaseIterable {
    /// The app shell / transcript backdrop. macOS `.underWindowBackground`
    /// behind-window; iOS opaque `surface`.
    case shell
    /// A floating menu, popover or picker card. zeron sigma 44.
    case menu
    /// The composer pill. zeron sigma 16 — deliberately lighter than `menu`.
    case pill

    #if canImport(AppKit)
    /// The closest AppKit material. `.underWindowBackground` matches gpui's
    /// `UnderWindowBackground` exactly; `.hudWindow` is the closest to the
    /// heavier menu recipe; `.popover` is lighter, preserving the pill-vs-menu
    /// ordering that the sigma difference expresses.
    var material: NSVisualEffectView.Material {
        switch self {
        case .shell: .underWindowBackground
        case .menu: .hudWindow
        case .pill: .popover
        }
    }
    #endif
}

// MARK: - Backdrop

/// The platform backdrop blur for a role, with the zeron tint painted on top.
///
/// Use it as a `.background(...)`, never as an overlay: the tint must composite
/// over the blur, and the content must composite over both.
public struct SupermuxZeronGlassBackdrop: View {
    private let theme: SupermuxZeronTheme
    private let role: SupermuxZeronBlurRole
    /// The tint painted over the blur. Defaults to the role's zeron token.
    private let tint: Color?

    public init(
        theme: SupermuxZeronTheme,
        role: SupermuxZeronBlurRole = .shell,
        tint: Color? = nil
    ) {
        self.theme = theme
        self.role = role
        self.tint = tint
    }

    /// The tint each role paints when the caller does not override it.
    private var resolvedTint: Color {
        if let tint { return tint }
        switch role {
        case .shell: return theme.glass()
        case .menu: return theme.glassOverlay()
        case .pill: return theme.inputGlassBG()
        }
    }

    public var body: some View {
        #if canImport(AppKit)
        ZStack {
            SupermuxZeronVisualEffect(material: role.material)
            resolvedTint
        }
        #else
        // iOS: the shell is opaque (C13) — nothing sits behind the app to blur,
        // and `.ultraThinMaterial` there would blur the transcript into itself.
        // Cards DO want the material, because it blurs app content.
        ZStack {
            if role == .shell {
                theme.surface
            } else {
                Rectangle().fill(.ultraThinMaterial)
                resolvedTint
            }
        }
        #endif
    }
}

#if canImport(AppKit)

/// `NSVisualEffectView` in `.behindWindow` / `.active`, which is gpui's setup.
///
/// `.active` (not `.followsWindowActiveState`) is deliberate: zeron's glass does
/// not go flat when the window loses key, and a transcript that changes tone on
/// focus change reads as a bug.
public struct SupermuxZeronVisualEffect: NSViewRepresentable {
    private let material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        // The transcript column paints its own rounding; the backdrop is a
        // plain rectangle under everything.
        view.autoresizingMask = [.width, .height]
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.blendingMode != .behindWindow { view.blendingMode = .behindWindow }
        if view.state != .active { view.state = .active }
    }
}

#endif

// MARK: - Modifier

public extension View {
    /// Paints the zeron backdrop for `role` behind this view.
    ///
    /// ```swift
    /// transcript.supermuxZeronGlass(theme, role: .shell)
    /// ```
    func supermuxZeronGlass(
        _ theme: SupermuxZeronTheme,
        role: SupermuxZeronBlurRole = .shell,
        tint: Color? = nil
    ) -> some View {
        background(SupermuxZeronGlassBackdrop(theme: theme, role: role, tint: tint))
    }
}

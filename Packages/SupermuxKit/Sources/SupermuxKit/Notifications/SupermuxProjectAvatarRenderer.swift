public import AppKit
public import Foundation
public import SupermuxMobileCore

/// Rasterizes a project avatar to PNG for surfaces that cannot host SwiftUI:
/// the macOS notification banner's ``UNNotificationAttachment``, and the bytes
/// the phone caches for its push avatar.
///
/// The output deliberately matches what the sidebar draws — same accent
/// resolution, same rounded-square geometry, same glyph precedence (image →
/// SF Symbol → letter) — because a banner avatar that disagrees with the
/// sidebar avatar for the same project reads as a different project.
///
/// Circular rather than rounded-square in the `circular` shape: the system
/// notification thumbnail and the phone's communication-notification avatar are
/// both presented as circles, and pre-clipping avoids the system masking a
/// rounded square into a lopsided blob.
///
/// Pure and synchronous: it takes bytes and values, never a store or the
/// filesystem, so callers control which actor pays for the raster and it is
/// unit-testable without an app.
public struct SupermuxProjectAvatarRenderer: Sendable {
    /// The avatar's outline.
    public enum Shape: Sendable, Equatable {
        /// A circle — the notification/lock-screen presentation.
        case circular
        /// A continuous rounded square at the sidebar's corner ratio.
        case roundedSquare
    }

    /// Creates a renderer.
    public init() {}

    /// Renders a project avatar and returns PNG bytes.
    ///
    /// - Parameters:
    ///   - project: The project identity to draw.
    ///   - image: The project's already-decoded icon, when it has one. Drawn
    ///     aspect-fill on a neutral plate rather than on the accent — repo
    ///     logos carry their own color and a tinted backing reads muddy.
    ///   - pixelSize: Output edge length in PIXELS (not points). The system
    ///     scales the thumbnail down, so oversampling is what keeps it crisp.
    ///   - shape: The outline to clip to.
    /// - Returns: PNG data, or `nil` when the bitmap context cannot be created.
    public func pngData(
        for project: SupermuxNotificationProject,
        image: NSImage?,
        pixelSize: Int = 256,
        shape: Shape = .circular
    ) -> Data? {
        let side = max(16, pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        let clip = Self.path(for: shape, in: bounds)
        clip.addClip()

        if let image {
            drawIcon(image, in: bounds)
        } else {
            drawGeneratedAvatar(for: project, in: bounds)
        }

        context.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }

    /// Writes a rendered avatar to a uniquely named file and returns its URL.
    ///
    /// ``UNNotificationAttachment`` takes ownership of the file it is given —
    /// it MOVES the URL into its own store — so the caller must hand it a
    /// disposable copy, never a path anything else reads. Each call therefore
    /// mints a fresh file under the caller's directory.
    ///
    /// - Parameters:
    ///   - project: The project identity to draw.
    ///   - image: The project's decoded icon, when it has one.
    ///   - directory: Directory to write into (created if missing).
    ///   - pixelSize: Output edge length in pixels.
    ///   - shape: The outline to clip to.
    /// - Returns: The written file's URL, or `nil` on any render/write failure.
    public func writeAvatar(
        for project: SupermuxNotificationProject,
        image: NSImage?,
        in directory: URL,
        pixelSize: Int = 256,
        shape: Shape = .circular
    ) -> URL? {
        guard let data = pngData(
            for: project, image: image, pixelSize: pixelSize, shape: shape
        ) else { return nil }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Drawing

    /// Draws the icon aspect-fill on a neutral plate, so a non-square logo
    /// fills the circle instead of leaving transparent wedges.
    private func drawIcon(_ image: NSImage, in bounds: NSRect) {
        NSColor.white.withAlphaComponent(0.94).setFill()
        bounds.fill()
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaled = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = NSPoint(
            x: bounds.midX - scaled.width / 2,
            y: bounds.midY - scaled.height / 2
        )
        image.draw(
            in: NSRect(origin: origin, size: scaled),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
    }

    /// Draws the accent-gradient plate carrying the project's SF Symbol, or
    /// its initial letter. White glyph on the accent, matching the app's other
    /// generated avatars.
    private func drawGeneratedAvatar(for project: SupermuxNotificationProject, in bounds: NSRect) {
        let accent = SupermuxProjectAccentPalette(
            colorHex: project.colorHex,
            projectID: project.id
        )
        let base = NSColor(
            srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1
        )
        // The same two-stop topLeading→bottomTrailing wash the sidebar and the
        // phone use, so one project reads as one object across every surface.
        let gradient = NSGradient(
            starting: base,
            ending: base.blended(withFraction: 0.28, of: .black) ?? base
        )
        gradient?.draw(in: bounds, angle: -45)

        let glyphSide = bounds.width * 0.46
        if let symbol = project.iconSymbol,
           !symbol.isEmpty,
           let rendered = Self.symbolImage(named: symbol, pointSize: glyphSide) {
            let size = rendered.size
            rendered.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2,
                    y: bounds.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: glyphSide, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let attributed = NSAttributedString(string: project.avatarLetter, attributes: attributes)
        let textSize = attributed.size()
        attributed.draw(at: NSPoint(
            x: bounds.midX - textSize.width / 2,
            y: bounds.midY - textSize.height / 2
        ))
    }

    /// A white-tinted SF Symbol at the requested point size, or `nil` when the
    /// symbol name does not resolve (a stale name must degrade to the letter
    /// avatar, never to an empty plate).
    private static func symbolImage(named name: String, pointSize: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let configured = symbol.withSymbolConfiguration(configuration) else { return nil }
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }

    /// The clip path for an outline.
    private static func path(for shape: Shape, in bounds: NSRect) -> NSBezierPath {
        switch shape {
        case .circular:
            return NSBezierPath(ovalIn: bounds)
        case .roundedSquare:
            let radius = bounds.width * 0.28
            return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        }
    }
}

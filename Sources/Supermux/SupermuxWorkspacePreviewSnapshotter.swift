import AppKit
import IOSurface
import WebKit

/// Best-effort, permission-free capture of a small still thumbnail of a
/// workspace's representative panel for the workspace switcher.
///
/// - **Terminal** panels are captured by reading Ghostty's existing
///   IOSurface-backed layer contents (the last rendered frame) — no screen
///   recording, and crucially no `cacheDisplay`/`forceRefresh`, so there is no
///   render on the typing hot path. A backgrounded surface may hold a stale or
///   blank frame, so the read is opportunistic: a blank result returns `nil` and
///   the caller keeps the cached/fallback card.
/// - **Browser** panels use `WKWebView.takeSnapshot` (async, off the main thread).
///
/// All captures are throttled by the controller (selected card first on open, the
/// rest warmed one-at-a-time after a workspace becomes visible).
@MainActor
enum SupermuxWorkspacePreviewSnapshotter {
    /// Pixel size of captured thumbnails (≈2× the card so it stays crisp).
    static let targetSize = CGSize(width: 480, height: 300)

    /// Captures a thumbnail for `workspace`, calling `completion` on the main
    /// actor with the image, or `nil` when no usable capture is available.
    static func capture(
        workspace: Workspace,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        guard let panel = representativePanel(for: workspace) else {
            completion(nil)
            return
        }
        if let browser = panel as? BrowserPanel {
            captureBrowser(browser, completion: completion)
        } else if let terminal = panel as? TerminalPanel {
            completion(captureTerminal(terminal))
        } else {
            completion(nil)
        }
    }

    /// The panel whose content best represents the workspace: the focused panel,
    /// else the first in display order.
    private static func representativePanel(for workspace: Workspace) -> (any Panel)? {
        if let focused = workspace.focusedPanelId, let panel = workspace.panels[focused] {
            return panel
        }
        if let firstId = workspace.orderedPanelIds.first, let panel = workspace.panels[firstId] {
            return panel
        }
        return workspace.panels.values.first
    }

    // MARK: - Terminal (Ghostty IOSurface)

    private static func captureTerminal(_ panel: TerminalPanel) -> NSImage? {
        guard let cgImage = copyGhosttyLayerImage(in: panel.hostedView),
              !isProbablyBlank(cgImage) else {
            return nil
        }
        let full = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return downscaled(full)
    }

    /// Finds the Metal-backed Ghostty view in the panel's view tree and copies its
    /// current IOSurface (or CGImage) layer contents without forcing a render.
    private static func copyGhosttyLayerImage(in root: NSView) -> CGImage? {
        guard let view = firstGhosttyView(in: root),
              let modelLayer = view.layer else { return nil }
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return nil }

        // Ghostty backs the surface layer with an IOSurface (see the DEBUG
        // `debugCopyIOSurfaceCGImage` helper this mirrors).
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        let surface = contents as! IOSurfaceRef

        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)

        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func firstGhosttyView(in root: NSView) -> GhosttyNSView? {
        if let view = root as? GhosttyNSView { return view }
        for subview in root.subviews {
            if let found = firstGhosttyView(in: subview) { return found }
        }
        return nil
    }

    /// Cheap blank-frame guard: renders the image into a tiny RGBA bitmap and
    /// reports near-uniform content (a stale/blank backgrounded surface) so the
    /// caller keeps its cached thumbnail or fallback card instead.
    private static func isProbablyBlank(_ image: CGImage) -> Bool {
        let w = 16, h = 10
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minV: [UInt8] = [255, 255, 255]
        var maxV: [UInt8] = [0, 0, 0]
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                let value = pixels[pixel + channel]
                if value < minV[channel] { minV[channel] = value }
                if value > maxV[channel] { maxV[channel] = value }
            }
        }
        // Uniform within ~8/255 on every channel ⇒ treat as blank.
        return (0..<3).allSatisfy { Int(maxV[$0]) - Int(minV[$0]) <= 8 }
    }

    // MARK: - Browser (WKWebView)

    private static func captureBrowser(
        _ panel: BrowserPanel,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        let webView = panel.webView
        guard webView.bounds.width > 1, webView.bounds.height > 1 else {
            completion(nil)
            return
        }
        let configuration = WKSnapshotConfiguration()
        // Snapshot the current rendered content without forcing a fresh layout.
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            DispatchQueue.main.async {
                completion(image.flatMap(downscaled))
            }
        }
    }

    // MARK: - Downscale

    /// Aspect-fill downscale to `targetSize`, bounding thumbnail memory.
    private static func downscaled(_ image: NSImage) -> NSImage {
        let target = targetSize
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }

        let scale = max(target.width / source.width, target.height / source.height)
        let scaledSize = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(
            x: (target.width - scaledSize.width) / 2,
            y: (target.height - scaledSize.height) / 2
        )

        let output = NSImage(size: target)
        output.lockFocus()
        defer { output.unlockFocus() }
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: target).fill()
        image.draw(
            in: CGRect(origin: origin, size: scaledSize),
            from: CGRect(origin: .zero, size: source),
            operation: .copy,
            fraction: 1.0
        )
        return output
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The icon-editing controls for a project: an SF Symbol name field plus a
/// custom-image picker that lets the user choose any image file when the
/// auto-detected repository logo is wrong or missing.
///
/// The previewed precedence mirrors ``SupermuxProjectAvatarView`` and
/// ``SupermuxProjectIconResolver/resolveAvatar(rootPath:customIconPath:)``:
/// custom image → detected logo → SF Symbol → letter. A chosen custom image
/// therefore wins over auto-detection; clearing it falls back to the logo probe.
struct SupermuxProjectIconEditor: View {
    /// Project root, probed for an auto-detected logo to preview.
    let rootPath: String
    /// Bound SF Symbol text (owned by the editor sheet).
    @Binding var iconSymbolText: String
    /// Bound absolute path to the user's custom icon, or `nil`.
    @Binding var customIconPath: String?

    /// Logo auto-detected from the project files, previewed when no custom icon.
    @State private var detectedIcon: NSImage?
    /// Project-relative path of the detected logo, shown next to its preview.
    @State private var detectedRelativePath: String?
    /// Preview of the user-chosen custom icon image, when one loads.
    @State private var customIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            symbolField
            customImageRow
        }
        .task { await refreshPreviews() }
    }

    // MARK: - Rows

    private var symbolField: some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "supermux.projectEditor.icon", defaultValue: "Icon"),
                text: $iconSymbolText,
                prompt: Text(String(
                    localized: "supermux.projectEditor.iconPrompt",
                    defaultValue: "SF Symbol name"
                ))
            )
            .autocorrectionDisabled()
            if isSymbolPreviewable {
                Image(systemName: trimmedSymbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customImageRow: some View {
        HStack(spacing: 8) {
            previewThumbnail
            statusText
            Spacer(minLength: 8)
            Button(String(
                localized: "supermux.projectEditor.icon.chooseCustom",
                defaultValue: "Choose Image…"
            )) { chooseCustomIcon() }
            if customIconPath != nil {
                Button(String(
                    localized: "supermux.projectEditor.icon.removeCustom",
                    defaultValue: "Remove"
                )) { clearCustomIcon() }
            }
        }
    }

    @ViewBuilder private var previewThumbnail: some View {
        if let image = customIcon ?? detectedIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ViewBuilder private var statusText: some View {
        if customIconPath != nil {
            if customIcon != nil {
                Text(verbatim: customFileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(String(
                    localized: "supermux.projectEditor.icon.customMissing",
                    defaultValue: "Custom image file could not be loaded"
                ))
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            }
        } else if let detectedRelativePath {
            Text(String(
                localized: "supermux.projectEditor.icon.detected",
                defaultValue: "Using detected logo \(detectedRelativePath)"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(String(
                localized: "supermux.projectEditor.icon.help",
                defaultValue: "Shown when no logo file is found in the project"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived state

    private var trimmedSymbol: String {
        iconSymbolText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSymbolPreviewable: Bool {
        !trimmedSymbol.isEmpty
            && NSImage(systemSymbolName: trimmedSymbol, accessibilityDescription: nil) != nil
    }

    private var customFileName: String {
        guard let customIconPath else { return "" }
        return (customIconPath as NSString).lastPathComponent
    }

    // MARK: - Actions

    /// Opens a file picker for an image and stores the chosen path. The chosen
    /// file overrides auto-detection until the user removes it.
    private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .svg, .icns]
        panel.prompt = String(
            localized: "supermux.projectEditor.icon.chooseCustom",
            defaultValue: "Choose Image…"
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customIconPath = url.path
        customIcon = NSImage(contentsOf: url)
    }

    /// Clears the custom icon, falling back to auto-detection / symbol / letter.
    private func clearCustomIcon() {
        customIconPath = nil
        customIcon = nil
    }

    /// Loads both previews: the auto-detected repository logo and the custom
    /// image, if a path is set. The probe *and* the file reads run off the main
    /// actor (only `Sendable` `Data`/`URL` cross back); the non-`Sendable`
    /// `NSImage` is decoded on the main actor.
    private func refreshPreviews() async {
        let root = rootPath
        let customPath = customIconPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolver = SupermuxProjectIconResolver()
        let loaded = await Task.detached { () -> (detectedURL: URL?, detectedData: Data?, customURL: URL?, customData: Data?) in
            let detectedURL = resolver.resolve(rootPath: root)
            let detectedData = detectedURL.flatMap { try? Data(contentsOf: $0) }
            var customURL: URL?
            if let customPath, !customPath.isEmpty {
                customURL = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            }
            let customData = customURL.flatMap { try? Data(contentsOf: $0) }
            return (detectedURL, detectedData, customURL, customData)
        }.value
        if let detectedURL = loaded.detectedURL {
            detectedIcon = Self.decode(loaded.detectedData, fallbackURL: detectedURL)
            let expandedRoot = (root as NSString).expandingTildeInPath
            detectedRelativePath = detectedURL.path.hasPrefix(expandedRoot + "/")
                ? String(detectedURL.path.dropFirst(expandedRoot.count + 1))
                : detectedURL.lastPathComponent
        } else {
            detectedIcon = nil
            detectedRelativePath = nil
        }
        customIcon = Self.decode(loaded.customData, fallbackURL: loaded.customURL)
    }

    /// Decodes icon bytes into an image; rare formats whose rep needs the file
    /// URL (rather than sniffing the data) fall back to a direct file load.
    private static func decode(_ data: Data?, fallbackURL: URL?) -> NSImage? {
        if let data, let image = NSImage(data: data) { return image }
        return fallbackURL.flatMap { NSImage(contentsOf: $0) }
    }
}

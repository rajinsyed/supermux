public import SupermuxMobileCore
public import SwiftUI

/// One file's diff: monospaced unified-diff text with additions tinted green
/// and removals red, plus explicit binary / truncated / empty / failed
/// placeholder states. Fetches once per push through the injected loader.
public struct SupermuxDiffScreen: View {
    /// Where the load currently stands.
    private enum Phase {
        case loading
        case failed(String)
        case binary
        case empty
        case loaded([SupermuxDiffLine], truncated: Bool)
    }

    private let path: String
    private let load: @MainActor () async throws -> SupermuxDiffDTO

    @State private var phase: Phase = .loading

    /// Creates the diff screen.
    /// - Parameters:
    ///   - path: The file's repo-root-relative path (title shows the
    ///     filename; the full path renders under the diff states).
    ///   - load: Fetches the diff payload; throwing lands in the retry state.
    public init(path: String, load: @escaping @MainActor () async throws -> SupermuxDiffDTO) {
        self.path = path
        self.load = load
    }

    public var body: some View {
        content
            .navigationTitle(path.split(separator: "/").last.map(String.init) ?? path)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .accessibilityIdentifier("SupermuxDiffScreen")
            .task { await loadDiff() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text(String(
                    localized: "supermux.diff.loading",
                    defaultValue: "Loading diff…",
                    bundle: .module
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                Text(String(
                    localized: "supermux.diff.failed.title",
                    defaultValue: "Couldn’t Load Diff",
                    bundle: .module
                ))
                .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task { await loadDiff() }
                } label: {
                    Text(String(
                        localized: "supermux.diff.retry",
                        defaultValue: "Retry",
                        bundle: .module
                    ))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("SupermuxDiffRetryButton")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .binary:
            diffPlaceholder(
                systemImage: "doc.zipper",
                message: String(
                    localized: "supermux.diff.binary",
                    defaultValue: "Binary file — no text diff available.",
                    bundle: .module
                )
            )
        case .empty:
            diffPlaceholder(
                systemImage: "doc",
                message: String(
                    localized: "supermux.diff.empty",
                    defaultValue: "No changes in this file.",
                    bundle: .module
                )
            )
        case let .loaded(lines, truncated):
            diffText(lines, truncated: truncated)
        }
    }

    private func diffPlaceholder(systemImage: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func diffText(_ lines: [SupermuxDiffLine], truncated: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    SupermuxDiffLineRow(line: line)
                }
                if truncated {
                    Text(String(
                        localized: "supermux.diff.truncated",
                        defaultValue: "Diff truncated — showing only the beginning.",
                        bundle: .module
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("SupermuxDiffTruncatedNote")
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// One diff line: verbatim monospaced text with the kind's tint. Values
/// only — no store reference below the `LazyVStack` boundary.
struct SupermuxDiffLineRow: View {
    let line: SupermuxDiffLine

    var body: some View {
        Text(verbatim: line.text.isEmpty ? " " : line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 0.5)
            .background(background)
    }

    /// Green additions / red removals, matching the repo's diff conventions
    /// (system semantic colors, like the desktop changes panel).
    private var foreground: Color {
        switch line.kind {
        case .addition: .green
        case .removal: .red
        case .hunk: .cyan
        case .meta: .secondary
        case .context: .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.10)
        case .removal: .red.opacity(0.10)
        case .hunk, .meta, .context: .clear
        }
    }
}

extension SupermuxDiffScreen {
    private func loadDiff() async {
        phase = .loading
        do {
            let diff = try await load()
            if diff.isBinary == true {
                phase = .binary
                return
            }
            let lines = SupermuxDiffLine.lines(from: diff.diffText ?? "")
            phase = lines.isEmpty
                ? .empty
                : .loaded(lines, truncated: diff.truncated == true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

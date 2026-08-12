public import SupermuxMobileCore
public import SwiftUI

/// Labels and option lookups for the model/effort runtime picker.
///
/// lint:allow namespace-enum — stateless lookup helpers.
public enum SupermuxClaudeRuntimeLabels {
    /// The model's display title, falling back to its raw value and then to a
    /// localized placeholder while options are still loading.
    /// - Parameters:
    ///   - model: The selected model value.
    ///   - options: The Mac's advertised options, if loaded.
    public static func modelTitle(_ model: String?, options: SupermuxClaudeOptionsDTO?) -> String {
        guard let model else {
            return String(
                localized: "supermux.claude.model.default",
                defaultValue: "Default",
                bundle: .module
            )
        }
        let match = options?.models.first { $0.value == model }
        return match?.displayName ?? model
    }

    /// The effort levels available for a model.
    ///
    /// Falls back to the Mac's union of supported levels when the model is
    /// unknown, so the slider still offers something usable rather than
    /// disappearing while the catalog loads.
    ///
    /// - Parameters:
    ///   - model: The selected model value.
    ///   - options: The Mac's advertised options.
    public static func effortLevels(
        for model: String?,
        options: SupermuxClaudeOptionsDTO?
    ) -> [String] {
        guard let options else { return [] }
        if let model, let match = options.models.first(where: { $0.value == model }),
           !match.supportedEffortLevels.isEmpty {
            return match.supportedEffortLevels
        }
        return options.supportedEffortLevels
    }

    /// Whether fast mode may be toggled for the selected model.
    /// - Parameters:
    ///   - model: The selected model value.
    ///   - options: The Mac's advertised options.
    public static func supportsFastMode(
        model: String?,
        options: SupermuxClaudeOptionsDTO?
    ) -> Bool {
        guard let options else { return false }
        if let model, let match = options.models.first(where: { $0.value == model }) {
            return match.supportsFastMode
        }
        return options.supportsFastMode
    }
}

extension View {
    /// Presents the model/effort runtime picker over this view.
    ///
    /// A full-screen overlay rather than a sheet — ported from remodex's
    /// `ComposerRuntimeSliderOverlay` — because the chat composer must keep
    /// its keyboard and focus while the picker is up. A sheet would resign
    /// first responder and drop the draft's cursor position.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the picker shows.
    ///   - options: The Mac's advertised options.
    ///   - isLoading: Whether options are still in flight.
    ///   - model: The selected model.
    ///   - effort: The selected effort.
    ///   - fastMode: The fast-mode toggle.
    @MainActor
    public func supermuxClaudeRuntimePicker(
        isPresented: Binding<Bool>,
        options: SupermuxClaudeOptionsDTO?,
        isLoading: Bool,
        model: Binding<String?>,
        effort: Binding<String?>,
        fastMode: Binding<Bool>
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                SupermuxClaudeRuntimePickerOverlay(
                    options: options,
                    isLoading: isLoading,
                    model: model,
                    effort: effort,
                    fastMode: fastMode,
                    dismiss: { isPresented.wrappedValue = false }
                )
            }
        }
    }
}

/// The centered runtime picker: a model menu, an effort fill slider, and the
/// fast-mode toggle, over a blurred backdrop that dismisses on tap.
struct SupermuxClaudeRuntimePickerOverlay: View {
    let options: SupermuxClaudeOptionsDTO?
    let isLoading: Bool
    @Binding var model: String?
    @Binding var effort: String?
    @Binding var fastMode: Bool
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private var levels: [String] {
        SupermuxClaudeRuntimeLabels.effortLevels(for: model, options: options)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(isVisible ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { close() }

            // Centered by the ZStack: the picker lands mid-screen no matter
            // where it was opened from or whether the keyboard is up.
            VStack(spacing: 18) {
                modelRow
                if levels.isEmpty {
                    unavailableRow
                } else {
                    SupermuxClaudeEffortSlider(levels: levels, selection: $effort)
                }
                if SupermuxClaudeRuntimeLabels.supportsFastMode(model: model, options: options) {
                    Toggle(isOn: $fastMode) {
                        Text(String(
                            localized: "supermux.claude.fastMode",
                            defaultValue: "Fast mode",
                            bundle: .module
                        ))
                        .font(SupermuxClaudeStyle.body())
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 28)
            .opacity(isVisible ? 1 : 0)
            // Scaled on the controls block alone, so the picker expands from
            // its own center and reads as popping into place.
            .scaleEffect(isVisible ? 1 : 0.85)
        }
        .onAppear {
            guard !reduceMotion else {
                isVisible = true
                return
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { isVisible = true }
        }
    }

    private var modelRow: some View {
        Menu {
            ForEach(options?.models ?? [], id: \.value) { option in
                Button {
                    model = option.value
                    // The new model may not support the current effort; drop
                    // to its own top level rather than sending one the Mac
                    // would reject.
                    let available = SupermuxClaudeRuntimeLabels.effortLevels(
                        for: option.value,
                        options: options
                    )
                    if let effort, !available.contains(effort) {
                        self.effort = available.last
                    }
                } label: {
                    Text(option.displayName ?? option.value)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(SupermuxClaudeRuntimeLabels.modelTitle(model, options: options))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }

    private var unavailableRow: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(isLoading
                ? String(
                    localized: "supermux.claude.model.loading",
                    defaultValue: "Loading model options…",
                    bundle: .module
                )
                : String(
                    localized: "supermux.claude.model.unavailable",
                    defaultValue: "Model options unavailable. Check the Mac connection.",
                    bundle: .module
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func close() {
        guard !reduceMotion else {
            dismiss()
            return
        }
        withAnimation(.easeIn(duration: 0.18)) {
            isVisible = false
        } completion: {
            dismiss()
        }
    }
}

/// The effort fill slider: one segment per level, filled up to the selection.
///
/// A fill slider rather than a picker because effort is ORDERED — "more" and
/// "less" are the two things a user actually wants to express, and a segmented
/// control of opaque names does not show that.
struct SupermuxClaudeEffortSlider: View {
    let levels: [String]
    @Binding var selection: String?

    private var selectedIndex: Int {
        guard let selection, let index = levels.firstIndex(of: selection) else {
            return max(levels.count - 1, 0)
        }
        return index
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    Button {
                        selection = level
                    } label: {
                        Capsule()
                            .fill(index <= selectedIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(height: 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(level)
                }
            }
            Text(levels.indices.contains(selectedIndex) ? levels[selectedIndex] : "")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}

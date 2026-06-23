import CmuxSettings
import SwiftUI

/// SUPERMUX — Settings card for the Vercel AI Gateway API key and model.
///
/// This is supermux-owned code that lives in the upstream `CmuxSettingsUI`
/// package because the package's section stack is closed to app-side injection
/// and cannot import `SupermuxKit` (that would be a reverse dependency). The
/// card is therefore fully self-contained: it depends only on `CmuxSettings`
/// and SwiftUI, and shares a single contract with `SupermuxKit.SupermuxAIConfig`
/// — the on-disk secret file name and the UserDefaults model-override key,
/// duplicated below. The supermux feature code reads the same secret file and
/// defaults key independently.
///
/// Rendered as one extra card inside ``AutomationSection`` (see the
/// `ai-settings` SUPERMUX touchpoint).
@MainActor
public struct SupermuxAISettingsCard: View {
    // MARK: Contract with SupermuxKit.SupermuxAIConfig — keep in sync.
    private static let secretKeyID = "supermux.ai.gatewayApiKey"
    private static let secretFileName = "supermux-ai-gateway-key"
    private static let modelDefaultsKey = "supermux.ai.model"
    private static let defaultModelPlaceholder = "openai/gpt-5.4-mini"

    @State private var keyModel: SecretValueModel
    @State private var keyDraft: String = ""
    @State private var status: StatusLine?
    @AppStorage(SupermuxAISettingsCard.modelDefaultsKey) private var modelSlug: String = ""

    private struct StatusLine: Equatable {
        let message: String
        let isError: Bool
    }

    /// Creates the card.
    /// - Parameters:
    ///   - secretStore: The app's secret-file store (rooted at the cmux state
    ///     directory) — the same store every other secret row uses.
    ///   - errorLog: Settings error log for surfacing write failures centrally.
    public init(secretStore: SecretFileStore, errorLog: SettingsErrorLog) {
        _keyModel = State(initialValue: SecretValueModel(
            store: secretStore,
            key: SecretFileKey(id: Self.secretKeyID, fileName: Self.secretFileName),
            errorLog: errorLog
        ))
    }

    public var body: some View {
        let hasKey = !keyModel.current.isEmpty
        SettingsCard {
            keyRow(hasKey: hasKey)
            SettingsCardDivider()
            modelRow
            SettingsCardDivider()
            SettingsCardNote(String(
                localized: "supermux.settings.ai.note",
                defaultValue: "Create a key at vercel.com/ai-gateway. It is stored in a private 0600 file on this Mac and is never written to cmux.json."
            ))
            if let status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isError ? Color.red : Color.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func keyRow(hasKey: Bool) -> some View {
        SettingsCardRow(
            String(localized: "supermux.settings.ai.key", defaultValue: "Vercel AI Gateway API Key"),
            subtitle: hasKey
                ? String(localized: "supermux.settings.ai.key.subtitleSet", defaultValue: "Stored securely. Used for AI branch names and commit messages.")
                : String(localized: "supermux.settings.ai.key.subtitleUnset", defaultValue: "Paste a key to enable supermux AI features.")
        ) {
            HStack(spacing: 8) {
                SecureField(
                    String(localized: "supermux.settings.ai.key.placeholder", defaultValue: "vck_…"),
                    text: $keyDraft
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                Button(
                    hasKey
                        ? String(localized: "supermux.settings.ai.key.change", defaultValue: "Change")
                        : String(localized: "supermux.settings.ai.key.set", defaultValue: "Set")
                ) {
                    saveKey()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button(String(localized: "supermux.settings.ai.key.clear", defaultValue: "Clear")) {
                        clearKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var modelRow: some View {
        SettingsCardRow(
            String(localized: "supermux.settings.ai.model", defaultValue: "Model"),
            subtitle: String(localized: "supermux.settings.ai.model.subtitle", defaultValue: "Model slug used for AI features. Leave blank for the default.")
        ) {
            TextField(Self.defaultModelPlaceholder, text: $modelSlug)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
        }
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        keyModel.set(trimmed)
        keyDraft = ""
        status = StatusLine(
            message: String(localized: "supermux.settings.ai.key.saved", defaultValue: "Saved."),
            isError: false
        )
    }

    private func clearKey() {
        keyModel.reset()
        keyDraft = ""
        status = StatusLine(
            message: String(localized: "supermux.settings.ai.key.cleared", defaultValue: "Cleared."),
            isError: false
        )
    }
}

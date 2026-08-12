import CmuxAgentChatUI
public import SupermuxMobileCore
public import SupermuxMobileKit
public import SwiftUI

/// The Claude harness chat screen: the transcript, the runtime accessory row,
/// and the composer.
///
/// Every value the rows need is snapshotted ABOVE the scroll view, so nothing
/// below the lazy boundary holds a store reference (the SwiftUI list-boundary
/// rule in CLAUDE.md). The composer's callbacks are the only things that
/// reach back into the store, and they run from `Task`, not from `body`.
public struct SupermuxClaudeChatScreen: View {
    private let store: SupermuxClaudeConversationStore
    private let options: SupermuxClaudeOptionsDTO?

    @State private var draft = ""
    @State private var isSending = false
    @State private var isPresentingRuntimePicker = false
    @State private var pendingModel: String?
    @State private var pendingEffort: String?
    @State private var pendingFastMode = false
    @State private var markdownRenderer = ChatMarkdownRenderer()

    /// Creates the chat screen.
    /// - Parameters:
    ///   - store: The live conversation session.
    ///   - options: The Mac's advertised options, for the runtime pills and
    ///     the composer's slash-command autocomplete. `nil` hides both.
    public init(
        store: SupermuxClaudeConversationStore,
        options: SupermuxClaudeOptionsDTO? = nil
    ) {
        self.store = store
        self.options = options
    }

    public var body: some View {
        // Snapshot the observable state ONCE, above the transcript.
        let rows = SupermuxClaudeTranscriptPresentation.rows(for: store.transcript.messages)
        let session = store.session
        let isWorking = store.isWorking
        let hasLoaded = store.hasLoaded
        let hasMoreHistory = store.transcript.hasMoreHistory

        VStack(spacing: 0) {
            transcript(rows: rows, hasLoaded: hasLoaded, hasMoreHistory: hasMoreHistory)
            accessoryRow(session: session, isWorking: isWorking)
            SupermuxClaudeComposer(
                draft: $draft,
                isSending: isSending,
                isWorking: isWorking,
                slashCommands: options?.slashCommands ?? [],
                send: { text in Task { await send(text) } },
                stop: { Task { try? await store.interrupt() } }
            )
        }
        .environment(\.chatMarkdownRenderer, markdownRenderer)
        .navigationTitle(session?.title ?? String(
            localized: "supermux.claude.sessions.title",
            defaultValue: "Claude",
            bundle: .module
        ))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .supermuxClaudeRuntimePicker(
            isPresented: $isPresentingRuntimePicker,
            options: options,
            isLoading: false,
            model: Binding(get: { pendingModel }, set: { applyModel($0) }),
            effort: Binding(get: { pendingEffort }, set: { applyEffort($0) }),
            fastMode: Binding(get: { pendingFastMode }, set: { applyFastMode($0) })
        )
        .task {
            await store.run()
        }
        // Keyed on the runtime VALUES, not on the snapshot's `version`: that
        // number is the Mac's live-session revision and resets when a session
        // ends, so keying on it would miss the very change that mattered.
        .onChange(of: RuntimeSnapshot(session: session), initial: true) { _, snapshot in
            // Adopt the Mac's reconciled runtime, so the pills always show
            // what is actually running rather than what this phone asked for.
            pendingModel = snapshot.model
            pendingEffort = snapshot.effort
            pendingFastMode = snapshot.fastMode
        }
        .accessibilityIdentifier("SupermuxClaudeChatScreen")
    }

    // MARK: Transcript

    private func transcript(
        rows: [SupermuxClaudeTranscriptRow],
        hasLoaded: Bool,
        hasMoreHistory: Bool
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SupermuxClaudeStyle.looseSpacing) {
                if hasMoreHistory {
                    Button {
                        Task { await store.loadOlderHistory() }
                    } label: {
                        Text(String(
                            localized: "supermux.claude.history.older",
                            defaultValue: "Load earlier messages",
                            bundle: .module
                        ))
                        .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                }
                ForEach(rows) { row in
                    SupermuxClaudeTranscriptRowView(row: row) { messageID in
                        guard let data = try? await store.toolPayload(messageID: messageID) else {
                            return nil
                        }
                        return String(decoding: data, as: UTF8.self)
                    }
                    .id(row.id)
                }
                if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, SupermuxClaudeStyle.horizontalMargin)
            .padding(.vertical, SupermuxClaudeStyle.looseSpacing)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Accessory row

    private func accessoryRow(session: SupermuxClaudeSessionDTO?, isWorking: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                isPresentingRuntimePicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(SupermuxClaudeRuntimeLabels.modelTitle(session?.model, options: options))
                        .font(.caption.weight(.medium))
                    if let effort = session?.effort {
                        Text(effort)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(options == nil)

            if isWorking {
                SupermuxChatShimmerText(text: String(
                    localized: "supermux.claude.working",
                    defaultValue: "Working",
                    bundle: .module
                ))
                .equatable()
            }

            Spacer(minLength: 0)

            if let queued = session?.queuedCount, queued > 0 {
                Label {
                    Text(String(
                        localized: "supermux.claude.queued.count",
                        defaultValue: "\(queued) queued",
                        bundle: .module
                    ))
                    .font(.caption)
                } icon: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
                .foregroundStyle(.secondary)
            }

            if let session, let cost = SupermuxClaudeSessionPresentation.costLabel(session.cost) {
                Text(cost)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, SupermuxClaudeStyle.horizontalMargin)
        .padding(.vertical, 6)
    }

    /// The runtime fields the accessory pills mirror, so `onChange` fires on a
    /// real runtime change and nothing else.
    private struct RuntimeSnapshot: Equatable {
        let model: String?
        let effort: String?
        let fastMode: Bool

        init(session: SupermuxClaudeSessionDTO?) {
            self.model = session?.model
            self.effort = session?.effort
            self.fastMode = session?.fastMode ?? false
        }
    }

    // MARK: Actions

    private func send(_ text: String) async {
        isSending = true
        defer { isSending = false }
        // Clear optimistically: the Mac echoes the prompt back as a transcript
        // message, so leaving the draft up would show it twice. On failure the
        // draft is restored rather than silently lost.
        draft = ""
        do {
            _ = try await store.send(text: text)
        } catch {
            draft = text
        }
    }

    private func applyModel(_ value: String?) {
        pendingModel = value
        guard let value else { return }
        Task { _ = try? await store.setOption(.model, to: .string(value)) }
    }

    private func applyEffort(_ value: String?) {
        pendingEffort = value
        guard let value else { return }
        Task { _ = try? await store.setOption(.effort, to: .string(value)) }
    }

    private func applyFastMode(_ value: Bool) {
        pendingFastMode = value
        Task { _ = try? await store.setOption(.fastMode, to: .bool(value)) }
    }
}

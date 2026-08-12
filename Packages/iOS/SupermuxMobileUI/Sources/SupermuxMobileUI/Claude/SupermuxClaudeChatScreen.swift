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
    private let resume: (@MainActor () async -> Bool)?

    @State private var draft = ""
    @State private var isSending = false
    @State private var isResuming = false
    @State private var isPresentingRuntimePicker = false
    @State private var pendingModel: String?
    @State private var pendingEffort: String?
    @State private var pendingFastMode = false
    @State private var showsOptionError = false
    @State private var markdownRenderer = ChatMarkdownRenderer()

    /// Creates the chat screen.
    /// - Parameters:
    ///   - store: The live conversation session.
    ///   - options: The Mac's advertised options, for the runtime pills and
    ///     the composer's slash-command autocomplete. `nil` hides both.
    ///   - resume: Resumes the ended session on the Mac, returning whether it
    ///     came back. `nil` hides the in-chat resume affordance.
    public init(
        store: SupermuxClaudeConversationStore,
        options: SupermuxClaudeOptionsDTO? = nil,
        resume: (@MainActor () async -> Bool)? = nil
    ) {
        self.store = store
        self.options = options
        self.resume = resume
    }

    public var body: some View {
        // Snapshot the observable state ONCE, above the transcript.
        let rows = SupermuxClaudeTranscriptPresentation.rows(for: store.transcript.messages)
        let session = store.session
        let isWorking = store.isWorking
        let hasLoaded = store.hasLoaded
        let hasMoreHistory = store.transcript.hasMoreHistory
        let isEnded = Self.isEnded(session)

        VStack(spacing: 0) {
            transcript(
                rows: rows,
                hasLoaded: hasLoaded,
                hasMoreHistory: hasMoreHistory,
                isEnded: isEnded
            )
            if isEnded {
                endedNotice
            }
            accessoryRow(session: session, isWorking: isWorking)
            SupermuxClaudeComposer(
                draft: $draft,
                isSending: isSending || isEnded,
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

    /// Whether the session cannot accept prompts (ended or failed on the Mac).
    private static func isEnded(_ session: SupermuxClaudeSessionDTO?) -> Bool {
        switch session?.state {
        case .ended, .failed: true
        case .starting, .working, .idle, nil: false
        }
    }

    // MARK: Transcript

    private func transcript(
        rows: [SupermuxClaudeTranscriptRow],
        hasLoaded: Bool,
        hasMoreHistory: Bool,
        isEnded: Bool
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
                // An ended session whose Mac process is gone has no history
                // endpoint to load from, so a spinner would just spin forever;
                // the ended notice below the transcript explains the state.
                if !hasLoaded, !isEnded {
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

    // MARK: Ended notice

    /// The ended-session bar: names the state instead of letting a send fail
    /// with a not-found error, and offers Resume when the host can.
    private var endedNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            Text(String(
                localized: "supermux.claude.ended.notice",
                defaultValue: "This session has ended.",
                bundle: .module
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if resume != nil {
                Button {
                    Task { await resumeSession() }
                } label: {
                    if isResuming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(String(
                            localized: "supermux.claude.resume",
                            defaultValue: "Resume",
                            bundle: .module
                        ))
                        .font(.footnote.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(isResuming)
            }
        }
        .padding(.horizontal, SupermuxClaudeStyle.horizontalMargin)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
        .accessibilityIdentifier("SupermuxClaudeEndedNotice")
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

            if showsOptionError {
                Text(String(
                    localized: "supermux.claude.option.rejected",
                    defaultValue: "Setting not applied",
                    bundle: .module
                ))
                .font(.caption)
                .foregroundStyle(.red)
                .transition(.opacity)
            } else if isWorking {
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
        // An ended session has no process to receive the prompt — the Mac
        // would answer not-found. The ended notice is already naming the
        // state, so the draft simply stays put.
        guard !Self.isEnded(store.session) else { return }
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

    private func resumeSession() async {
        guard let resume else { return }
        isResuming = true
        defer { isResuming = false }
        _ = await resume()
        // Success or failure, the authoritative snapshot decides what shows:
        // on success the state flips and the notice disappears; on failure it
        // stays, which is the honest reading.
    }

    private func applyModel(_ value: String?) {
        pendingModel = value
        guard let value else { return }
        Task {
            await applyOption(.model, value: .string(value)) {
                pendingModel = store.session?.model
            }
        }
    }

    private func applyEffort(_ value: String?) {
        pendingEffort = value
        guard let value else { return }
        Task {
            await applyOption(.effort, value: .string(value)) {
                pendingEffort = store.session?.effort
            }
        }
    }

    private func applyFastMode(_ value: Bool) {
        pendingFastMode = value
        Task {
            await applyOption(.fastMode, value: .bool(value)) {
                pendingFastMode = store.session?.fastMode ?? false
            }
        }
    }

    /// Sends one option mutation. On rejection the pending value is rolled
    /// back to the authoritative snapshot — a rejected `setOption` leaves the
    /// Mac unchanged, so `onChange` never fires and an optimistic pending
    /// value would keep the picker lying — and a brief inline error names
    /// what happened.
    private func applyOption(
        _ option: SupermuxClaudeOption,
        value: SupermuxClaudeOptionValue,
        rollback: @MainActor () -> Void
    ) async {
        do {
            _ = try await store.setOption(option, to: value)
            showsOptionError = false
        } catch {
            rollback()
            withAnimation { showsOptionError = true }
            try? await Task.sleep(for: .seconds(4))
            withAnimation { showsOptionError = false }
        }
    }
}

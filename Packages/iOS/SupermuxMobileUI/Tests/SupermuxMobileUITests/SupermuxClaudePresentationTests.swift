import SupermuxMobileCore
import SupermuxMobileKit
@testable import SupermuxMobileUI
import Testing

/// The Claude harness screens' presentation logic: session grouping and dots,
/// transcript row projection, to-do parsing, and the composer's gates.
@Suite struct SupermuxClaudePresentationTests {
    private func session(
        id: String = "s1",
        cwd: String = "/repo",
        state: SupermuxClaudeSessionState = .idle,
        model: String? = nil,
        launcher: SupermuxClaudeLauncher = .claude,
        queued: Int = 0,
        cost: SupermuxClaudeCostDTO = SupermuxClaudeCostDTO(totalUSD: 0, turns: 0, durationMS: 0),
        lastActivityAt: Double? = 1
    ) -> SupermuxClaudeSessionDTO {
        SupermuxClaudeSessionDTO(
            sessionID: id,
            title: "Session \(id)",
            cwd: cwd,
            launcher: launcher,
            model: model,
            state: state,
            cost: cost,
            queuedCount: queued,
            lastActivityAt: lastActivityAt,
            version: 1
        )
    }

    // MARK: Session list

    @Test func groupsPreserveTheStoresActivityOrder() {
        let groups = SupermuxClaudeSessionPresentation.groups(for: [
            session(id: "a", cwd: "/work/beta"),
            session(id: "b", cwd: "/work/alpha"),
            session(id: "c", cwd: "/work/beta"),
        ])
        // Beta first because its most recent session came first; re-sorting
        // alphabetically here would throw away the store's activity ordering.
        #expect(groups.map(\.cwd) == ["/work/beta", "/work/alpha"])
        #expect(groups.map(\.title) == ["beta", "alpha"])
        #expect(groups.first?.sessions.map(\.sessionID) == ["a", "c"])
    }

    @Test func directoryNamesFallBackToTheWholePath() {
        #expect(SupermuxClaudeSessionPresentation.displayName(forPath: "/a/b/c") == "c")
        #expect(SupermuxClaudeSessionPresentation.displayName(forPath: "/a/b/c/") == "c")
        #expect(SupermuxClaudeSessionPresentation.displayName(forPath: "/") == "/")
        #expect(SupermuxClaudeSessionPresentation.displayName(forPath: "bare") == "bare")
    }

    /// The dot palette carries meaning, so each state maps to exactly one
    /// colour and states with no news draw nothing at all.
    @Test func dotsShowOnlyForStatesThatCarryNews() {
        #expect(SupermuxClaudeSessionPresentation.showsDot(for: .working))
        #expect(SupermuxClaudeSessionPresentation.showsDot(for: .finishedUnopened))
        #expect(SupermuxClaudeSessionPresentation.showsDot(for: .failed))
        #expect(!SupermuxClaudeSessionPresentation.showsDot(for: .idle))
        #expect(!SupermuxClaudeSessionPresentation.showsDot(for: .finished))

        #expect(SupermuxClaudeSessionPresentation.dotColor(for: .working) == .teal)
        #expect(SupermuxClaudeSessionPresentation.dotColor(for: .finishedUnopened) == .blue)
        #expect(SupermuxClaudeSessionPresentation.dotColor(for: .failed) == .red)
    }

    @Test func everyIndicatorHasAVoiceOverLabel() {
        let indicators: [SupermuxClaudeSessionIndicator] = [
            .working, .idle, .finishedUnopened, .finished, .failed,
        ]
        let labels = indicators.map(SupermuxClaudeSessionPresentation.dotAccessibilityLabel(for:))
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(Set(labels).count == labels.count, "each state needs a distinct label")
    }

    /// The default launcher is not named on every row (that would be noise);
    /// anything else is, because it changes what is actually running.
    @Test func subtitleNamesOnlyNonDefaultLaunchers() {
        #expect(SupermuxClaudeSessionPresentation.launcherLabel(.claude) == nil)
        #expect(SupermuxClaudeSessionPresentation.launcherLabel(.ccx) == "ccx")
        #expect(
            SupermuxClaudeSessionPresentation.launcherLabel(.custom(path: "/opt/bin/mine"))
                == "mine"
        )

        let subtitle = SupermuxClaudeSessionPresentation.subtitle(
            for: session(model: "opus", launcher: .ccx, queued: 2)
        )
        #expect(subtitle.contains("opus"))
        #expect(subtitle.contains("ccx"))
        #expect(subtitle.contains("2"))
    }

    @Test func costShowsOnlyAfterATurnCompletes() {
        #expect(
            SupermuxClaudeSessionPresentation
                .costLabel(SupermuxClaudeCostDTO(totalUSD: 0, turns: 0, durationMS: 0)) == nil
        )
        #expect(
            SupermuxClaudeSessionPresentation
                .costLabel(SupermuxClaudeCostDTO(totalUSD: 1.5, turns: 2, durationMS: 10))
                == "$1.50"
        )
    }

    // MARK: Transcript projection

    private func message(
        id: String,
        kind: SupermuxClaudeChatMessageKind,
        role: SupermuxClaudeChatRole = .assistant,
        text: String? = nil,
        tool: SupermuxClaudeToolDTO? = nil
    ) -> SupermuxClaudeChatMessageDTO {
        SupermuxClaudeChatMessageDTO(
            id: id,
            seq: 1,
            role: role,
            timestamp: 1,
            kind: kind,
            text: text,
            tool: tool
        )
    }

    @Test func eachMessageKindProjectsToItsRow() {
        let tool = SupermuxClaudeToolDTO(
            toolUseID: "t1",
            name: "Bash",
            title: "Ran command",
            isComplete: true
        )
        let rows = SupermuxClaudeTranscriptPresentation.rows(for: [
            message(id: "u", kind: .prose, role: .user, text: "hi"),
            message(id: "a", kind: .prose, text: "hello"),
            message(id: "t", kind: .thought, text: "hmm"),
            message(id: "tool", kind: .tool, tool: tool),
            message(id: "s", kind: .status, text: "resumed"),
        ])
        #expect(rows.map(\.id) == ["u", "a", "t", "tool", "s"])
        #expect(rows[0].content == .userPrompt("hi"))
        #expect(rows[1].content == .assistantProse("hello"))
        #expect(rows[2].content == .thinking("hmm"))
        #expect(rows[3].content == .tool(tool))
        #expect(rows[4].content == .status("resumed"))
    }

    /// A streaming prose message exists before its first delta lands, and
    /// rendering an empty bubble for it would make rows flicker in and out.
    @Test func emptyAndWhitespaceOnlyMessagesDrawNothing() {
        let rows = SupermuxClaudeTranscriptPresentation.rows(for: [
            message(id: "empty", kind: .prose, text: ""),
            message(id: "blank", kind: .prose, text: "   \n "),
            message(id: "nil", kind: .prose, text: nil),
            message(id: "toolless", kind: .tool, tool: nil),
        ])
        #expect(rows.isEmpty)
    }

    /// Forward compatibility: a kind this build cannot place still shows its
    /// CONTENT, just unstyled — silently dropping a turn would be worse.
    @Test func anUnknownKindFallsBackToVisibleText() {
        let rows = SupermuxClaudeTranscriptPresentation.rows(for: [
            message(id: "future", kind: .unknown("chart"), text: "payload"),
        ])
        #expect(rows.map(\.content) == [.status("payload")])
    }

    @Test func toolTitlesPreferTheMacsHumanizedLabel() {
        let humanized = SupermuxClaudeToolDTO(
            toolUseID: "t",
            name: "Bash",
            title: "Running command",
            isComplete: false
        )
        #expect(SupermuxClaudeTranscriptPresentation.toolTitle(humanized) == "Running command")
        // An older Mac may send an empty title; the protocol name is readable
        // enough to be the fallback.
        let bare = SupermuxClaudeToolDTO(toolUseID: "t", name: "Bash", title: "  ", isComplete: true)
        #expect(SupermuxClaudeTranscriptPresentation.toolTitle(bare) == "Bash")
    }

    @Test func onlyCompletedToolsOfferTheirFullPayload() {
        func tool(complete: Bool, output: String?) -> SupermuxClaudeToolDTO {
            SupermuxClaudeToolDTO(
                toolUseID: "t",
                name: "Bash",
                title: "Ran command",
                outputSummary: output,
                isComplete: complete
            )
        }
        // A running tool's summary is still growing and the Mac has no final
        // payload to serve yet.
        #expect(!SupermuxClaudeTranscriptPresentation.offersFullPayload(
            tool(complete: false, output: "partial")
        ))
        #expect(!SupermuxClaudeTranscriptPresentation.offersFullPayload(
            tool(complete: true, output: nil)
        ))
        #expect(SupermuxClaudeTranscriptPresentation.offersFullPayload(
            tool(complete: true, output: "done")
        ))
    }

    @Test func onlyACompletedErrorReadsAsFailed() {
        func tool(complete: Bool, isError: Bool?) -> SupermuxClaudeToolDTO {
            SupermuxClaudeToolDTO(
                toolUseID: "t",
                name: "Bash",
                title: "Ran command",
                isError: isError,
                isComplete: complete
            )
        }
        #expect(SupermuxClaudeTranscriptPresentation.isFailed(tool(complete: true, isError: true)))
        #expect(!SupermuxClaudeTranscriptPresentation.isFailed(tool(complete: false, isError: true)))
        #expect(!SupermuxClaudeTranscriptPresentation.isFailed(tool(complete: true, isError: nil)))
    }

    // MARK: TodoWrite

    private func todoTool(_ json: String) -> SupermuxClaudeToolDTO {
        SupermuxClaudeToolDTO(
            toolUseID: "todo",
            name: "TodoWrite",
            title: "Updated to-dos",
            inputSummary: json,
            isComplete: true
        )
    }

    @Test func todosParseWithStatusesAndProgress() {
        let todos = SupermuxClaudeTodoPresentation.todos(in: todoTool(#"""
        {"todos":[
          {"content":"Write it","status":"completed"},
          {"content":"Test it","status":"in_progress"},
          {"content":"Ship it","status":"pending"}
        ]}
        """#))
        #expect(todos.map(\.title) == ["Write it", "Test it", "Ship it"])
        #expect(todos.map(\.status) == [.completed, .inProgress, .pending])
        #expect(SupermuxClaudeTodoPresentation.progress(todos) == 1.0 / 3.0)
    }

    /// A payload shape this build does not recognize must degrade to "render
    /// as an ordinary tool card", never to a transcript that refuses to draw.
    @Test func unparseableTodoPayloadsYieldNoRows() {
        #expect(SupermuxClaudeTodoPresentation.todos(in: todoTool("not json")).isEmpty)
        #expect(SupermuxClaudeTodoPresentation.todos(in: todoTool(#"{"other":[]}"#)).isEmpty)
        let notATodoList = SupermuxClaudeToolDTO(
            toolUseID: "t",
            name: "Bash",
            title: "Ran command",
            inputSummary: #"{"todos":[{"content":"x","status":"pending"}]}"#,
            isComplete: true
        )
        #expect(SupermuxClaudeTodoPresentation.todos(in: notATodoList).isEmpty)
    }

    @Test func anEmptyTodoListHasZeroProgressRatherThanDividingByZero() {
        #expect(SupermuxClaudeTodoPresentation.progress([]) == 0)
    }

    @Test func unknownTodoStatusesFallBackToPending() {
        let todos = SupermuxClaudeTodoPresentation.todos(
            in: todoTool(#"{"todos":[{"content":"x","status":"blocked"}]}"#)
        )
        #expect(todos.map(\.status) == [.pending])
    }

    // MARK: Composer

    @Test func sendIsGatedOnRealContentAndNoInFlightSend() {
        #expect(SupermuxClaudeComposerPresentation.canSend(draft: "hi", isSending: false))
        // Whitespace-only would consume a real turn.
        #expect(!SupermuxClaudeComposerPresentation.canSend(draft: "   \n", isSending: false))
        #expect(!SupermuxClaudeComposerPresentation.canSend(draft: "", isSending: false))
        #expect(!SupermuxClaudeComposerPresentation.canSend(draft: "hi", isSending: true))
    }

    /// Stop only takes the primary slot when there is nothing to send, so a
    /// tap aimed at Send during a turn still queues Mac-side.
    @Test func stopOnlyTakesTheButtonWhenTheDraftIsEmpty() {
        #expect(SupermuxClaudeComposerPresentation.showsStop(isWorking: true, draft: ""))
        #expect(!SupermuxClaudeComposerPresentation.showsStop(isWorking: true, draft: "queue me"))
        #expect(!SupermuxClaudeComposerPresentation.showsStop(isWorking: false, draft: ""))
    }

    @Test func slashAutocompleteMatchesPrefixesAndNormalizesSlashes() {
        let commands = ["/compact", "clear", "cost", "review"]
        #expect(
            SupermuxClaudeComposerPresentation.slashSuggestions(draft: "/c", commands: commands)
                == ["/clear", "/compact", "/cost"]
        )
        #expect(
            SupermuxClaudeComposerPresentation.slashSuggestions(draft: "/", commands: commands)
                == ["/clear", "/compact", "/cost", "/review"]
        )
    }

    /// Once the command has arguments the list would cover the text being
    /// written, so it hides.
    @Test func slashAutocompleteHidesOnceTheCommandHasArguments() {
        let commands = ["compact"]
        #expect(
            SupermuxClaudeComposerPresentation
                .slashSuggestions(draft: "/compact now", commands: commands).isEmpty
        )
        #expect(
            SupermuxClaudeComposerPresentation
                .slashSuggestions(draft: "hello", commands: commands).isEmpty
        )
        #expect(
            SupermuxClaudeComposerPresentation
                .slashSuggestions(draft: "/zzz", commands: commands).isEmpty
        )
    }

    @Test func acceptingACommandLeavesRoomForArguments() {
        #expect(SupermuxClaudeComposerPresentation.accept(command: "/compact") == "/compact ")
    }

    // MARK: New-session validation

    /// The Mac resolves the path verbatim, so a relative one would silently
    /// land wherever the host process happens to be.
    @Test func startRequiresAnAbsoluteDirectory() {
        #expect(SupermuxClaudeNewSessionValidation.canStart(
            cwd: "/repo",
            launcher: .claude,
            isCreating: false
        ))
        #expect(!SupermuxClaudeNewSessionValidation.canStart(
            cwd: "repo",
            launcher: .claude,
            isCreating: false
        ))
        #expect(!SupermuxClaudeNewSessionValidation.canStart(
            cwd: "",
            launcher: .claude,
            isCreating: false
        ))
        #expect(!SupermuxClaudeNewSessionValidation.canStart(
            cwd: "/repo",
            launcher: .claude,
            isCreating: true
        ))
    }

    /// "Never silently fall back to plain claude" means a half-typed custom
    /// path cannot start a session.
    @Test func aCustomLauncherNeedsAnAbsolutePathToo() {
        #expect(!SupermuxClaudeNewSessionValidation.canStart(
            cwd: "/repo",
            launcher: .custom(path: ""),
            isCreating: false
        ))
        #expect(!SupermuxClaudeNewSessionValidation.canStart(
            cwd: "/repo",
            launcher: .custom(path: "ccx"),
            isCreating: false
        ))
        #expect(SupermuxClaudeNewSessionValidation.canStart(
            cwd: "/repo",
            launcher: .custom(path: "/opt/bin/ccx"),
            isCreating: false
        ))
    }

    // MARK: Runtime labels

    private var options: SupermuxClaudeOptionsDTO {
        SupermuxClaudeOptionsDTO(
            models: [
                SupermuxClaudeModelOptionDTO(
                    value: "opus",
                    displayName: "Opus",
                    supportedEffortLevels: ["low", "medium", "high"],
                    supportsFastMode: true
                ),
                SupermuxClaudeModelOptionDTO(value: "haiku", displayName: "Haiku"),
            ],
            supportedEffortLevels: ["medium"],
            supportsFastMode: false,
            slashCommands: [],
            launchers: []
        )
    }

    @Test func modelTitlesPreferTheDisplayNameAndDegradeGracefully() {
        #expect(SupermuxClaudeRuntimeLabels.modelTitle("opus", options: options) == "Opus")
        // Unknown to the catalog: the raw value is still the truth.
        #expect(SupermuxClaudeRuntimeLabels.modelTitle("sonnet", options: options) == "sonnet")
        #expect(!SupermuxClaudeRuntimeLabels.modelTitle(nil, options: options).isEmpty)
    }

    /// A model with its own effort list wins; otherwise the Mac's union keeps
    /// the slider usable instead of vanishing.
    @Test func effortLevelsFallBackToTheHostUnion() {
        #expect(
            SupermuxClaudeRuntimeLabels.effortLevels(for: "opus", options: options)
                == ["low", "medium", "high"]
        )
        #expect(
            SupermuxClaudeRuntimeLabels.effortLevels(for: "haiku", options: options) == ["medium"]
        )
        #expect(SupermuxClaudeRuntimeLabels.effortLevels(for: "opus", options: nil).isEmpty)
    }

    @Test func fastModeFollowsTheSelectedModel() {
        #expect(SupermuxClaudeRuntimeLabels.supportsFastMode(model: "opus", options: options))
        #expect(!SupermuxClaudeRuntimeLabels.supportsFastMode(model: "haiku", options: options))
        #expect(!SupermuxClaudeRuntimeLabels.supportsFastMode(model: "opus", options: nil))
    }
}

import CmuxAgentJournal
import Foundation

// Supermux-owned (SUPERMUX-TOUCHPOINTS.md, `claude-answer-hook`).
extension CMUXCLI {
    /// The Claude Code tools whose result is the user's answer: a question
    /// (`AskUserQuestion`) or a plan approval (`ExitPlanMode`). Claude Code runs
    /// their PostToolUse as soon as the user answers in the terminal.
    static let supermuxClaudeAnsweredToolMatcher = "AskUserQuestion|ExitPlanMode"

    /// `claude-hook post-tool-use`: the user answered the prompt the tool
    /// raised, so the agent works again.
    ///
    /// The tool's PreToolUse put the pane in needs input and opened a request
    /// keyed by its `tool_use_id`; Claude Code's PermissionRequest hook opened
    /// a Feed request beside it. An answer typed in the terminal fires no hook
    /// of its own, and while a request is open a later tool's running state is
    /// held at needs input, so the pane kept "needs input" until the turn
    /// ended. This hook resolves the tool's request the way a Feed reply does,
    /// sends a stamped PostToolUse to Feed (which retires its abandoned
    /// request) and puts the agent's pill back to Running.
    func runSupermuxClaudeAnswerHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        markFeedTelemetryHandled: () -> Void,
        sendFeedTelemetry: (String?, String?) -> Void
    ) throws {
        telemetry.breadcrumb("claude-hook.post-tool-use")
        let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
        guard let resolvedTarget = try resolveClaudeHookDeliveryTarget(
            mappedSession: mappedSession,
            routing: routing,
            client: client
        ), resolvedTarget.isAuthoritative else {
            markFeedTelemetryHandled()
            telemetry.breadcrumb("claude-hook.post-tool-use.unresolved")
            printClaudeHookAck()
            return
        }
        let workspaceId = resolvedTarget.workspaceId
        let surfaceId = resolvedTarget.surfaceId
        let env = ProcessInfo.processInfo.environment
        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ), !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("claude-hook.post-tool-use.skipped")
            sendFeedTelemetry(workspaceId, surfaceId)
            printClaudeHookAck()
            return
        }
        emitAgentJournalEvent(
            client: client,
            kind: .attentionResolved,
            source: "claude",
            agentKey: Self.claudeCodeStatusKey,
            sessionId: parsedInput.sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            nativeEvent: reportedHookEventName(from: parsedInput) ?? "PostToolUse",
            declaredPhase: .running,
            attention: Self.semanticAttentionContext(parsedInput.rawObject),
            occurredAtMs: Self.semanticOccurredAtMs(parsedInput.rawObject),
            store: sessionStore,
            telemetry: telemetry
        )
        // Only after the journal acknowledged the resolution above: Feed's own
        // resolution of its request then commits and reduces after it. Sent
        // first, Feed's could commit later yet reduce earlier, and the
        // lifecycle fold drops the older-sequence projection that ends the wait.
        sendFeedTelemetry(workspaceId, surfaceId)
        if let sessionId = parsedInput.sessionId {
            _ = try? sessionStore.upsert(
                sessionId: sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                cwd: parsedInput.cwd,
                transcriptPath: parsedInput.transcriptPath,
                agentLifecycle: .running,
                hookEventName: reportedHookEventName(from: parsedInput) ?? "PostToolUse",
                // The answered question's text must not resurface as a later
                // notification's body, as after the next tool's PreToolUse.
                updateLastSummary: true
            )
        }
        try setClaudeStatus(
            client: client,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            value: String(localized: "agent.generic.status.running", defaultValue: "Running"),
            icon: "bolt.fill",
            color: "#4C8DFF",
            pid: claudePid,
            workState: .running
        )
        printClaudeHookAck()
    }
}

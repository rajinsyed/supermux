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
    /// The tool's PreToolUse put the pane in needs input. The wait it left
    /// open in the agent journal depends on the mode: in bypass mode a
    /// request keyed by the tool's `tool_use_id`, beside it the Feed request
    /// Claude Code's PermissionRequest hook raised, and otherwise that Feed
    /// request or, when Feed's notification was not admitted, the permission
    /// prompt notification's request with no identity. An answer typed in the
    /// terminal fires no hook of its own, and while a request is open a later
    /// tool's running state is held at needs input, so the pane kept "needs
    /// input" until the turn ended. This hook answers the tool's own request
    /// and then the one request left open, as a Feed reply does (Feed's
    /// stamped PostToolUse retires its own request too), and puts the agent's
    /// pill back to Running.
    func runSupermuxClaudeAnswerHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        routing: ClaudeHookRoutingContext,
        localClaudePID: (ClaudeHookSessionRecord?) -> Int?,
        liveClaudePID: (ClaudeHookSessionRecord?) -> Int?,
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
        // As pre-tool-use: a queued replay walks no process tree, since the
        // hook's PID may already be recycled.
        let isNestedAgentSession = nestedAgentSessionDetected(
            currentAgentPID: liveClaudePID(mappedSession),
            env: env
        )
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ), !shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: liveClaudePID(mappedSession),
            precomputedNestedDetection: isNestedAgentSession,
            env: env
        ) else {
            telemetry.breadcrumb("claude-hook.post-tool-use.skipped")
            sendFeedTelemetry(workspaceId, surfaceId)
            printClaudeHookAck()
            return
        }
        let answeredRequest = Self.semanticAttentionContext(parsedInput.rawObject)
        // The tool's own request, then the one request left open.
        for attention in [answeredRequest, AgentAttentionContext(turnIdentity: answeredRequest.turnIdentity)] {
            emitAgentJournalEvent(
                client: client,
                kind: .attentionResolved,
                source: "claude",
                agentKey: Self.claudeCodeStatusKey,
                sessionId: parsedInput.sessionId,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                isSubagent: isNestedAgentSession,
                pendingWork: true,
                nativeEvent: reportedHookEventName(from: parsedInput) ?? "PostToolUse",
                declaredPhase: .running,
                attention: attention,
                occurredAtMs: Self.semanticOccurredAtMs(parsedInput.rawObject),
                store: sessionStore,
                telemetry: telemetry
            )
        }
        // Only after the journal acknowledged the resolutions above: Feed's
        // own resolution of its request then commits and reduces after them.
        // Sent first, Feed's could commit later yet reduce earlier, and the
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
            pid: localClaudePID(mappedSession),
            workState: .running
        )
        printClaudeHookAck()
    }
}

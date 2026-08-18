/**
 * Three keys were retired in round 3 after the reachability test below caught
 * them rendering nowhere: `app.title` (the document title is baked into the
 * build's `<head>`, not read at runtime), `turn.complete` and
 * `permission.needed` (the native notification path uses its OWN
 * `supermux.harness.notification.*` keys, and `permission.needed` was a
 * verbatim duplicate of `permission.title`). A dead key is not free — it reaches
 * translators through the extract → merge pipeline and is paid for in every
 * language while appearing in none. Their SupermuxHarnessCopy.swift and
 * Localizable.xcstrings rows should go with them.
 *
 * Round 4 retires five more with the inline WorkflowCard the browser replaces:
 * `workflow.showResult` / `workflow.hideResult` (the per-agent result
 * disclosure — the browser's Outcome section is a heading and an Expand, not a
 * show/hide toggle), `workflow.openAgent` (superseded by
 * `workflow.browser.openTranscript`, which opens the agent's CHAT rather than
 * an inline drill-in), and `workflow.collapse` / `workflow.expand` (the card's
 * head fold; a full view has a back affordance instead). Same removal applies
 * to their Swift and xcstrings rows.
 */
export const copyDefaults = {
  "supermux.harness.app.untitledSession": "New session",

  "supermux.harness.empty.headline": "Claude Code, in your workspace",
  "supermux.harness.empty.subhead": "Ask a question, describe a change, or paste an error.",
  "supermux.harness.empty.workingIn": "Working in",
  "supermux.harness.empty.recentSessions": "Recent sessions",
  "supermux.harness.empty.suggestionsTitle": "Try one of these",
  "supermux.harness.empty.suggestion1": "Explain how this project is structured",
  "supermux.harness.empty.suggestion2": "Find and fix the failing test",
  "supermux.harness.empty.suggestion3": "Review my uncommitted changes",
  "supermux.harness.empty.detectingModel": "Detecting model…",

  "supermux.harness.nocli.headline": "Claude Code CLI not found",
  "supermux.harness.nocli.body":
    "This pane drives the Claude Code command-line tool. Install it, then retry.",
  "supermux.harness.nocli.install": "npm install -g @anthropic-ai/claude-code",
  "supermux.harness.nocli.retry": "Retry detection",
  "supermux.harness.nocli.docs": "Installation guide",
  "supermux.harness.nocli.searchedPath": "Searched PATH and common version-manager directories.",
  "supermux.harness.nocli.setBinary": "Point at a binary…",

  "supermux.harness.exited.headline": "Session ended",
  "supermux.harness.exited.body": "The Claude process exited. Your transcript is preserved.",
  "supermux.harness.exited.restart": "Start a new session",

  "supermux.harness.composer.placeholder": "Message Claude…",
  "supermux.harness.composer.placeholderRunning": "Send a follow-up — it will be queued",
  "supermux.harness.composer.placeholderWaiting": "Respond to the request above",
  "supermux.harness.composer.placeholderPlan": "Approve the plan, or say what to change",
  "supermux.harness.composer.placeholderNoCli": "Install the Claude Code CLI to start",
  // A restart disables the composer for a second or two, and the no-CLI copy —
  // the only other reason it is ever disabled — told the user to install
  // software they plainly already have.
  "supermux.harness.composer.placeholderRestarting": "Restarting Claude…",
  "supermux.harness.composer.send": "Send",
  "supermux.harness.composer.stop": "Stop",
  "supermux.harness.composer.hintSend": "Enter to send",
  "supermux.harness.composer.hintNewline": "Shift+Enter for a new line",
  "supermux.harness.composer.hintInterrupt": "Esc to interrupt",
  "supermux.harness.composer.hintMode": "Shift+Tab cycles permission mode",
  "supermux.harness.composer.attach": "Attach files",
  "supermux.harness.composer.removeAttachment": "Remove attachment",
  "supermux.harness.composer.queued": "Queued",
  "supermux.harness.composer.cancelQueued": "Cancel queued message",
  "supermux.harness.composer.mentionTitle": "Files",
  "supermux.harness.composer.mentionEmpty": "No matching files",
  "supermux.harness.composer.commandTitle": "Commands",
  "supermux.harness.composer.commandEmpty": "No matching commands",
  "supermux.harness.composer.approxTokens": "~{count} tokens",

  "supermux.harness.status.idle": "Ready",
  "supermux.harness.status.thinking": "Claude is thinking…",
  "supermux.harness.status.thinkingTokens": "Thinking · {tokens} tokens",
  "supermux.harness.status.running": "Running {tool}",
  "supermux.harness.status.waitingApproval": "Waiting for your approval",
  "supermux.harness.status.compacting": "Compacting conversation…",
  "supermux.harness.status.retrying": "Retrying in {seconds}s · attempt {attempt} of {max}",
  "supermux.harness.status.starting": "Starting Claude…",
  "supermux.harness.status.restarting": "Restarting Claude…",
  "supermux.harness.status.queuedOne": "{count} message queued",
  "supermux.harness.status.queued": "{count} messages queued",
  "supermux.harness.status.exited": "Process exited",
  "supermux.harness.status.noCli": "Claude Code CLI not found",
  "supermux.harness.status.restart": "Restart",
  "supermux.harness.status.workingFor": "Working for {duration}",
  "supermux.harness.status.jumpToLatest": "Jump to latest",

  "supermux.harness.turn.workedFor": "Worked for {duration}",
  "supermux.harness.turn.stoppedAfter": "You stopped after {duration}",
  "supermux.harness.turn.failedAfter": "Failed after {duration}",
  "supermux.harness.turn.showFullMessage": "Show full message",
  "supermux.harness.turn.showLess": "Show less",
  "supermux.harness.turn.interrupted": "Interrupted",
  "supermux.harness.turn.previousToolCallsOne": "{count} earlier tool call",
  "supermux.harness.turn.previousToolCalls": "{count} earlier tool calls",
  "supermux.harness.turn.earlierMessagesOne": "{count} earlier message",
  "supermux.harness.turn.earlierMessages": "{count} earlier messages",
  "supermux.harness.turn.turnNumber": "Turn {seq}",
  "supermux.harness.turn.exportTitle": "Claude session",

  "supermux.harness.thinking.label": "Thinking",
  "supermux.harness.thinking.summary": "Thinking · {tokens} tokens · {duration}",
  "supermux.harness.thinking.summaryNoTokens": "Thinking · {duration}",
  "supermux.harness.thinking.redacted": "Reasoning is not shown for this account.",

  "supermux.harness.tool.running": "Running",
  "supermux.harness.tool.succeeded": "Done",
  "supermux.harness.tool.failed": "Failed",
  "supermux.harness.tool.denied": "Denied",
  "supermux.harness.tool.aborted": "Interrupted",
  "supermux.harness.tool.pending": "Preparing",
  "supermux.harness.tool.noOutput": "No output",
  "supermux.harness.tool.showMoreOne": "Show {count} more line",
  "supermux.harness.tool.showMore": "Show {count} more lines",
  "supermux.harness.tool.showLess": "Collapse output",
  "supermux.harness.tool.copy": "Copy",
  "supermux.harness.tool.copied": "Copied",
  "supermux.harness.tool.copyFailed": "Copy failed",
  "supermux.harness.tool.wrap": "Wrap lines",
  "supermux.harness.tool.openFile": "Open file",
  "supermux.harness.tool.exitCode": "exit {code}",
  "supermux.harness.tool.linesAdded": "+{count}",
  "supermux.harness.tool.linesRemoved": "−{count}",
  "supermux.harness.tool.filesFoundOne": "{count} file",
  "supermux.harness.tool.filesFound": "{count} files",
  "supermux.harness.tool.matchesFoundOne": "{count} match",
  "supermux.harness.tool.matchesFound": "{count} matches",
  "supermux.harness.tool.toolsSearchedOne": "{count} tool searched",
  "supermux.harness.tool.toolsSearched": "{count} tools searched",
  "supermux.harness.tool.linesReadOne": "{count} line",
  "supermux.harness.tool.linesRead": "{count} lines",
  "supermux.harness.tool.created": "Created",
  "supermux.harness.tool.updated": "Updated",
  "supermux.harness.tool.searchResultsOne": "{count} result",
  "supermux.harness.tool.searchResults": "{count} results",
  "supermux.harness.tool.mcpServer": "MCP · {server}",
  "supermux.harness.tool.rawInput": "Input",
  "supermux.harness.tool.rawOutput": "Output",
  "supermux.harness.tool.durationMs": "{count}ms",
  "supermux.harness.tool.webResult": "Result",

  "supermux.harness.subagent.badge": "Subagent",
  "supermux.harness.subagent.background": "Background",
  "supermux.harness.subagent.tokens": "{tokens} tokens",
  "supermux.harness.subagent.toolUsesOne": "{count} tool",
  "supermux.harness.subagent.toolUses": "{count} tools",
  // Retired in round 4 with the inline expandable subagent card: there is no
  // "show/hide subagent work" toggle any more, because the agent's work is not
  // rendered inline at all — the transcript keeps a one-line row and the
  // conversation is a view. `subagent.shownAbove` went with them: it existed
  // only to mark the duplicate an inline drill-in produced, and nothing draws
  // one agent twice now.
  "supermux.harness.subagent.transcriptLoading": "Reading the agent's transcript…",
  "supermux.harness.subagent.transcriptMissing":
    "No transcript on disk yet — it appears once the agent writes its first message.",
  "supermux.harness.subagent.transcriptEmpty": "The agent has not recorded anything yet.",
  "supermux.harness.subagent.transcriptFailed": "Could not read the agent's transcript.",
  "supermux.harness.subagent.transcriptTruncated": "Only the most recent messages are shown.",
  "supermux.harness.subagent.transcriptRefresh": "Refresh",
  "supermux.harness.subagent.filesReadOne": "read {count} file",
  "supermux.harness.subagent.filesRead": "read {count} files",
  "supermux.harness.subagent.filesEditedOne": "edited {count} file",
  "supermux.harness.subagent.filesEdited": "edited {count} files",
  "supermux.harness.subagent.searchesOne": "{count} search",
  "supermux.harness.subagent.searches": "{count} searches",
  "supermux.harness.subagent.commandsOne": "{count} command",
  "supermux.harness.subagent.commands": "{count} commands",
  "supermux.harness.subagent.lineDelta": "+{added} −{removed}",
  "supermux.harness.subagent.spawnDepth": "Depth {depth}",
  "supermux.harness.subagent.fromDisk": "Agent transcript",
  "supermux.harness.subagent.waiting": "Waiting to start…",
  "supermux.harness.subagent.nestedOne": "{count} nested agent",
  "supermux.harness.subagent.nested": "{count} nested agents",

  "supermux.harness.workflow.badge": "Workflow",
  "supermux.harness.workflow.untitled": "Workflow",
  "supermux.harness.workflow.starting": "Starting the workflow…",
  "supermux.harness.workflow.phasesOne": "{count} phase",
  "supermux.harness.workflow.phases": "{count} phases",
  "supermux.harness.workflow.agentsOne": "{count} agent",
  "supermux.harness.workflow.agents": "{count} agents",
  "supermux.harness.workflow.phasePending": "Not started",
  "supermux.harness.workflow.progress": "{done} of {total} done",
  "supermux.harness.workflow.stop": "Stop workflow",
  "supermux.harness.workflow.stopping": "Stopping…",
  "supermux.harness.workflow.stopped": "Stopped",
  "supermux.harness.workflow.stoppedAfter": "Stopped after {duration}",
  "supermux.harness.workflow.agentsFinishedOne": "{done} of {total} agent finished",
  "supermux.harness.workflow.agentsFinished": "{done} of {total} agents finished",
  "supermux.harness.workflow.stopFailed": "Could not stop the workflow.",
  "supermux.harness.workflow.state.queued": "Queued",
  "supermux.harness.workflow.state.running": "Running",
  "supermux.harness.workflow.state.done": "Done",
  "supermux.harness.workflow.state.error": "Failed",
  "supermux.harness.workflow.state.blocked": "Blocked",
  "supermux.harness.workflow.state.cached": "Cached",
  "supermux.harness.workflow.attempt": "Attempt {count}",
  "supermux.harness.workflow.isolationWorktree": "Worktree",
  "supermux.harness.workflow.isolationRemote": "Remote",
  "supermux.harness.workflow.showLogsOne": "{count} log line",
  "supermux.harness.workflow.showLogs": "{count} log lines",
  "supermux.harness.workflow.hideLogs": "Hide log",
  "supermux.harness.workflow.noAgents": "No agents have been scheduled yet.",
  "supermux.harness.workflow.unphased": "Unphased",
  "supermux.harness.workflow.viewAgents": "Pick an agent to open its transcript:",

  // --- Round 4: the multi-pane workflow browser ---
  // The transcript keeps a one-line row; the run itself is browsed in a full
  // view with a phases column, a phase agent list, and an agent detail pane.
  "supermux.harness.workflow.browser.title": "Workflow",
  "supermux.harness.workflow.browser.open": "Open",
  "supermux.harness.workflow.browser.back": "Back",
  "supermux.harness.workflow.browser.phases": "Phases",
  "supermux.harness.workflow.browser.agentCount": "{done}/{total} agents",
  "supermux.harness.workflow.browser.prompt": "Prompt",
  "supermux.harness.workflow.browser.activity": "Activity",
  "supermux.harness.workflow.browser.outcome": "Outcome",
  "supermux.harness.workflow.browser.noActivity": "No tool activity reported.",
  "supermux.harness.workflow.browser.expand": "Expand",
  "supermux.harness.workflow.browser.collapse": "Collapse",
  "supermux.harness.workflow.browser.loadingFull": "Reading the agent's transcript…",
  "supermux.harness.workflow.browser.fullMissing":
    "The agent's transcript is not on disk yet — only the preview is available.",
  "supermux.harness.workflow.browser.fullFailed": "Could not read the agent's transcript.",
  "supermux.harness.workflow.browser.retry": "Retry",
  "supermux.harness.workflow.browser.truncated": "Only the most recent messages are shown.",
  "supermux.harness.workflow.browser.openTranscript": "Open full transcript",
  "supermux.harness.workflow.browser.cachedBadge": "Cached",
  "supermux.harness.workflow.browser.toolCallsOne": "{count} tool call",
  "supermux.harness.workflow.browser.toolCalls": "{count} tool calls",
  // The footer hint bar. These are REAL bindings on the browser, not decoration:
  // ↑↓ move the selection, x stops the run, esc steps back out.
  "supermux.harness.workflow.browser.hintSelect": "select",
  "supermux.harness.workflow.browser.hintBack": "back",
  // The routed view outlived its task: the process restarted, or the
  // conversation was rewound past the turn that launched the run.
  "supermux.harness.workflow.browser.gone": "This workflow is no longer available.",

  // --- Round 4: the agents dock, above the composer ---
  "supermux.harness.dock.title": "Agents",
  "supermux.harness.dock.main": "Claude",
  "supermux.harness.dock.mainHint": "Main conversation",
  "supermux.harness.dock.collapse": "Hide agents",
  "supermux.harness.dock.expand": "Show agents",
  "supermux.harness.dock.countOne": "{count} agent",
  "supermux.harness.dock.count": "{count} agents",
  "supermux.harness.dock.open": "Open",
  "supermux.harness.dock.stop": "Stop",
  "supermux.harness.dock.stopping": "Stopping…",
  "supermux.harness.dock.stopFailed": "Could not stop this task.",
  "supermux.harness.dock.untitledAgent": "Agent",
  "supermux.harness.dock.untitledShell": "Shell",
  "supermux.harness.dock.untitledWorkflow": "Workflow",
  "supermux.harness.dock.statusRunning": "Running",
  "supermux.harness.dock.statusDone": "Done",
  "supermux.harness.dock.statusFailed": "Failed",
  "supermux.harness.dock.statusStopped": "Stopped",
  "supermux.harness.dock.statusIdle": "Idle",
  "supermux.harness.dock.workflowAgents": "{done}/{total} agents",
  "supermux.harness.dock.a11y": "Agents and background tasks",
  "supermux.harness.dock.keyHint": "↑↓ select · ⏎ open · esc back",

  // --- Round 4: full-chat agent views ---
  "supermux.harness.view.back": "Back",
  "supermux.harness.view.backTo": "Back to {label}",
  "supermux.harness.view.rootCrumb": "Claude",
  "supermux.harness.agentView.prompt": "Prompt",
  "supermux.harness.agentView.empty": "This agent has not said anything yet.",
  "supermux.harness.agentView.loading": "Loading this agent's conversation…",
  "supermux.harness.agentView.unavailable":
    "No transcript for this agent yet — it appears once the agent writes its first message.",
  "supermux.harness.agentView.failed": "Could not load this agent's conversation.",
  "supermux.harness.agentView.retry": "Try again",
  "supermux.harness.agentView.fromDisk": "Loaded from this agent's transcript on disk.",
  "supermux.harness.agentView.childAgents": "Agents this one started",
  "supermux.harness.agentView.openChild": "Open agent",
  // The composer inside an agent view sends TO the agent, which is a different
  // act from messaging Claude and must not wear the same placeholder.
  "supermux.harness.agentView.composerPlaceholder": "Message {agent}…",
  "supermux.harness.agentView.composerPlaceholderDone":
    "This agent has finished — messages go to Claude instead",
  "supermux.harness.agentView.relayHint":
    "Delivered through Claude at the agent's next tool call.",
  "supermux.harness.agentView.relaySending": "Sending…",
  "supermux.harness.agentView.relayRelayed": "Passed to the agent",
  "supermux.harness.agentView.relayDelivered": "Received by the agent",
  "supermux.harness.agentView.relayFailed": "Could not reach this agent.",
  // Honest about the one delivery case the wire cannot promise: main is blocked
  // on the agent's own foreground Task and could not be freed.
  "supermux.harness.agentView.relayQueuedForeground":
    "Claude is waiting on this agent, so the message arrives when it finishes.",
  "supermux.harness.relay.chip": "Sent to {agent}",
  "supermux.harness.relay.chipUnknown": "Sent to an agent",
  "supermux.harness.relay.ack": "Relayed",

  "supermux.harness.tasks.title": "Background tasks",
  "supermux.harness.tasks.countOne": "{count} task",
  "supermux.harness.tasks.count": "{count} tasks",
  "supermux.harness.tasks.collapse": "Hide background tasks",
  "supermux.harness.tasks.expand": "Show background tasks",
  "supermux.harness.tasks.typeShell": "Shell",
  "supermux.harness.tasks.typeAgent": "Agent",
  "supermux.harness.tasks.typeWorkflow": "Workflow",
  // The SDK's task_type set is extensible; an unrecognised value gets a neutral
  // label rather than being asserted to be a shell.
  "supermux.harness.tasks.typeTask": "Task",
  "supermux.harness.tasks.statusDone": "Done",
  "supermux.harness.tasks.statusFailed": "Failed",
  "supermux.harness.tasks.statusStopped": "Stopped",
  "supermux.harness.tasks.statusSettled": "Settled",
  "supermux.harness.tasks.moreBelow": "{count} more below",
  "supermux.harness.tasks.untitled": "Background task",
  "supermux.harness.tasks.stop": "Stop",
  "supermux.harness.tasks.stopping": "Stopping…",
  "supermux.harness.tasks.stopFailed": "Could not stop this task.",
  "supermux.harness.tasks.view": "View",
  "supermux.harness.tasks.hide": "Hide",
  "supermux.harness.tasks.outputTitle": "Output",
  "supermux.harness.tasks.outputLoading": "Reading output…",
  "supermux.harness.tasks.outputEmpty": "No output yet.",
  "supermux.harness.tasks.outputMissing": "This task has not written an output file yet.",
  "supermux.harness.tasks.outputFailed": "Could not read the output.",
  "supermux.harness.tasks.outputTruncated": "Showing the end of the output.",
  "supermux.harness.tasks.outputLive": "Live",

  "supermux.harness.bash.background": "Background",
  "supermux.harness.bash.backgroundedByUser": "Moved to background",
  "supermux.harness.bash.autoBackgrounded": "Backgrounded after {duration}",
  "supermux.harness.bash.moveToBackground": "Move to background",
  "supermux.harness.bash.moveToBackgroundHint":
    "Keep this command running and hand the turn back — the CLI's Ctrl+B.",
  "supermux.harness.bash.moveToBackgroundKey": "Ctrl+B",
  "supermux.harness.bash.moving": "Moving…",
  "supermux.harness.bash.moveFailed": "Could not move this command to the background.",
  "supermux.harness.bash.showOutput": "Show output",
  "supermux.harness.bash.hideOutput": "Hide output",
  "supermux.harness.bash.stop": "Stop",
  "supermux.harness.bash.statusRunning": "Still running",
  "supermux.harness.bash.statusCompleted": "Finished",
  "supermux.harness.bash.statusFailed": "Failed",
  "supermux.harness.bash.statusKilled": "Stopped",

  "supermux.harness.todo.title": "Plan",
  "supermux.harness.todo.progress": "{done}/{total}",
  "supermux.harness.todo.expand": "Show all steps",
  "supermux.harness.todo.collapse": "Collapse steps",

  "supermux.harness.permission.title": "Permission needed",
  "supermux.harness.permission.allowOnce": "Allow once",
  "supermux.harness.permission.allowAlways": "Always allow",
  "supermux.harness.permission.allowAlwaysRule": "Adds rule {rule}",
  "supermux.harness.permission.deny": "Deny",
  "supermux.harness.permission.denyReason": "Reason (optional)",
  "supermux.harness.permission.denyAndStop": "Deny and stop",
  "supermux.harness.permission.blockedPath": "Blocked path",
  // No one/other split: "1 more waiting" is already correct English.
  "supermux.harness.permission.moreWaiting": "{count} more waiting",
  "supermux.harness.permission.destinationLocal": "this project",
  "supermux.harness.permission.destinationProject": "the project settings",
  "supermux.harness.permission.destinationUser": "all projects",
  "supermux.harness.permission.destinationSession": "this session",
  "supermux.harness.permission.denyBack": "Back",

  "supermux.harness.plan.badge": "Plan",
  "supermux.harness.plan.title": "Claude has a plan",
  "supermux.harness.plan.approveAuto": "Approve & auto-accept edits",
  "supermux.harness.plan.approveManual": "Approve, ask before edits",
  "supermux.harness.plan.keepPlanning": "Keep planning",
  "supermux.harness.plan.keepPlanningMessage": "Keep planning — refine the approach first.",
  "supermux.harness.plan.copy": "Copy plan",
  "supermux.harness.plan.download": "Download plan as Markdown",
  "supermux.harness.plan.implement": "Implement",
  "supermux.harness.plan.refine": "Refine",

  "supermux.harness.question.badge": "Question",
  "supermux.harness.question.title": "Claude has a question",
  "supermux.harness.question.other": "Something else",
  "supermux.harness.question.otherPlaceholder": "Type your answer…",
  "supermux.harness.question.submit": "Submit",
  "supermux.harness.question.selectMultiple": "Select all that apply",
  "supermux.harness.question.dismiss": "Skip",
  "supermux.harness.question.dismissed": "Dismissed",
  "supermux.harness.question.unanswered": "Not answered yet",
  "supermux.harness.question.willSend": "Will send: {answer}",

  "supermux.harness.header.rename": "Rename session",
  "supermux.harness.header.renameSave": "Save",
  "supermux.harness.header.renameCancel": "Cancel",
  "supermux.harness.header.model": "Model",
  "supermux.harness.header.effort": "Effort",
  "supermux.harness.header.effortDefault": "Default",
  // The wire tokens are low | medium | high | xhigh | max. The set is closed and
  // enumerated in the contract, so each gets a display string rather than
  // leaking `xhigh` into a menu beside "Auto-edit" and "Opus (1M context)".
  "supermux.harness.effort.low": "Low",
  "supermux.harness.effort.medium": "Medium",
  "supermux.harness.effort.high": "High",
  "supermux.harness.effort.xhigh": "Extra high",
  "supermux.harness.effort.max": "Max",
  "supermux.harness.header.permissionMode": "Permissions",
  "supermux.harness.header.context": "Context",
  "supermux.harness.header.contextUsed": "{used} of {total} used",
  "supermux.harness.header.contextAutoCompact": "Auto-compacts at {threshold}",
  "supermux.harness.header.cost": "Cost",
  "supermux.harness.header.sessions": "Sessions",
  "supermux.harness.header.sessionsSearch": "Search sessions",
  "supermux.harness.header.sessionsEmpty": "No sessions yet for this folder",
  "supermux.harness.header.resume": "Resume",
  "supermux.harness.header.resumeHint": "Replaces this pane's session",
  "supermux.harness.header.fork": "Fork",
  "supermux.harness.header.forkHint": "Branch into a copy, leaving this one untouched",
  "supermux.harness.header.openInNewPane": "New pane",
  "supermux.harness.header.openInNewPaneHint": "Open beside this one, both live at once",
  "supermux.harness.header.more": "More",
  "supermux.harness.header.compact": "Compact conversation",
  "supermux.harness.header.clear": "Clear conversation",
  "supermux.harness.header.export": "Export transcript",
  "supermux.harness.header.openTerminal": "Open folder in terminal",
  "supermux.harness.header.newSession": "New session",
  "supermux.harness.header.binary": "Claude binary…",
  "supermux.harness.header.modelsLoading": "Loading models…",

  "supermux.harness.binary.title": "Claude binary",
  "supermux.harness.binary.resolved": "Currently using",
  "supermux.harness.binary.resolvedNone": "No binary resolved",
  "supermux.harness.binary.overrideLabel": "Custom path",
  "supermux.harness.binary.overridePlaceholder": "/Users/you/.local/bin/ccx",
  "supermux.harness.binary.help":
    "Point the pane at your own launcher or wrapper script. Leave it empty to search PATH.",
  "supermux.harness.binary.appliesNextStart": "Applies the next time the session starts.",
  "supermux.harness.binary.save": "Save",
  "supermux.harness.binary.clear": "Clear",
  "supermux.harness.binary.cancel": "Cancel",
  "supermux.harness.binary.saved": "Saved",
  "supermux.harness.binary.version": "Version {version}",

  "supermux.harness.rewind.action": "Rewind",
  "supermux.harness.rewind.title": "Rewind to this message",
  "supermux.harness.rewind.body":
    "Everything after this message is dropped, and its text goes back in the composer to edit.",
  "supermux.harness.rewind.restoreFiles": "Also restore files to this point",
  "supermux.harness.rewind.checking": "Checking what changed…",
  "supermux.harness.rewind.filesChangedOne": "{count} file · +{added} −{removed}",
  "supermux.harness.rewind.filesChanged": "{count} files · +{added} −{removed}",
  "supermux.harness.rewind.noFiles": "No file changes to restore",
  "supermux.harness.rewind.unavailable":
    "This session has no file checkpoints, so only the conversation can be rewound.",
  "supermux.harness.rewind.confirm": "Rewind & edit",
  "supermux.harness.rewind.cancel": "Cancel",
  "supermux.harness.rewind.done": "Rewound to before this message.",
  // The conversation half succeeded and the file half did not. Saying only
  // "Rewound" here is the lie: the working tree still holds the changes the
  // user asked to undo.
  "supermux.harness.rewind.doneFilesFailed":
    "Conversation rewound; files could not be restored.",
  "supermux.harness.rewind.failed": "Rewind failed",

  "supermux.harness.mode.default": "Ask each time",
  "supermux.harness.mode.defaultShort": "Ask",
  "supermux.harness.mode.acceptEdits": "Auto-accept edits",
  "supermux.harness.mode.acceptEditsShort": "Auto-edit",
  "supermux.harness.mode.plan": "Plan only",
  "supermux.harness.mode.planShort": "Plan",
  "supermux.harness.mode.bypassPermissions": "Bypass all prompts",
  "supermux.harness.mode.bypassPermissionsShort": "Bypass",

  "supermux.harness.divider.compact": "Conversation compacted",
  "supermux.harness.divider.compactTokens": "{tokens} tokens summarized",
  "supermux.harness.divider.reset": "Conversation cleared",
  "supermux.harness.history.truncated": "Earlier messages in this session are not shown",

  // The reducer knows the outcome; `{subject}` is the task's own description.
  "supermux.harness.notice.taskFinished": "Background task finished — {subject}",
  "supermux.harness.notice.taskStopped": "Background task stopped — {subject}",
  "supermux.harness.notice.taskFailed": "Background task failed — {subject}",
  // A workflow is announced as what it is, by its name — "Workflow stopped —
  // alpha-beta-demo" — not as a generic background task.
  "supermux.harness.notice.workflowFinished": "Workflow finished — {subject}",
  "supermux.harness.notice.workflowStopped": "Workflow stopped — {subject}",
  "supermux.harness.notice.workflowFailed": "Workflow failed — {subject}",

  "supermux.harness.banner.dismiss": "Dismiss",
  "supermux.harness.banner.retryAttempt": "Attempt {attempt} of {max}",

  "supermux.harness.error.generic": "Something went wrong",
  "supermux.harness.error.rateLimit": "Usage limit reached",
  "supermux.harness.error.billing": "Billing problem",
  "supermux.harness.error.auth": "Authentication failed",
  "supermux.harness.error.startFailed": "Could not start Claude",

  "supermux.harness.a11y.transcript": "Conversation transcript",
  "supermux.harness.a11y.composer": "Message composer",
  "supermux.harness.a11y.permissionAlert": "Claude needs permission to continue",
  "supermux.harness.a11y.timeline": "Conversation timeline",
  "supermux.harness.a11y.closeDialog": "Close",

  "supermux.harness.time.seconds": "{value}s",
  "supermux.harness.time.minutes": "{value}m {seconds}s",
  "supermux.harness.time.hours": "{value}h {minutes}m",
  "supermux.harness.time.justNow": "just now",
  "supermux.harness.time.minutesAgo": "{value}m ago",
  "supermux.harness.time.hoursAgo": "{value}h ago",
  "supermux.harness.time.daysAgo": "{value}d ago"
} as const;

export type CopyKey = keyof typeof copyDefaults;

export const copyKeys = Object.keys(copyDefaults) as CopyKey[];

export function resolveCopy(dict: Record<string, string> | undefined): Record<CopyKey, string> {
  const out = { ...copyDefaults } as Record<CopyKey, string>;
  if (!dict) return out;
  for (const key of copyKeys) {
    const value = dict[key];
    if (typeof value === "string" && value.length > 0) out[key] = value;
  }
  return out;
}

export function format(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{(\w+)\}/g, (match, name: string) => {
    const value = values[name];
    return value === undefined ? match : String(value);
  });
}

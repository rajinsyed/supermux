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
 *
 * The agents dock then retired the round-3 TasksStrip itself, and with it the
 * strip-only `tasks.*` rows (title, counts, collapse, expand, the type and
 * status families, moreBelow, untitled, stop, view, hide) plus
 * `workflow.viewAgents` (the strip's
 * agent picker — the browser's phase list is that affordance now). The
 * `tasks.*` keys that survive are the ones the Bash card's background strip and
 * the task-output tail still render.
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
  // `composer.hintInterrupt` ("Esc to interrupt") retired with the busy status
  // strip that was its only render site: the strip no longer narrates a running
  // turn at all, because the composer's Stop button IS that state. Its Swift and
  // xcstrings rows should go with it.
  "supermux.harness.composer.attach": "Attach files",
  "supermux.harness.composer.removeAttachment": "Remove attachment",
  "supermux.harness.composer.attachmentName": "image",
  "supermux.harness.composer.attachmentUnsupported":
    "Unsupported image format. Use PNG, JPEG, GIF, or WebP.",
  "supermux.harness.composer.attachmentInvalid": "Could not read this image.",
  "supermux.harness.composer.attachmentTooLarge": "Each image must be 512 KiB or smaller.",
  "supermux.harness.composer.attachmentTotalTooLarge":
    "Attachments must total 2 MiB or less.",
  "supermux.harness.composer.attachmentTooMany": "You can attach up to 8 images.",
  "supermux.harness.composer.queued": "Queued",
  "supermux.harness.composer.cancelQueued": "Cancel queued message",
  "supermux.harness.composer.mentionTitle": "Files",
  "supermux.harness.composer.mentionEmpty": "No matching files",
  "supermux.harness.composer.commandTitle": "Commands",
  "supermux.harness.composer.commandEmpty": "No matching commands",

  // The strip above the composer narrates EXCEPTIONS only. Eight keys retired
  // with the busy states it used to print — `status.thinking`,
  // `status.thinkingTokens`, `status.running`, `status.waitingApproval`,
  // `status.compacting`, `status.starting`, `status.queuedOne`,
  // `status.queued` — because every one of them restated something already on
  // screen (the composer's Stop button, the permission card, the queue chips),
  // and the row appearing and vanishing under the composer moved the whole dock
  // as a turn advanced. Their Swift and xcstrings rows should go with them.
  "supermux.harness.status.retrying": "Retrying in {seconds}s · attempt {attempt} of {max}",
  "supermux.harness.status.restarting": "Restarting Claude…",
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
  "supermux.harness.turn.exportTitle": "Claude session",
  "supermux.harness.turn.commandChip": "Slash command",
  "supermux.harness.divider.continued": "Continued from a previous conversation",

  "supermux.harness.thinking.label": "Thinking",
  // `thinking.summary` (tokens + duration) retired with the per-step metric
  // chrome: a settled thinking row now reads "Thinking · 4s" only.
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

  // --- Round 4: the multi-pane workflow browser ---
  // The transcript keeps a one-line row; the run itself is browsed in a full
  // view with a phases column, a phase agent list, and an agent detail pane.
  "supermux.harness.workflow.browser.title": "Workflow",
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

  // --- The working panel (agents dock), floating above the composer ---
  // Cursor's header grammar verbatim: "2 Working — Stop All — ✕". The panel
  // lists ONLY working subagents; main is not a row (the way back to the main
  // chat is the framed view's own close).
  "supermux.harness.dock.title": "Agents",
  "supermux.harness.dock.workingOne": "{count} Working",
  "supermux.harness.dock.working": "{count} Working",
  "supermux.harness.dock.stopAll": "Stop All",
  "supermux.harness.dock.collapse": "Hide agents",
  "supermux.harness.dock.expand": "Show agents",
  "supermux.harness.dock.stop": "Stop",
  "supermux.harness.dock.stopping": "Stopping…",
  "supermux.harness.dock.stopFailed": "Could not stop this task.",
  "supermux.harness.dock.untitledAgent": "Agent",
  "supermux.harness.dock.untitledShell": "Shell",
  "supermux.harness.dock.untitledWorkflow": "Workflow",
  // The status vocabulary is gone entirely: every row on the panel is running
  // by construction, and saying so in orange on every line was noise. State is
  // carried by the animated glyph alone.
  "supermux.harness.dock.workflowAgents": "{done}/{total} agents",
  "supermux.harness.dock.a11y": "Agents and background tasks",

  // --- Full-chat agent views, framed like Cursor's subagent panel ---
  "supermux.harness.view.backTo": "Back to {label}",
  "supermux.harness.view.close": "Close",
  "supermux.harness.view.rootCrumb": "Claude",
  "supermux.harness.agentView.prompt": "Prompt",
  "supermux.harness.agentView.empty": "This agent has not said anything yet.",
  "supermux.harness.agentView.working": "Working…",
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

  // The rest of the round-3 `tasks.*` family went with the TasksStrip the dock
  // replaced (see the retirement note above); these survivors render in the
  // Bash card's background strip and the task-output tail.
  "supermux.harness.tasks.stopping": "Stopping…",
  "supermux.harness.tasks.stopFailed": "Could not stop this task.",
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
  "supermux.harness.question.willSend": "Will send: {answer}",
  // Round 6: the card shows ONE question at a time with a stepper, so the
  // "Not answered yet" placeholder that used to fill every inactive section is
  // retired — `question.unanswered` should lose its Swift and xcstrings rows
  // with it. What replaces it is a position ("2 of 3") plus per-step marks that
  // say which steps are answered, and two controls to walk between them.
  "supermux.harness.question.step": "{index} of {total}",
  "supermux.harness.question.previous": "Previous question",
  "supermux.harness.question.next": "Next question",
  "supermux.harness.question.stepAnswered": "Question {index}, answered",
  "supermux.harness.question.stepUnanswered": "Question {index}, not answered",
  // The single-select's "or type your own" affordance. It was an always-open
  // text field under every option list — a fourth box in a three-option
  // question — and is a quiet row that opens one now.
  "supermux.harness.question.otherRow": "Something else…",

  // `header.rename` / `header.renameSave` / `header.renameCancel` retired with
  // the bottom bar's session title. The strip carries the pane's ADDRESS (the
  // folder) and its CONTROLS; the title named something the user never chose
  // (the CLI's own auto-title), was the widest thing on the line, and opened an
  // inline text field in a bar whose every other control opens a menu. The
  // `onRename` prop survives on HeaderProps for a future surface that suits it.
  // Their Swift and xcstrings rows should go with them.
  "supermux.harness.header.model": "Model",
  // `header.effort` ("Effort") retired with the bottom bar's model pill: the
  // picker moved into the composer, where the setting is a "Reasoning" row in
  // the per-model flyout rather than a menu section heading. Its Swift and
  // xcstrings rows should go with it.
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
  // Abbreviated because it shares a 11px meta line with a relative time and a
  // branch name; the full word would push the branch out of every row.
  "supermux.harness.header.sessionMessages": "{count} msgs",
  // `header.resume` retired with the sessions panel's legend row. The foot of
  // that panel is ONE action (New session) rather than an action plus a caption
  // explaining a different one; what the row's own click does is on the row, as
  // its title. Its Swift and xcstrings rows should go with it.
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
  // `model.search` / `model.noMatches` retired with the picker's search field.
  // A filter over four rows that all fit on screen cost a row of chrome, stole
  // the caret on open, and made the first keystroke ambiguous; the panel is a
  // list now. Their Swift and xcstrings rows should go with them.
  "supermux.harness.model.reasoning": "Reasoning",
  "supermux.harness.model.restoreDefaults": "Restore defaults",
  // The two gestures that move reasoning without opening the panel, named on the
  // trigger's own tooltip: a wheel over a text label is not a discoverable
  // control unless something says so, and Option+,/. is the CLI's own pair of
  // bindings, which a user arriving from the terminal will reach for first.
  "supermux.harness.model.effortWheelHint": "Scroll or press ⌥, / ⌥. to change reasoning",

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
  // Round 6: the dialog lists the two things a rewind does rather than
  // describing them in one sentence, so each half needs a name of its own and
  // the always-on half needs to say that it is not a choice.
  "supermux.harness.rewind.quoteLabel": "Rewinding to",
  "supermux.harness.rewind.conversationTitle": "Rewind the conversation",
  "supermux.harness.rewind.always": "Always",
  "supermux.harness.rewind.restoreFiles": "Also restore files to this point",
  "supermux.harness.rewind.checking": "Checking what changed…",
  "supermux.harness.rewind.filesChangedOne": "{count} file · +{added} −{removed}",
  "supermux.harness.rewind.filesChanged": "{count} files · +{added} −{removed}",
  "supermux.harness.rewind.noFiles": "No file changes to restore",
  "supermux.harness.rewind.unavailable":
    "This session has no file checkpoints, so only the conversation can be rewound.",
  "supermux.harness.rewind.confirm": "Rewind & edit",
  "supermux.harness.rewind.cancel": "Cancel",
  // A successful rewind says so by ITSELF — the transcript truncates and the
  // message is back in the composer — so `rewind.done` was retired with the
  // rest of the success chips. Only the half that leaves no trace on screen
  // still speaks: the conversation rewound and the working tree did not.
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
  // One line of CONSEQUENCE per mode. The four names alone ("Ask each time",
  // "Plan only") name a policy without saying what it lets through, which is
  // the only thing the choice is about.
  "supermux.harness.mode.defaultDetail": "Approve every file edit and command",
  "supermux.harness.mode.acceptEditsDetail": "Edits apply on their own; commands still ask",
  "supermux.harness.mode.planDetail": "Research and propose, change nothing",
  "supermux.harness.mode.bypassPermissionsDetail": "No prompts at all — use with care",

  "supermux.harness.divider.compact": "Conversation compacted",
  "supermux.harness.divider.compactTokens": "{tokens} tokens summarized",
  "supermux.harness.divider.reset": "Conversation cleared",
  "supermux.harness.history.truncated": "Earlier messages in this session are not shown",

  // The six `notice.task*`/`notice.workflow*` outcome keys stood here. They
  // phrased the finished-background-task banner, which is gone: a completion
  // never raises a floating chip any more. The outcome is read on the launching
  // card and in the dock row's disappearance.

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

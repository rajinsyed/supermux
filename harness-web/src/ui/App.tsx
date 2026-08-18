import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { dockRows } from "../model/dock";
import { resolveModel } from "../model/helpers";
import { runningForegroundBash } from "../model/tasks";
import type { HarnessStore } from "../model/store";
import type { ImageAttachment, RelayTarget } from "../model/types";
import type { JsonObject, ProtocolLine } from "../protocol/types";
import { CopyProvider, useCopy } from "./CopyContext";
import { Composer } from "./composer/Composer";
import { AgentsDock } from "./dock/AgentsDock";
import { EmptyState, ExitedState, NoCliState } from "./empty/EmptyStates";
import { Header } from "./header/Header";
import { AlertTriangle, Close } from "./Icons";
import { BinaryDialog } from "./settings/BinaryDialog";
import { RewindDialog, type RewindTarget } from "./transcript/RewindDialog";
import { PermissionCard, type PermissionDecision } from "./permission/PermissionCard";
import { PlanCard } from "./permission/PlanCard";
import { setModeSuggestion } from "./permission/permissionText";
import { QuestionCard } from "./permission/QuestionCard";
import { BannerStack } from "./status/BannerStack";
import { StatusStrip } from "./status/StatusStrip";
import { TodoStrip } from "./status/TodoStrip";
import { applyThemeVariables } from "./theme";
import { TranscriptList } from "./transcript/TranscriptList";
import { useScrollFollow } from "./transcript/useScrollFollow";
import { exportTranscript } from "./exportTranscript";
import { useHarness } from "./useHarness";
import { AgentChatView } from "./views/AgentChatView";
import { OpenViewContext } from "./views/OpenViewContext";
import { ShellView } from "./views/ShellView";
import { relayInstruction } from "./views/relay";
import { useViewRouter } from "./views/useViewRouter";
import { ViewBreadcrumb } from "./views/ViewBreadcrumb";
import { WorkflowView } from "./workflow/WorkflowView";

export function App({ store }: { store: HarnessStore }) {
  const harness = useHarness(store);

  useEffect(() => {
    applyThemeVariables(document.documentElement, harness.theme);
  }, [harness.theme]);

  // Split so everything below can call useCopy(); the provider has to be an
  // ancestor of its consumers.
  return (
    <CopyProvider dict={harness.context?.copy}>
      <AppBody store={store} harness={harness} />
    </CopyProvider>
  );
}

function AppBody({
  store,
  harness
}: {
  store: HarnessStore;
  harness: ReturnType<typeof useHarness>;
}) {
  const copy = useCopy();
  const { model, context } = harness;
  const [binaryOpen, setBinaryOpen] = useState(false);
  const [rewindTarget, setRewindTarget] = useState<RewindTarget | undefined>(undefined);
  /**
   * The rewind receipt — FAILURES ONLY.
   *
   * A successful rewind announces itself: the transcript truncates under the
   * reader's eyes and their message is back in the composer with the caret in
   * it. A chip on top of that was a dismissable restatement of something the
   * user just watched happen, and it is gone with the rest of the completion
   * toasts. What survives is the half that is INVISIBLE — `rewind_files`
   * refusing while the conversation rewound anyway. Nothing else on screen says
   * the working tree still holds the changes the user asked to undo.
   */
  const [rewindNote, setRewindNote] = useState<string | undefined>(undefined);
  const composerFocus = useRef<(() => void) | undefined>(undefined);

  const router = useViewRouter(model, copy);
  const view = router.view;
  const rows = useMemo(() => dockRows(model), [model]);
  const thread = view.kind === "agent" ? model.agentThreads[view.toolUseId] : undefined;
  /**
   * The relays addressed to the agent on screen. Read from the model rather
   * than kept in component state so switching away from an agent view and back
   * shows the same delivery status — the send outlives the view that made it.
   */
  const viewRelays = useMemo(
    () =>
      view.kind === "agent"
        ? Object.values(model.relays)
            .filter((relay) => relay.toolUseId === view.toolUseId)
            .sort((a, b) => a.sentAtMs - b.sentAtMs)
        : [],
    [model.relays, view]
  );

  const { ref: scrollRef, contentRef, showPill, scrollToBottom } = useScrollFollow([
    model.revision,
    model.turns.length,
    model.pending.length
  ]);

  // Turn-complete and permission notifications are posted by the NATIVE side
  // from protocol frames, through the same policy gate and unread-badge store
  // the terminal's Claude Code hooks use. A web-side `document.hidden` gate
  // never fired for an embedded WKWebView (the page is "visible" even with the
  // app in the background), which is why the pane showed no badge or banner.

  const pending = model.pending[0];

  useEffect(() => {
    if (!pending) return;
    const frame = requestAnimationFrame(() => scrollToBottom(true));
    return () => cancelAnimationFrame(frame);
  }, [pending?.requestId, scrollToBottom]);

  const decide = useCallback(
    (decision: PermissionDecision) => {
      if (!pending) return;
      store.dispatch({
        kind: "permissionResolved",
        requestId: pending.requestId,
        behavior: decision.behavior,
        // Carried so the reducer can leave a record of an answered question in
        // the transcript; the answers only exist in this payload.
        updatedInput:
          decision.updatedInput && typeof decision.updatedInput === "object"
            ? (decision.updatedInput as JsonObject)
            : undefined
      });
      harness.bridge
        .respondPermission({
          requestId: pending.requestId,
          behavior: decision.behavior,
          updatedInput: decision.updatedInput,
          updatedPermissions: decision.updatedPermissions,
          message: decision.message,
          interrupt: decision.interrupt
        })
        .catch(() => undefined);
      const setMode = decision.updatedPermissions?.find((s) => s.type === "setMode") as
        | { mode?: string }
        | undefined;
      if (setMode?.mode) {
        store.dispatch({ kind: "setPermissionMode", mode: setMode.mode as never });
      }
    },
    [harness.bridge, pending, store]
  );

  const fetchFileSuggestions = useCallback(
    async (query: string) => {
      const result = await harness.bridge.fileSuggestions({ query }).catch(() => undefined);
      return result?.paths ?? [];
    },
    [harness.bridge]
  );

  const pickFiles = useCallback(async (): Promise<ImageAttachment[]> => {
    const result = await harness.bridge.pickFiles().catch(() => undefined);
    return result?.images ?? [];
  }, [harness.bridge]);

  const running =
    model.activity.sessionState === "running" ||
    model.activity.status === "requesting" ||
    model.turns.some((turn) => turn.state === "streaming");

  /**
   * Ctrl+B, exactly as the CLI binds it: move the Bash that is blocking the turn
   * into the background. The same action is a button on the running card — one
   * shared path, so the two can never diverge — and this is the reflex a user
   * arriving from the terminal will reach for first.
   *
   * Omitting the tool_use_id would background EVERY foreground task, which is
   * the CLI's own fallback; the id is passed whenever a specific Bash is in
   * flight so the key cannot silently move work the user was not looking at.
   */
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (!event.ctrlKey || event.metaKey || event.altKey) return;
      if (event.key !== "b" && event.key !== "B") return;
      const target = runningForegroundBash(model);
      if (!target) return;
      event.preventDefault();
      harness.bridge.backgroundTask({ toolUseId: target }).catch(() => undefined);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [harness.bridge, model]);

  /**
   * Sending from inside an agent view.
   *
   * The wire has no way to prompt an agent directly, so this is a two-step
   * relay, and the ORDER matters:
   *
   *  1. Background the agent's Task if it has one. A relay only reaches main's
   *     model at main's NEXT turn, and if main is blocked on this very agent's
   *     foreground Task, that is after the agent has already finished — the
   *     message would arrive too late to be guidance. `background_tasks` frees
   *     main to take the turn. The reply is honoured honestly: a false or a
   *     rejection is recorded on the relay, and the agent view says the message
   *     will land when the agent finishes rather than pretending otherwise.
   *  2. Send the probed relay instruction to main as an ordinary message.
   *
   * The user's own text — not the instruction — is what the chip and the
   * agent's thread show; the instruction is plumbing and never appears as
   * something the user said.
   */
  const sendToAgent = useCallback(
    (text: string) => {
      if (view.kind !== "agent" || !thread) return;
      const description = thread.description ?? thread.subagentType ?? thread.toolUseId;
      const target: RelayTarget = { toolUseId: thread.toolUseId, description: thread.description };
      const instruction = relayInstruction(description, text);
      const running = thread.status !== "completed" && thread.status !== "failed";
      const needsBackgrounding = running && thread.background !== true;
      const send = (backgrounded: boolean | undefined) =>
        harness.sendRelay(instruction, text, target, backgrounded);
      if (!needsBackgrounding) {
        send(true);
        return;
      }
      harness.bridge
        .backgroundTask({ toolUseId: thread.toolUseId })
        .then((result) => send(result?.backgrounded === true))
        // A refusal is not a reason to drop the message: it still goes, and the
        // relay carries the honest note about when it will arrive.
        .catch(() => send(false));
    },
    [harness, thread, view]
  );

  const hydrateThread = useCallback(
    (toolUseId: string, events: ProtocolLine[]) => {
      store.dispatch({ kind: "hydrateThread", toolUseId, events });
    },
    [store]
  );

  const cliUnavailable = context !== undefined && context.cliStatus.available === false;

  const planPending = pending?.kind === "plan" || pending?.kind === "enterPlan";

  // The plan card and the composer answer the SAME request, so both go through
  // one decision path rather than each keeping its own copy of the protocol.
  const decidePlan = useCallback(
    (refinement?: string) => {
      if (!pending) return;
      if (refinement) {
        decide({ behavior: "deny", message: refinement });
        harness.setDraft("");
        return;
      }
      decide({
        behavior: "allow",
        updatedInput: pending.request.input,
        updatedPermissions: [setModeSuggestion(pending.request, "acceptEdits")]
      });
    },
    [decide, harness, pending]
  );

  /**
   * "Rewind to message N" means the conversation is resumed AT message N-1, so
   * the target's predecessor is what the CLI needs. No predecessor means N is
   * the first message and the new run is a fresh session, which is why
   * `resumeAtUuid` is optional rather than defaulted.
   */
  const openRewind = useCallback(
    (uuid: string) => {
      const index = model.turns.findIndex((turn) => turn.userUuid === uuid);
      if (index < 0) return;
      const turn = model.turns[index];
      let resumeAtUuid: string | undefined;
      for (let i = index - 1; i >= 0; i -= 1) {
        if (model.turns[i].userUuid) {
          resumeAtUuid = model.turns[i].userUuid;
          break;
        }
      }
      setRewindNote(undefined);
      setRewindTarget({ uuid, text: turn.userText ?? "", resumeAtUuid });
    },
    [model.turns]
  );

  const confirmRewind = useCallback(
    (restoreFiles: boolean) => {
      const target = rewindTarget;
      if (!target) return;
      setRewindTarget(undefined);
      harness
        .rewind(target, restoreFiles)
        .then((result) => {
          // A rewind has two halves that fail independently. The conversation
          // half succeeded — the promise resolved — but `rewind_files` can still
          // have refused, and NOTHING on screen would say so: the transcript
          // truncates either way. Only that failure earns a note; the success
          // the user is already watching does not.
          const failed = restoreFiles && !result.filesRestored;
          const base = copy("supermux.harness.rewind.doneFilesFailed");
          setRewindNote(
            failed ? (result.reason ? `${base} ${result.reason}` : base) : undefined
          );
          // The composer is prefilled with the original text; putting the caret
          // in it is the difference between "here is your message back" and
          // "find the box and click it yourself".
          composerFocus.current?.();
        })
        .catch((error: unknown) => {
          setRewindNote(
            error instanceof Error ? error.message : copy("supermux.harness.rewind.failed")
          );
        });
    },
    [copy, harness, rewindTarget]
  );

  const permissionPane = useMemo(() => {
    if (!pending) return null;
    const queueCount = model.pending.length - 1;
    if (pending.kind === "plan" || pending.kind === "enterPlan") {
      return <PlanCard pending={pending} onDecide={decide} />;
    }
    if (pending.kind === "question") {
      return <QuestionCard pending={pending} onDecide={decide} />;
    }
    return <PermissionCard pending={pending} queueCount={queueCount} onDecide={decide} />;
  }, [decide, model.pending.length, pending]);

  const inAgentView = view.kind === "agent" && thread !== undefined;
  // An agent that has finished cannot be messaged: there is no mailbox left to
  // drop into, and a relay would just be an instruction main answers itself.
  // The composer stays, addressed to Claude, and says so.
  const agentReachable =
    inAgentView && thread!.status !== "completed" && thread!.status !== "failed";

  return (
    <OpenViewContext.Provider value={router.open}>
    <div className="app">
      <Header
        degraded={cliUnavailable}
        session={model.session}
        usage={model.usage}
        contextUsage={model.contextUsage}
        workingDirectory={context?.workingDirectory ?? model.session.cwd}
        sessions={harness.sessions}
        cachedModels={model.cachedModels}
        onRename={(title) => {
          store.dispatch({ kind: "setTitle", title });
          harness.bridge.renameSession({ title }).catch(() => undefined);
        }}
        onSetModel={harness.setModel}
        onSetPermissionMode={harness.setPermissionMode}
        onResumeSession={(sessionId, fork) => harness.restart(sessionId, fork)}
        onOpenSessionInNewPane={harness.openSessionInNewPane}
        onLoadSessions={harness.refreshSessions}
        onCompact={() => harness.send("/compact", [])}
        onClear={() => {
          store.dispatch({ kind: "reset" });
          harness.send("/clear", []);
        }}
        onExport={() => {
          const markdown = exportTranscript(model, copy);
          harness.bridge.copyText({ text: markdown }).catch(() => undefined);
        }}
        onOpenTerminal={() => {
          const dir = context?.workingDirectory ?? model.session.cwd;
          if (dir) harness.bridge.openFile({ path: dir }).catch(() => undefined);
        }}
        onNewSession={harness.newSession}
        onOpenBinarySettings={() => setBinaryOpen(true)}
      />

      {/* Where you are, and one press back. Only ever present when the stack
          has depth — the main chat has nowhere to return to, and a breadcrumb
          reading just "Claude" would be a row of chrome that says nothing. */}
      <ViewBreadcrumb
        stack={router.stack}
        labelFor={router.labelFor}
        onBack={router.back}
        onOpen={router.open}
      />

      {cliUnavailable ? (
        <div className="harness-scroll transcript">
          <div className="transcript-inner">
            <NoCliState
              status={context!.cliStatus}
              onRetry={harness.reloadContext}
              onSetBinary={() => setBinaryOpen(true)}
            />
          </div>
        </div>
      ) : view.kind === "agent" ? (
        <AgentChatView
          thread={thread}
          threads={model.agentThreads}
          relays={viewRelays}
          scrollRef={scrollRef}
          contentRef={contentRef}
          showPill={showPill}
          onJump={() => scrollToBottom(true)}
          onHydrate={hydrateThread}
        />
      ) : view.kind === "workflow" ? (
        <div className="harness-scroll transcript" ref={scrollRef}>
          <div className="transcript-inner" ref={contentRef}>
            <WorkflowView model={model} taskId={view.taskId} onBack={router.back} />
          </div>
        </div>
      ) : view.kind === "shell" ? (
        <ShellView
          record={model.tasksById[view.taskId]}
          scrollRef={scrollRef}
          contentRef={contentRef}
        />
      ) : (
        <TranscriptList
          turns={model.turns}
          relays={model.relays}
          scrollRef={scrollRef}
          contentRef={contentRef}
          showPill={showPill}
          onJump={() => scrollToBottom(true)}
          onRewind={openRewind}
          header={
            model.turns.length === 0 ? (
              <EmptyState
                workingDirectory={context?.workingDirectory ?? model.session.cwd}
                // The empty state is BY DEFINITION pre-start, so `session.models`
                // is empty here more often than not and the cached catalog is the
                // only thing that can turn a selector into a name. Same fallback
                // the header pill uses, or the two chips on one screen disagree.
                modelName={
                  resolveModel(model.session, model.cachedModels)?.displayName ??
                  model.session.model
                }
                sessions={harness.sessions}
                onSuggestion={(text) => harness.setDraft(text)}
                onResume={(sessionId) => harness.restart(sessionId, false)}
              />
            ) : model.historyTruncated ? (
              <div className="divider" role="separator">
                <span className="divider-line" />
                <span className="divider-sub">
                  {copy("supermux.harness.history.truncated")}
                </span>
                <span className="divider-line" />
              </div>
            ) : null
          }
          footer={
            <>
              {permissionPane}
              {model.runPhase === "exited" && model.turns.length > 0 ? (
                <ExitedState
                  error={model.exitError}
                  startFailed={model.startFailed}
                  stderrTail={model.stderrTail}
                  onRestart={() => harness.restart()}
                />
              ) : null}
            </>
          }
        />
      )}

      <div className="dock">
        <BannerStack
          banners={model.banners}
          onDismiss={(id) => store.dispatch({ kind: "dismissBanner", id })}
        />
        {/* The CLI's agents dock, above the composer. It replaces the round-3
            tasks strip entirely: same information, plus every agent and its
            tree, and rows that persist for the session instead of vanishing
            when the CLI's background set empties. */}
        <AgentsDock rows={rows} activeView={view} onOpen={router.open} />
        <TodoStrip todos={model.todos} />
        {rewindNote ? (
          <div
            className="rewind-note is-degraded"
            // Always a failure now, so always an interrupt: `status` is
            // announced whenever the screen reader gets round to it, and "the
            // files on disk are not what you just asked for" cannot wait.
            role="alert"
          >
            <AlertTriangle size={12} />
            {rewindNote}
            <button
              type="button"
              className="rewind-note-x"
              onClick={() => setRewindNote(undefined)}
              aria-label={copy("supermux.harness.banner.dismiss")}
            >
              <Close size={10} />
            </button>
          </div>
        ) : null}
        <StatusStrip
          model={model}
          runPhase={model.runPhase}
          activity={model.activity}
          cliUnavailable={cliUnavailable}
          restarting={harness.restarting}
          onRestart={() => harness.restart()}
        />
        <Composer
          // A send during a restart reaches a process that is being torn down
          // and is simply lost, so the composer says so instead of accepting it.
          disabled={cliUnavailable || harness.restarting}
          // Both states disable the composer; only this one says which.
          restarting={harness.restarting}
          running={running}
          registerFocus={(focus) => {
            composerFocus.current = focus;
          }}
          awaitingPermission={model.pending.length > 0}
          planPending={planPending}
          onPlanImplement={() => decidePlan()}
          onPlanRefine={(text) => decidePlan(text)}
          onPlanKeepPlanning={() =>
            decidePlan(copy("supermux.harness.plan.keepPlanningMessage"))
          }
          // Stranded messages are still waiting to be sent, so they stay on the
          // strip: a chip that disappears when the process dies reads as a
          // message that was delivered.
          queued={model.stranded.length > 0 ? model.stranded.concat(model.queued) : model.queued}
          commands={model.session.commands}
          permissionMode={model.session.permissionMode}
          draft={harness.draft}
          onDraftChange={harness.setDraft}
          // In an agent view the composer addresses THAT agent, through the
          // relay. A reachable agent takes the message; a finished one cannot,
          // so the send falls back to Claude and the placeholder says so rather
          // than silently redirecting what the user thought they were sending.
          onSend={
            agentReachable ? (text) => sendToAgent(text) : harness.send
          }
          agentName={
            inAgentView
              ? agentReachable
                ? thread!.description ?? copy("supermux.harness.dock.untitledAgent")
                : null
              : undefined
          }
          onInterrupt={harness.interrupt}
          onCancelQueued={harness.cancelQueued}
          onCyclePermissionMode={harness.cyclePermissionMode}
          fetchFileSuggestions={fetchFileSuggestions}
          onPickFiles={pickFiles}
        />
      </div>

      {binaryOpen ? (
        <BinaryDialog
          onClose={() => {
            setBinaryOpen(false);
            // The resolved path may have moved, and the model catalog is keyed
            // on the binary — both live in the context reply.
            harness.reloadContext();
          }}
          load={harness.bridge.getBinarySetting}
          save={(path) => harness.bridge.setBinaryPath({ path })}
        />
      ) : null}

      {rewindTarget ? (
        <RewindDialog
          target={rewindTarget}
          onCancel={() => setRewindTarget(undefined)}
          onConfirm={confirmRewind}
          loadPreview={harness.rewindPreview}
        />
      ) : null}
    </div>
    </OpenViewContext.Provider>
  );
}

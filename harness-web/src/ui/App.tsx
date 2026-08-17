import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { resolveModel } from "../model/helpers";
import type { HarnessStore } from "../model/store";
import type { ImageAttachment } from "../model/types";
import type { JsonObject } from "../protocol/types";
import { CopyProvider, useCopy } from "./CopyContext";
import { Composer } from "./composer/Composer";
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
   * The rewind receipt. `degraded` is carried alongside the text rather than
   * sniffed back out of it: the strip has to LOOK like a warning when the file
   * half failed, and a note that reads "could not be restored" in the same
   * accent as a plain success is the same understatement in a different place.
   */
  const [rewindNote, setRewindNote] = useState<
    { text: string; degraded?: boolean } | undefined
  >(undefined);
  const composerFocus = useRef<(() => void) | undefined>(undefined);

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
          // have refused, and reporting the flat success string there tells the
          // user their working tree was restored when it was not. The note only
          // changes when a restore was actually ASKED for: a conversation-only
          // rewind reports success, because that is all it promised.
          const failed = restoreFiles && !result.filesRestored;
          const base = failed
            ? copy("supermux.harness.rewind.doneFilesFailed")
            : copy("supermux.harness.rewind.done");
          setRewindNote({
            text: failed && result.reason ? `${base} ${result.reason}` : base,
            degraded: failed
          });
          // The composer is prefilled with the original text; putting the caret
          // in it is the difference between "here is your message back" and
          // "find the box and click it yourself".
          composerFocus.current?.();
        })
        .catch((error: unknown) => {
          setRewindNote({
            text: error instanceof Error ? error.message : copy("supermux.harness.rewind.failed"),
            degraded: true
          });
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

  return (
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
      ) : (
        <TranscriptList
          turns={model.turns}
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
        <TodoStrip todos={model.todos} />
        {rewindNote ? (
          <div
            className={`rewind-note${rewindNote.degraded ? " is-degraded" : ""}`}
            // A degraded note reports a failure, and `status` is announced only
            // when the screen reader gets round to it; `alert` interrupts, which
            // is right for "the files on disk are not what you just asked for".
            role={rewindNote.degraded ? "alert" : "status"}
          >
            {rewindNote.degraded ? <AlertTriangle size={12} /> : null}
            {rewindNote.text}
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
          onSend={harness.send}
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
  );
}

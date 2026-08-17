import { useCallback, useEffect, useMemo, useRef } from "react";
import type { HarnessStore } from "../model/store";
import type { ImageAttachment } from "../model/types";
import { CopyProvider, useCopy } from "./CopyContext";
import { Composer } from "./composer/Composer";
import { EmptyState, ExitedState, NoCliState } from "./empty/EmptyStates";
import { Header } from "./header/Header";
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
  const notifiedTurns = useRef(0);

  const { ref: scrollRef, contentRef, showPill, scrollToBottom } = useScrollFollow([
    model.revision,
    model.turns.length,
    model.pending.length
  ]);

  useEffect(() => {
    const settled = model.turns.filter((turn) => turn.state !== "streaming").length;
    if (settled > notifiedTurns.current && notifiedTurns.current > 0 && document.hidden) {
      harness.bridge
        .notify({
          title: copy("supermux.harness.app.title"),
          body: model.session.title ?? copy("supermux.harness.turn.complete")
        })
        .catch(() => undefined);
    }
    notifiedTurns.current = settled;
  }, [copy, harness.bridge, model.session.title, model.turns]);

  useEffect(() => {
    if (model.pending.length === 0 || !document.hidden) return;
    harness.bridge
      .notify({
        title: copy("supermux.harness.app.title"),
        body: copy("supermux.harness.permission.needed")
      })
      .catch(() => undefined);
  }, [copy, harness.bridge, model.pending.length]);

  const pending = model.pending[0];

  useEffect(() => {
    if (!pending) return;
    const frame = requestAnimationFrame(() => scrollToBottom(true));
    return () => cancelAnimationFrame(frame);
  }, [pending?.requestId, scrollToBottom]);

  const decide = useCallback(
    (decision: PermissionDecision) => {
      if (!pending) return;
      store.dispatch({ kind: "permissionResolved", requestId: pending.requestId });
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
        onRename={(title) => {
          store.dispatch({ kind: "setTitle", title });
          harness.bridge.renameSession({ title }).catch(() => undefined);
        }}
        onSetModel={harness.setModel}
        onSetPermissionMode={harness.setPermissionMode}
        onResumeSession={(sessionId, fork) => harness.restart(sessionId, fork)}
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
        onNewSession={() => {
          store.dispatch({ kind: "reset" });
          harness.restart();
        }}
      />

      {cliUnavailable ? (
        <div className="harness-scroll transcript">
          <div className="transcript-inner">
            <NoCliState status={context!.cliStatus} onRetry={harness.reloadContext} />
          </div>
        </div>
      ) : (
        <TranscriptList
          turns={model.turns}
          scrollRef={scrollRef}
          contentRef={contentRef}
          showPill={showPill}
          onJump={() => scrollToBottom(true)}
          header={
            model.turns.length === 0 ? (
              <EmptyState
                workingDirectory={context?.workingDirectory ?? model.session.cwd}
                modelName={
                  model.session.models.find((m) => m.value === model.session.model)?.displayName ??
                  model.session.model
                }
                sessions={harness.sessions}
                onSuggestion={(text) => harness.setDraft(text)}
                onResume={(sessionId) => harness.restart(sessionId, false)}
              />
            ) : null
          }
          footer={
            <>
              {permissionPane}
              {model.runPhase === "exited" && model.turns.length > 0 ? (
                <ExitedState
                  error={model.exitError}
                  startFailed={model.startFailed}
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
        <StatusStrip
          model={model}
          runPhase={model.runPhase}
          activity={model.activity}
          cliUnavailable={cliUnavailable}
          onRestart={() => harness.restart()}
        />
        <Composer
          disabled={cliUnavailable}
          running={running}
          awaitingPermission={model.pending.length > 0}
          planPending={planPending}
          onPlanImplement={() => decidePlan()}
          onPlanRefine={(text) => decidePlan(text)}
          onPlanKeepPlanning={() =>
            decidePlan(copy("supermux.harness.plan.keepPlanningMessage"))
          }
          queued={model.queued}
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
    </div>
  );
}

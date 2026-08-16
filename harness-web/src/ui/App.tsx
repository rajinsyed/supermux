import { useCallback, useEffect, useMemo, useRef } from "react";
import type { HarnessStore } from "../model/store";
import type { ImageAttachment } from "../model/types";
import { CopyProvider } from "./CopyContext";
import { Composer } from "./composer/Composer";
import { EmptyState, ExitedState, NoCliState } from "./empty/EmptyStates";
import { Header } from "./header/Header";
import { PermissionCard, type PermissionDecision } from "./permission/PermissionCard";
import { PlanCard } from "./permission/PlanCard";
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
  const { model, theme, context } = harness;
  const notifiedTurns = useRef(0);

  useEffect(() => {
    applyThemeVariables(document.documentElement, theme);
  }, [theme]);

  const { ref: scrollRef, showPill, scrollToBottom } = useScrollFollow([
    model.revision,
    model.turns.length,
    model.pending.length
  ]);

  useEffect(() => {
    const settled = model.turns.filter((turn) => turn.state !== "streaming").length;
    if (settled > notifiedTurns.current && notifiedTurns.current > 0 && document.hidden) {
      harness.bridge
        .notify({ title: "Claude", body: model.session.title ?? "Turn complete" })
        .catch(() => undefined);
    }
    notifiedTurns.current = settled;
  }, [harness.bridge, model.session.title, model.turns]);

  useEffect(() => {
    if (model.pending.length === 0 || !document.hidden) return;
    harness.bridge
      .notify({ title: "Claude", body: "Permission needed" })
      .catch(() => undefined);
  }, [harness.bridge, model.pending.length]);

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
    <CopyProvider dict={context?.copy}>
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
            const markdown = exportTranscript(model);
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
                  <ExitedState error={model.exitError} onRestart={() => harness.restart()} />
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
            onRestart={() => harness.restart()}
          />
          <Composer
            disabled={cliUnavailable}
            running={running}
            awaitingPermission={model.pending.length > 0}
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
    </CopyProvider>
  );
}

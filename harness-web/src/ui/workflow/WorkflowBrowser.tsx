import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getBridge } from "../../bridge";
import type { WorkflowAgent } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ArrowLeft, ChevronDown, ChevronRight, Cpu, Map as MapIcon, Stop } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { AgentDetail } from "./AgentDetail";
import {
  agentAt,
  ascend,
  descend,
  displayState,
  groupAt,
  moveSelection,
  normalizeSelection,
  phaseGroups,
  workflowInterrupted,
  workflowStopped,
  type Selection
} from "./browserModel";
import { STATE_LABELS } from "./state";
import type { WorkflowSubject } from "./subject";

/**
 * The multi-pane workflow browser: the CLI's own information design — header,
 * phases column, phase agent list, agent detail — rendered in the pane's own
 * tokens rather than as terminal cosplay.
 *
 * It replaces the inline WorkflowCard, which grew to 643px of nested
 * disclosures inside the transcript. The transcript now keeps a one-line row
 * that opens this; everything the card used to hold lives here, where it has
 * room and a keyboard.
 */
export function WorkflowBrowser({
  subject,
  onClose,
  onOpenAgentChat
}: {
  subject: WorkflowSubject;
  /** Esc at the top level, and the back affordance in the header. */
  onClose(): void;
  /**
   * The view router's agent-chat entry, answering false when this agent has no
   * thread to route to. The detail pane then opens the agent's disk transcript
   * in place instead.
   */
  onOpenAgentChat?(target: { workflowRunId?: string; agentId?: string; label?: string }): boolean;
}) {
  const copy = useCopy();
  const [selection, setSelection] = useState<Selection | undefined>(undefined);
  const [stopping, setStopping] = useState(false);
  const [stopFailed, setStopFailed] = useState(false);
  const [openLogs, setOpenLogs] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const logs = subject.workflow?.logs ?? [];

  const groups = useMemo(() => phaseGroups(subject.workflow), [subject.workflow]);
  // Re-derived on every render rather than stored: the workflow advances under
  // the reader, and a selection is only ever as valid as the current snapshot.
  const current = normalizeSelection(groups, selection);
  const group = groupAt(groups, current);
  const agent = agentAt(groups, current);

  const totals = subject.workflow?.totals;
  const interrupted = workflowInterrupted(subject.status);
  const stopped = workflowStopped(subject.status);
  const running = !interrupted;

  const stop = useCallback(() => {
    const taskId = subject.taskId;
    if (!taskId) return;
    setStopping(true);
    setStopFailed(false);
    getBridge()
      .stopTask({ taskId })
      .catch(() => setStopFailed(true))
      .finally(() => setStopping(false));
  }, [subject.taskId]);

  /**
   * The footer's hints are REAL bindings, handled here rather than globally: the
   * browser is a focusable region, so ↑↓ and x belong to it only while the
   * reader is in it and Escape-to-interrupt stays the composer's everywhere
   * else.
   */
  const onKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        setSelection((value) => moveSelection(groups, value, event.key === "ArrowDown" ? 1 : -1));
        return;
      }
      if (event.key === "ArrowRight" || event.key === "Enter") {
        event.preventDefault();
        setSelection((value) => descend(groups, value));
        return;
      }
      if (event.key === "Escape" || event.key === "ArrowLeft") {
        event.preventDefault();
        event.stopPropagation();
        setSelection((value) => {
          const normalized = normalizeSelection(groups, value);
          const next = ascend(normalized);
          // Nothing left to step out of: Escape leaves the browser entirely.
          if (next === undefined) onClose();
          return next;
        });
        return;
      }
      if ((event.key === "x" || event.key === "X") && running && subject.taskId) {
        event.preventDefault();
        stop();
      }
    },
    [groups, onClose, running, stop, subject.taskId]
  );

  // The keys only work where focus is, so the browser takes it on open — the
  // same contract Modal keeps.
  useEffect(() => {
    root.current?.focus();
  }, []);

  const summary: string[] = [];
  if (stopped) {
    // An interruption reads as the deliberate act it was: when it happened,
    // then how much of the run it caught. The partial counts stay as the honest
    // record rather than being rounded up into a finish.
    summary.push(
      subject.durationMs
        ? copy("supermux.harness.workflow.stoppedAfter", {
            duration: formatCompactDuration(subject.durationMs, copy)
          })
        : copy("supermux.harness.workflow.stopped")
    );
    if (totals && totals.agents > 0) {
      summary.push(
        copy(
          totals.agents === 1
            ? "supermux.harness.workflow.agentsFinishedOne"
            : "supermux.harness.workflow.agentsFinished",
          { done: totals.done, total: totals.agents }
        )
      );
    }
  } else if (totals && totals.agents > 0) {
    summary.push(
      copy("supermux.harness.workflow.browser.agentCount", {
        done: totals.done,
        total: totals.agents
      })
    );
  }
  if (subject.workflow && subject.workflow.phases.length > 0) {
    summary.push(
      plural(
        copy,
        subject.workflow.phases.length,
        "supermux.harness.workflow.phasesOne",
        "supermux.harness.workflow.phases"
      )
    );
  }
  if (totals?.tokens) {
    summary.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(totals.tokens) }));
  }
  // The stopped branch already said how long the run lasted, in the sentence
  // that explains why it ended.
  if (!running && !stopped && subject.durationMs) {
    summary.push(formatCompactDuration(subject.durationMs, copy));
  }

  return (
    <div
      className="wf-browser"
      ref={root}
      tabIndex={-1}
      onKeyDown={onKeyDown}
      role="region"
      aria-label={copy("supermux.harness.workflow.browser.title")}
    >
      <header className="wfb-head">
        <button
          type="button"
          className="icon-btn wfb-back"
          onClick={onClose}
          aria-label={copy("supermux.harness.workflow.browser.back")}
        >
          <ArrowLeft size={12} />
        </button>
        <span className="wfb-icon">
          <MapIcon size={13} />
        </span>
        <span className="wfb-identity">
          <span className="wfb-name">
            {subject.name ?? copy("supermux.harness.workflow.untitled")}
          </span>
          {subject.description && subject.description !== subject.name ? (
            <span className="wfb-desc" title={subject.description}>
              {subject.description}
            </span>
          ) : null}
        </span>
        {summary.length > 0 ? <span className="wfb-summary tnum">{summary.join(" · ")}</span> : null}
        {running ? (
          <>
            {subject.startedAtMs ? (
              <Elapsed className="wfb-elapsed tnum" startedAtMs={subject.startedAtMs} />
            ) : null}
            <Spinner size={12} />
          </>
        ) : stopped ? (
          <span className="wf-stopped-chip">
            <Stop size={9} />
            {copy("supermux.harness.workflow.stopped")}
          </span>
        ) : null}
      </header>

      {stopFailed ? <div className="wf-error">{copy("supermux.harness.workflow.stopFailed")}</div> : null}

      <div className="wfb-panes">
        <nav className="wfb-phases" aria-label={copy("supermux.harness.workflow.browser.phases")}>
          <h2 className="wfb-col-title">{copy("supermux.harness.workflow.browser.phases")}</h2>
          {groups.length === 0 ? (
            <p className="wfb-empty">
              {running
                ? copy("supermux.harness.workflow.starting")
                : copy("supermux.harness.workflow.noAgents")}
            </p>
          ) : (
            <ul className="wfb-phase-list">
              {groups.map((entry) => {
                const active = current?.phaseKey === entry.key;
                return (
                  <li key={entry.key}>
                    <button
                      type="button"
                      className={`wfb-phase-row${active ? " is-active" : ""}${
                        entry.running > 0 ? " is-running" : ""
                      }`}
                      aria-current={active ? "true" : undefined}
                      onClick={() => setSelection({ phaseKey: entry.key })}
                    >
                      {entry.index !== undefined ? (
                        <span className="wfb-phase-index tnum">{entry.index}</span>
                      ) : (
                        <span className="wfb-phase-index" />
                      )}
                      <span className="wfb-phase-title">
                        {entry.title ?? copy("supermux.harness.workflow.unphased")}
                      </span>
                      <span className="wfb-phase-count tnum">
                        {entry.total === 0
                          ? copy("supermux.harness.workflow.phasePending")
                          : copy("supermux.harness.workflow.progress", {
                              done: entry.done,
                              total: entry.total
                            })}
                      </span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </nav>

        <div className="wfb-right">
          {agent ? (
            <AgentDetail
              agent={agent}
              runId={subject.runId}
              interrupted={interrupted}
              progressTick={subject.progressTick}
              onOpenAgentChat={onOpenAgentChat}
            />
          ) : (
            <>
              {/* Which phase the right pane is showing. On a narrow split the
                  phases column is a band the reader has scrolled past, and
                  without this the agent list is a list of names belonging to
                  nothing. */}
              <h2 className="wfb-col-title">
                {group?.title ?? copy("supermux.harness.workflow.unphased")}
                {group && group.total > 0 ? (
                  <span className="wfb-col-count tnum">
                    {plural(
                      copy,
                      group.total,
                      "supermux.harness.workflow.agentsOne",
                      "supermux.harness.workflow.agents"
                    )}
                  </span>
                ) : null}
              </h2>
              <AgentList
                agents={group?.agents ?? []}
                interrupted={interrupted}
                onSelect={(index) =>
                  setSelection({ phaseKey: group?.key ?? current?.phaseKey ?? "", agentIndex: index })
                }
              />
            </>
          )}
        </div>
      </div>

      {logs.length > 0 ? (
        <div className="wfb-logs-block">
          <button
            type="button"
            className="wf-logs-toggle"
            onClick={() => setOpenLogs((value) => !value)}
            aria-expanded={openLogs}
          >
            {openLogs ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
            {openLogs
              ? copy("supermux.harness.workflow.hideLogs")
              : plural(
                  copy,
                  logs.length,
                  "supermux.harness.workflow.showLogsOne",
                  "supermux.harness.workflow.showLogs"
                )}
          </button>
          <Disclosure open={openLogs} keepMounted>
            <ol className="wf-logs mono">
              {logs.map((line, i) => (
                <li key={`${i}:${line}`}>{line}</li>
              ))}
            </ol>
          </Disclosure>
        </div>
      ) : null}

      <footer className="wfb-hints">
        <span className="wfb-hint">
          <kbd className="btn-kbd">↑↓</kbd>
          {copy("supermux.harness.workflow.browser.hintSelect")}
        </span>
        {running && subject.taskId ? (
          <button type="button" className="wfb-hint is-action" onClick={stop} disabled={stopping}>
            <kbd className="btn-kbd">x</kbd>
            {stopping
              ? copy("supermux.harness.workflow.stopping")
              : copy("supermux.harness.workflow.stop")}
          </button>
        ) : null}
        <button
          type="button"
          className="wfb-hint is-action"
          onClick={() => {
            const next = ascend(current);
            if (next === undefined) onClose();
            else setSelection(next);
          }}
        >
          <kbd className="btn-kbd">esc</kbd>
          {copy("supermux.harness.workflow.browser.hintBack")}
        </button>
      </footer>
    </div>
  );
}

function AgentList({
  agents,
  interrupted,
  onSelect
}: {
  agents: WorkflowAgent[];
  interrupted: boolean;
  onSelect(index: number): void;
}) {
  const copy = useCopy();
  if (agents.length === 0) {
    return <p className="wfb-empty">{copy("supermux.harness.workflow.phasePending")}</p>;
  }
  return (
    <ul className="wfb-agent-list">
      {agents.map((agent) => {
        const state = displayState(agent, interrupted);
        return (
          <li key={agent.index}>
            <button type="button" className="wfb-agent-row" onClick={() => onSelect(agent.index)}>
              <span className={`wfb-dot is-${state}`} aria-hidden="true" />
              <span className="wfb-agent-label" title={agent.promptPreview}>
                {agent.label}
              </span>
              <span className="sr-only">
                {state === "stopped"
                  ? copy("supermux.harness.workflow.stopped")
                  : copy(STATE_LABELS[agent.state])}
              </span>
              {agent.model ? (
                <span className="subagent-model" title={agent.fallbackModel ?? agent.model}>
                  <Cpu size={9} />
                  <span className="subagent-model-name">{agent.model}</span>
                </span>
              ) : null}
              <span className="wfb-agent-tokens tnum">
                {agent.tokens ? formatTokens(agent.tokens) : ""}
              </span>
              {state === "running" && agent.startedAt ? (
                <Elapsed className="wfb-agent-elapsed tnum" startedAtMs={agent.startedAt} />
              ) : (
                <span className="wfb-agent-elapsed tnum">
                  {agent.durationMs ? formatCompactDuration(agent.durationMs, copy) : ""}
                </span>
              )}
            </button>
          </li>
        );
      })}
    </ul>
  );
}

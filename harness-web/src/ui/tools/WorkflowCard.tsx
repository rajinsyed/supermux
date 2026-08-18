import { memo, useState } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
import { workStartedAtMs } from "../../model/tasks";
import type { ToolBlock, WorkflowAgent, WorkflowAgentState } from "../../model/types";
import { groupByPhase } from "../../model/workflow";
import { plural, useCopy } from "../CopyContext";
import {
  AlertTriangle,
  CheckCircle,
  ChevronDown,
  ChevronRight,
  Cpu,
  Clock,
  Folder,
  Map as MapIcon,
  Stop
} from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { useDismissible } from "../primitives/useDismissible";
import { useFoldHold } from "../transcript/foldGuard";
import { SubagentTranscriptView } from "./SubagentTranscript";

/** One vocabulary for an agent's state, wherever the agent is rendered. */
export const STATE_LABELS: Record<WorkflowAgentState, CopyKey> = {
  queued: "supermux.harness.workflow.state.queued",
  running: "supermux.harness.workflow.state.running",
  done: "supermux.harness.workflow.state.done",
  error: "supermux.harness.workflow.state.error",
  blocked: "supermux.harness.workflow.state.blocked",
  cached: "supermux.harness.workflow.state.cached"
};

function AgentRow({
  agent,
  runId,
  tick,
  interrupted = false
}: {
  agent: WorkflowAgent;
  runId?: string;
  /** Progress counter; a drill-in open on a running agent re-fetches on it. */
  tick?: number;
  /**
   * The workflow was stopped (or otherwise settled) with this agent still
   * mid-run. Its last progress frame says "running" forever — no further frame
   * will ever demote it — so the row freezes: stopped chip, no spinner, no
   * climbing elapsed on work that is already dead.
   */
  interrupted?: boolean;
}) {
  const copy = useCopy();
  const [openResult, setOpenResult] = useState(false);
  const [openDrill, setOpenDrill] = useState(false);
  // Escape closes the drill-in the reader is in — the same contract the Bash
  // card's output tail and the strip's detail keep — instead of falling through
  // to the composer and interrupting the turn they are inspecting.
  const scope = useDismissible(openDrill, () => setOpenDrill(false));
  // An open drill-in is the reader's place in this turn; the turn must not fold
  // itself away around it when the workflow settles.
  useFoldHold(openDrill || openResult);
  const running = agent.state === "running" && !interrupted;
  const stoppedMidRun = agent.state === "running" && interrupted;
  const detail = agent.error ?? agent.resultPreview;
  const canDrill = runId !== undefined && agent.agentId !== undefined;

  const metrics: string[] = [];
  if (agent.tokens) metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(agent.tokens) }));
  if (agent.toolCalls) {
    metrics.push(
      plural(
        copy,
        agent.toolCalls,
        "supermux.harness.subagent.toolUsesOne",
        "supermux.harness.subagent.toolUses"
      )
    );
  }
  if (!running && agent.durationMs) metrics.push(formatCompactDuration(agent.durationMs, copy));

  // While it runs the CLI reports what the agent is doing right now; when it is
  // done that line is replaced by what it produced.
  const live = running
    ? agent.lastToolSummary ?? agent.lastToolName ?? agent.promptPreview
    : agent.state === "queued"
      ? agent.promptPreview
      : undefined;

  return (
    <li className={`wf-agent is-${agent.state}`} ref={scope as React.RefObject<HTMLLIElement>}>
      <div className="wf-agent-head">
        <span className={`wf-state is-${stoppedMidRun ? "stopped" : agent.state}`}>
          {running ? <Spinner size={9} /> : null}
          {/* The same stop glyph the card header wears: "I killed this at 3s"
              and "this was never dispatched" must be one glance apart, not one
              alpha value apart. */}
          {stoppedMidRun ? <Stop size={8} /> : null}
          {stoppedMidRun
            ? copy("supermux.harness.workflow.stopped")
            : copy(STATE_LABELS[agent.state])}
        </span>
        <span className="wf-agent-label" title={agent.promptPreview}>
          {agent.label}
        </span>
        <span className="wf-agent-chips">
          {agent.isolation ? (
            <span className="tool-badge is-quiet">
              <Folder size={9} />
              {copy(
                agent.isolation === "remote"
                  ? "supermux.harness.workflow.isolationRemote"
                  : "supermux.harness.workflow.isolationWorktree"
              )}
            </span>
          ) : null}
          {agent.attempt !== undefined && agent.attempt > 1 ? (
            <span
              className="tool-badge is-warn tnum"
              title={agent.lastAttemptReason}
            >
              {copy("supermux.harness.workflow.attempt", { count: agent.attempt })}
            </span>
          ) : null}
          {agent.model ? (
            <span className="subagent-model" title={agent.fallbackModel ?? agent.model}>
              <Cpu size={9} />
              <span className="subagent-model-name">{agent.model}</span>
            </span>
          ) : null}
        </span>
        {metrics.length > 0 ? <span className="wf-agent-metrics tnum">{metrics.join(" · ")}</span> : null}
        {running && agent.startedAt ? (
          <Elapsed className="wf-agent-elapsed tnum" startedAtMs={agent.startedAt} />
        ) : null}
      </div>
      {live ? <div className="wf-agent-live">{live}</div> : null}
      {detail ? (
        <>
          <button
            type="button"
            className="wf-agent-toggle"
            onClick={() => setOpenResult((v) => !v)}
            aria-expanded={openResult}
          >
            {openResult ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
            {openResult
              ? copy("supermux.harness.workflow.hideResult")
              : copy("supermux.harness.workflow.showResult")}
          </button>
          <Disclosure open={openResult}>
            <div className={`wf-agent-result${agent.error ? " is-error" : ""}`}>{detail}</div>
          </Disclosure>
        </>
      ) : null}
      {canDrill ? (
        <>
          <button
            type="button"
            className="wf-agent-toggle"
            onClick={() => setOpenDrill((v) => !v)}
            aria-expanded={openDrill}
          >
            {openDrill ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
            {openDrill
              ? copy("supermux.harness.subagent.closeTranscript")
              : copy("supermux.harness.workflow.openAgent")}
          </button>
          <Disclosure open={openDrill} className="subagent-drill">
            <SubagentTranscriptView
              target={{ workflowRunId: runId, agentId: agent.agentId }}
              label={agent.label}
              open={openDrill}
              tick={running ? tick : undefined}
            />
          </Disclosure>
        </>
      ) : null}
    </li>
  );
}

export const WorkflowCard = memo(function WorkflowCard({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const workflow = block.workflow;
  const info = block.subagent ?? {};
  const [openLogs, setOpenLogs] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [stopError, setStopError] = useState(false);
  /**
   * Every other card in the pane folds from its head; this one was 643px of
   * phases with no way to put it away, which is a lot of transcript to scroll
   * past on a run you have finished reading. Undefined means "follow the run":
   * open while it matters, and the reader's own click pins it either way.
   */
  const [openOverride, setOpenOverride] = useState<boolean | undefined>(undefined);
  // A hand-opened body is the reader's place, and so is an open log strip.
  useFoldHold(openOverride === true || openLogs);

  const name =
    workflow?.name ??
    info.workflowName ??
    (block.input.name as string) ??
    copy("supermux.harness.workflow.untitled");
  const status = info.status ?? workflow?.status;
  // Three distinct ends, not two: `killed`/`stopped` is the user interrupting
  // the run (the CLI's kill sequence ends with a `stopped` notification), and a
  // green check on a workflow the user just killed congratulates them on the
  // wrong thing. The partial totals ("0 of 2 done") stay as the honest record.
  const stopped = status === "killed" || status === "stopped";
  const finished = status === "completed" || status === "failed" || stopped;
  const failed = status === "failed" || (workflow?.totals.failed ?? 0) > 0;
  const runId = info.workflowRunId ?? workflow?.runId;
  const taskId = info.taskId;

  const groups = workflow ? groupByPhase(workflow) : [];
  const totals = workflow?.totals;

  const stop = () => {
    if (!taskId) return;
    setStopping(true);
    setStopError(false);
    getBridge()
      .stopTask({ taskId })
      .catch(() => setStopError(true))
      .finally(() => setStopping(false));
  };

  const summary: string[] = [];
  if (stopped) {
    // An interruption reads as the deliberate act it was: when it happened,
    // then how much of the run it caught — more useful than either pretending
    // the run finished or pretending it never ran.
    summary.push(
      info.durationMs
        ? copy("supermux.harness.workflow.stoppedAfter", {
            duration: formatCompactDuration(info.durationMs, copy)
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
  } else {
    if (workflow && workflow.phases.length > 0) {
      summary.push(
        plural(
          copy,
          workflow.phases.length,
          "supermux.harness.workflow.phasesOne",
          "supermux.harness.workflow.phases"
        )
      );
    }
    if (totals && totals.agents > 0) {
      summary.push(copy("supermux.harness.workflow.progress", { done: totals.done, total: totals.agents }));
    }
    if (info.durationMs && finished) summary.push(formatCompactDuration(info.durationMs, copy));
  }
  if (totals?.tokens) {
    summary.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(totals.tokens) }));
  }

  /**
   * Collapsed means the phase list is gone; the head stays exactly as it is.
   *
   * That is the whole one-line summary the fold needs — the head already reads
   * "alpha-beta-demo · Workflow · <description> · 2 phases · 3 of 3 done · 5s ·
   * 50k tokens" plus its outcome chip. A second line under it repeating agents
   * and tokens was the same duplication finding 7 is about, in a new place.
   */
  const open = openOverride ?? true;

  return (
    <div
      className={`workflow-card${open ? " is-open" : ""}${
        failed ? " is-error" : stopped ? " is-stopped" : finished ? " is-done" : " is-running"
      }`}
    >
      <div className="wf-head">
        {/* The fold affordance every other card in the pane has. It is the icon
            slot rather than a fourth control on the right: the map glyph was
            decoration, and a caret in its place makes the whole head read as
            the clickable thing it now is. */}
        <button
          type="button"
          className="wf-fold"
          onClick={() => setOpenOverride(!open)}
          aria-expanded={open}
          aria-label={copy(
            open
              ? "supermux.harness.workflow.collapse"
              : "supermux.harness.workflow.expand"
          )}
        >
          <span className="wf-caret" aria-hidden="true">
            {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          </span>
          <span className="wf-icon">
            <MapIcon size={13} />
          </span>
        </button>
        <span className="wf-identity">
          <span className="wf-name">{name}</span>
          <span className="wf-meta">
            <span className="tool-badge is-quiet">{copy("supermux.harness.workflow.badge")}</span>
            {info.description && info.description !== name ? (
              <span className="wf-desc" title={info.description}>
                {info.description}
              </span>
            ) : null}
            {summary.length > 0 ? <span className="tnum">{summary.join(" · ")}</span> : null}
          </span>
        </span>
        {finished ? (
          failed ? (
            <AlertTriangle size={13} className="mark-warn" />
          ) : stopped ? (
            <span className="wf-stopped-chip">
              <Stop size={9} />
              {copy("supermux.harness.workflow.stopped")}
            </span>
          ) : (
            <CheckCircle size={13} className="mark-ok" />
          )
        ) : (
          <>
            {/* The TASK's clock, not the block's: the strip row for this same
                run counts from the record, and two labels for one workflow
                disagreeing by a second is a bug the reader can see. */}
            <Elapsed className="tool-elapsed tnum" startedAtMs={workStartedAtMs(block)} />
            <Spinner size={12} />
            {taskId ? (
              <button
                type="button"
                className="btn btn-quiet wf-stop"
                onClick={stop}
                disabled={stopping}
              >
                <Stop size={10} />
                {stopping
                  ? copy("supermux.harness.workflow.stopping")
                  : copy("supermux.harness.workflow.stop")}
              </button>
            ) : null}
          </>
        )}
      </div>
      {stopError ? (
        <div className="wf-error">{copy("supermux.harness.workflow.stopFailed")}</div>
      ) : null}

      {/* `keepMounted`, so collapsing a card is never destructive: an open log
          strip, an open drill-in and its scroll position are all exactly where
          they were when the reader opens it again. */}
      <Disclosure open={open} keepMounted className="wf-body">
        {!workflow || groups.length === 0 ? (
          <div className="wf-empty">
            {finished
              ? copy("supermux.harness.workflow.noAgents")
              : copy("supermux.harness.workflow.starting")}
          </div>
        ) : (
          <div className="wf-phases">
            {groups.map((group, index) => (
              <section className="wf-phase" key={group.phase?.index ?? `loose-${index}`}>
                <header className="wf-phase-head">
                  <span className="wf-phase-title">
                    {group.phase?.title ?? copy("supermux.harness.workflow.unphased")}
                  </span>
                  {/* A phase the script has declared but not reached yet has no
                      agents to count, and "0 agents" reads as a phase that ran
                      empty rather than one that has not started. */}
                  <span className="wf-phase-count tnum">
                    {group.agents.length === 0
                      ? copy("supermux.harness.workflow.phasePending")
                      : plural(
                          copy,
                          group.agents.length,
                          "supermux.harness.workflow.agentsOne",
                          "supermux.harness.workflow.agents"
                        )}
                  </span>
                </header>
                {group.agents.length > 0 ? (
                  <ul className="wf-agents">
                    {group.agents.map((agent) => (
                      <AgentRow
                        key={agent.index}
                        agent={agent}
                        runId={runId}
                        tick={info.progressTick}
                        interrupted={finished}
                      />
                    ))}
                  </ul>
                ) : null}
              </section>
            ))}
          </div>
        )}

        {workflow && workflow.logs.length > 0 ? (
          <>
            <button
              type="button"
              className="wf-logs-toggle"
              onClick={() => setOpenLogs((v) => !v)}
              aria-expanded={openLogs}
            >
              {openLogs ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
              <Clock size={10} />
              {openLogs
                ? copy("supermux.harness.workflow.hideLogs")
                : plural(
                    copy,
                    workflow.logs.length,
                    "supermux.harness.workflow.showLogsOne",
                    "supermux.harness.workflow.showLogs"
                  )}
            </button>
            <Disclosure open={openLogs}>
              <ol className="wf-logs mono">
                {workflow.logs.map((line, i) => (
                  <li key={`${i}:${line}`}>{line}</li>
                ))}
              </ol>
            </Disclosure>
          </>
        ) : null}
      </Disclosure>
    </div>
  );
});

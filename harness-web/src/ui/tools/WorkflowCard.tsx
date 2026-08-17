import { memo, useState } from "react";
import { getBridge } from "../../bridge";
import type { CopyKey } from "../../copyKeys";
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
import { SubagentTranscriptView } from "./SubagentTranscript";

const STATE_LABELS: Record<WorkflowAgentState, CopyKey> = {
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
  tick
}: {
  agent: WorkflowAgent;
  runId?: string;
  /** Progress counter; a drill-in open on a running agent re-fetches on it. */
  tick?: number;
}) {
  const copy = useCopy();
  const [openResult, setOpenResult] = useState(false);
  const [openDrill, setOpenDrill] = useState(false);
  const running = agent.state === "running";
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
    <li className={`wf-agent is-${agent.state}`}>
      <div className="wf-agent-head">
        <span className={`wf-state is-${agent.state}`}>
          {running ? <Spinner size={9} /> : null}
          {copy(STATE_LABELS[agent.state])}
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
              {agent.model}
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

  const name =
    workflow?.name ??
    info.workflowName ??
    (block.input.name as string) ??
    copy("supermux.harness.workflow.untitled");
  const status = info.status ?? workflow?.status;
  const finished = status === "completed" || status === "failed" || status === "killed";
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
  if (totals?.tokens) {
    summary.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(totals.tokens) }));
  }
  if (info.durationMs && finished) summary.push(formatCompactDuration(info.durationMs, copy));

  return (
    <div className={`workflow-card${failed ? " is-error" : finished ? " is-done" : " is-running"}`}>
      <div className="wf-head">
        <span className="wf-icon">
          <MapIcon size={13} />
        </span>
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
          ) : (
            <CheckCircle size={13} className="mark-ok" />
          )
        ) : (
          <>
            <Elapsed className="tool-elapsed tnum" startedAtMs={block.startedAtMs} />
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
    </div>
  );
});

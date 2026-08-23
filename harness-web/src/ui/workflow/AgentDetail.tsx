import { useState } from "react";
import type { WorkflowAgent } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import {
  AlertTriangle,
  CheckCircle,
  ChevronDown,
  ChevronRight,
  Cpu,
  Folder,
  Refresh,
  Stop
} from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Disclosure } from "../primitives/Disclosure";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner, WorkingGlyph } from "../primitives/Spinner";
import { SubagentTranscriptView } from "../tools/SubagentTranscript";
import { displayState, type DisplayState } from "./browserModel";
import { STATE_LABELS } from "./state";
import { useAgentDocument, type DocumentState } from "./useAgentDocument";

/**
 * One expandable text section of the detail pane.
 *
 * Both the prompt and the outcome arrive twice: a truncated preview on every
 * `workflow_progress` frame, and the full text in the agent's own file on disk.
 * The preview renders immediately and the expansion is a bridge read, so the
 * pane costs nothing until a reader actually asks for the whole thing.
 */
function TextSection({
  title,
  preview,
  full,
  document,
  open,
  onToggle,
  tone
}: {
  title: string;
  preview?: string;
  full?: string;
  document: DocumentState & { reload(): void };
  open: boolean;
  onToggle(): void;
  tone?: "error";
}) {
  const copy = useCopy();
  if (!preview && !full && document.phase !== "ready") return null;
  const expandable = preview !== undefined;
  const body = open && full !== undefined ? full : preview ?? full;

  return (
    <section className={`wfb-section${tone === "error" ? " is-error" : ""}`}>
      <header className="wfb-section-head">
        <h3 className="wfb-section-title">{title}</h3>
        {expandable ? (
          <button type="button" className="wfb-expand" onClick={onToggle} aria-expanded={open}>
            {open ? <ChevronDown size={10} /> : <ChevronRight size={10} />}
            {open
              ? copy("supermux.harness.workflow.browser.collapse")
              : copy("supermux.harness.workflow.browser.expand")}
          </button>
        ) : null}
      </header>
      <p className="wfb-section-body">{body}</p>
      {open ? (
        document.phase === "loading" ? (
          <div className="wfb-section-note">
            <Spinner size={10} />
            {copy("supermux.harness.workflow.browser.loadingFull")}
          </div>
        ) : document.phase === "missing" ? (
          <div className="wfb-section-note">
            {copy("supermux.harness.workflow.browser.fullMissing")}
            <button type="button" className="link-btn" onClick={document.reload}>
              <Refresh size={10} />
              {copy("supermux.harness.workflow.browser.retry")}
            </button>
          </div>
        ) : document.phase === "failed" ? (
          <div className="wfb-section-note is-error">
            {copy("supermux.harness.workflow.browser.fullFailed")}
            <button type="button" className="link-btn" onClick={document.reload}>
              <Refresh size={10} />
              {copy("supermux.harness.workflow.browser.retry")}
            </button>
          </div>
        ) : document.truncated ? (
          <div className="wfb-section-note">
            {copy("supermux.harness.workflow.browser.truncated")}
          </div>
        ) : null
      ) : null}
    </section>
  );
}

/**
 * The state chip's leading mark.
 *
 * RUNNING is the one that changed in round 7: it was the orbit, which the
 * loading family reserves for "one request is in flight and the pane is waiting
 * on its answer". A workflow agent is none of those — it is delegated work off
 * doing its own thing — so it takes the delegated mark, the same comet the
 * transcript's agent rows, the dock rows and the agent list beside this pane
 * already wear. Every settled state keeps its own glyph.
 *
 * The chip is sized once at its widest state (`.wfb-state`, asserted in
 * tests/styles.test.ts), and the grid is the same 11px box the orbit was, so
 * the swap costs the chip nothing.
 */
function StateMark({ state }: { state: DisplayState }) {
  if (state === "running") return <WorkingGlyph variant="orbit" className="wfb-mark" />;
  if (state === "error") return <AlertTriangle size={12} className="mark-warn" />;
  if (state === "stopped") return <Stop size={10} />;
  if (state === "done" || state === "cached") return <CheckCircle size={12} className="mark-ok" />;
  return <span className={`wfb-mark wfb-dot is-${state}`} aria-hidden="true" />;
}

/**
 * The third pane of the browser: everything the CLI shows about ONE workflow
 * agent — its state and model, its metrics, the prompt it was given, what it is
 * doing right now, and what it produced.
 */
export function AgentDetail({
  agent,
  runId,
  interrupted,
  progressTick,
  onOpenAgentChat
}: {
  agent: WorkflowAgent;
  runId?: string;
  /** The workflow itself has ended, so a `running` agent is frozen, not live. */
  interrupted: boolean;
  progressTick?: number;
  /**
   * The router's agent-chat entry. It answers FALSE when this agent has no
   * thread to route to — a workflow agent never appears on the wire as an Agent
   * tool call, so most of them do not — and the disk-backed inline transcript
   * takes over. The affordance is therefore never a button that does nothing.
   */
  onOpenAgentChat?(target: { workflowRunId?: string; agentId?: string; label?: string }): boolean;
}) {
  const copy = useCopy();
  const [openPrompt, setOpenPrompt] = useState(false);
  const [openOutcome, setOpenOutcome] = useState(false);
  /** The inline fallback for a build whose agent-chat router has not landed. */
  const [openInline, setOpenInline] = useState(false);
  const state = displayState(agent, interrupted);
  const running = state === "running";
  const document = useAgentDocument(
    { workflowRunId: runId, agentId: agent.agentId },
    openPrompt || openOutcome,
    running ? progressTick : undefined
  );

  const metrics: string[] = [];
  if (agent.tokens) {
    metrics.push(copy("supermux.harness.subagent.tokens", { tokens: formatTokens(agent.tokens) }));
  }
  if (agent.toolCalls !== undefined) {
    metrics.push(
      plural(
        copy,
        agent.toolCalls,
        "supermux.harness.workflow.browser.toolCallsOne",
        "supermux.harness.workflow.browser.toolCalls"
      )
    );
  }
  if (agent.durationMs) metrics.push(formatCompactDuration(agent.durationMs, copy));

  const activity = agent.lastToolSummary ?? agent.lastToolName;
  const canOpen = runId !== undefined && agent.agentId !== undefined;

  return (
    <div className="wfb-detail">
      <div className="wfb-detail-head">
        <span className={`wfb-state is-${state}`}>
          <StateMark state={state} />
          {state === "stopped"
            ? copy("supermux.harness.workflow.stopped")
            : copy(STATE_LABELS[agent.state])}
        </span>
        <span className="wfb-detail-name" title={agent.label}>
          {agent.label}
        </span>
        {agent.model ? (
          <span className="subagent-model" title={agent.fallbackModel ?? agent.model}>
            <Cpu size={9} />
            <span className="subagent-model-name">{agent.model}</span>
          </span>
        ) : null}
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
          <span className="tool-badge is-warn tnum" title={agent.lastAttemptReason}>
            {copy("supermux.harness.workflow.attempt", { count: agent.attempt })}
          </span>
        ) : null}
        {agent.cached ? (
          <span className="tool-badge is-quiet">
            {copy("supermux.harness.workflow.browser.cachedBadge")}
          </span>
        ) : null}
        {running && agent.startedAt ? (
          <Elapsed className="wfb-detail-elapsed tnum" startedAtMs={agent.startedAt} />
        ) : null}
      </div>

      {metrics.length > 0 ? (
        <div className="wfb-detail-metrics tnum">{metrics.join(" · ")}</div>
      ) : null}

      <TextSection
        title={copy("supermux.harness.workflow.browser.prompt")}
        preview={agent.promptPreview}
        full={document.prompt}
        document={document}
        open={openPrompt}
        onToggle={() => setOpenPrompt((value) => !value)}
      />

      <section className="wfb-section">
        <header className="wfb-section-head">
          <h3 className="wfb-section-title">{copy("supermux.harness.workflow.browser.activity")}</h3>
        </header>
        <p className="wfb-section-body is-activity">
          {activity ?? copy("supermux.harness.workflow.browser.noActivity")}
        </p>
      </section>

      {agent.error ? (
        <TextSection
          title={copy("supermux.harness.workflow.browser.outcome")}
          preview={agent.error}
          document={document}
          open={false}
          onToggle={() => undefined}
          tone="error"
        />
      ) : (
        <TextSection
          title={copy("supermux.harness.workflow.browser.outcome")}
          preview={agent.resultPreview}
          full={document.outcome}
          document={document}
          open={openOutcome}
          onToggle={() => setOpenOutcome((value) => !value)}
        />
      )}

      {canOpen ? (
        <div className="wfb-detail-actions">
          <button
            type="button"
            className="btn btn-quiet wfb-open-chat"
            onClick={() => {
              // The router first: an agent with a live thread opens as the
              // standard agent chat, the same view the dock and the inline
              // agent rows reach. It answers false when there is no thread for
              // this agent, and the disk-backed transcript opens in place.
              if (onOpenAgentChat?.({ workflowRunId: runId, agentId: agent.agentId, label: agent.label })) {
                return;
              }
              setOpenInline((value) => !value);
            }}
            aria-expanded={openInline}
          >
            {copy("supermux.harness.workflow.browser.openTranscript")}
          </button>
        </div>
      ) : null}

      <Disclosure open={openInline} className="subagent-drill">
        <SubagentTranscriptView
          target={{ workflowRunId: runId, agentId: agent.agentId }}
          label={agent.label}
          open={openInline}
          tick={running ? progressTick : undefined}
        />
      </Disclosure>
    </div>
  );
}

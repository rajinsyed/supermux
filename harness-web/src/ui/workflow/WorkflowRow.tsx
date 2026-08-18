import { memo, useContext, useState } from "react";
import type { ToolBlock } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { AlertTriangle, CheckCircle, ChevronRight, Map as MapIcon, Stop } from "../Icons";
import { formatCompactDuration, formatTokens } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { Spinner } from "../primitives/Spinner";
import { useFoldHold } from "../transcript/foldGuard";
import { OpenViewContext } from "../views/OpenViewContext";
import { WorkflowBrowser } from "./WorkflowBrowser";
import { workflowInterrupted, workflowStopped } from "./browserModel";
import { subjectFromBlock, type WorkflowSubject } from "./subject";

/**
 * The transcript's whole record of a workflow: ONE row.
 *
 * The inline card this replaces rendered the entire run in place — phases,
 * every agent, per-agent result disclosures, a log strip — which is 600px of
 * nested detail wedged into a conversation. The CLI does not do that either: it
 * keeps a line in the transcript and puts the run in a browser. Everything that
 * card drew now lives in `WorkflowBrowser`, and this row is what opens it.
 */
export const WorkflowRow = memo(function WorkflowRow({ block }: { block: ToolBlock }) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const subject = subjectFromBlock(block);
  /**
   * The fallback when the row is rendered outside the router — a test mounting
   * one card, the export path, a workflow whose task id never landed so the
   * router has nothing to route TO. The browser opens over the pane instead, so
   * the affordance is never dead.
   */
  const [openLocal, setOpenLocal] = useState(false);
  // The reader is inside this workflow; the turn around it must not fold itself
  // away underneath them.
  useFoldHold(openLocal);

  const totals = subject.workflow?.totals;
  const interrupted = workflowInterrupted(subject.status);
  const stopped = workflowStopped(subject.status);
  const failed = subject.status === "failed" || (totals?.failed ?? 0) > 0;
  const running = !interrupted;

  const summary: string[] = [];
  if (totals && totals.agents > 0) {
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
  if (!running && subject.durationMs) summary.push(formatCompactDuration(subject.durationMs, copy));

  const open = () => {
    // The router addresses a workflow by its task id — the same id the dock row
    // and the tasks strip use — so a run reachable from three places is ONE
    // view rather than three copies of it.
    if (subject.taskId) {
      openView({ kind: "workflow", taskId: subject.taskId });
      return;
    }
    setOpenLocal(true);
  };

  return (
    <>
      <button
        type="button"
        className={`wf-row${
          failed ? " is-error" : stopped ? " is-stopped" : interrupted ? " is-done" : " is-running"
        }`}
        onClick={open}
      >
        <span className="wf-row-icon">
          <MapIcon size={13} />
        </span>
        <span className="wf-row-name">
          {subject.name ?? copy("supermux.harness.workflow.untitled")}
        </span>
        <span className="tool-badge is-quiet">{copy("supermux.harness.workflow.badge")}</span>
        {subject.description && subject.description !== subject.name ? (
          <span className="wf-row-desc" title={subject.description}>
            {subject.description}
          </span>
        ) : null}
        {summary.length > 0 ? <span className="wf-row-summary tnum">{summary.join(" · ")}</span> : null}
        {running ? (
          <>
            {subject.startedAtMs ? (
              <Elapsed className="wf-row-elapsed tnum" startedAtMs={subject.startedAtMs} />
            ) : null}
            <Spinner size={11} />
          </>
        ) : failed ? (
          <AlertTriangle size={12} className="mark-warn" />
        ) : stopped ? (
          <span className="wf-stopped-chip">
            <Stop size={9} />
            {copy("supermux.harness.workflow.stopped")}
          </span>
        ) : (
          <CheckCircle size={12} className="mark-ok" />
        )}
        <span className="wf-row-open">
          {copy("supermux.harness.workflow.browser.open")}
          <ChevronRight size={11} />
        </span>
      </button>
      {openLocal ? (
        <WorkflowOverlay subject={subject} onClose={() => setOpenLocal(false)} />
      ) : null}
    </>
  );
});

/**
 * The browser as an overlay, for a row with no router to hand it to. Same scrim
 * grammar as Modal — this is a full view of one object, not a dialog with
 * decisions in it, so it takes the whole pane rather than a 460px panel.
 */
function WorkflowOverlay({
  subject,
  onClose
}: {
  subject: WorkflowSubject;
  onClose(): void;
}) {
  return (
    <div
      className="wfb-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose();
      }}
    >
      <WorkflowBrowser subject={subject} onClose={onClose} />
    </div>
  );
}

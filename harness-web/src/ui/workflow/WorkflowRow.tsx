import { memo, useContext, useState } from "react";
import type { ToolBlock } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
import { ChevronRight } from "../Icons";
import { formatCompactDuration } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingGlyph } from "../primitives/Spinner";
import { useFoldHold } from "../transcript/foldGuard";
import { OpenViewContext } from "../views/OpenViewContext";
import { WorkflowBrowser } from "./WorkflowBrowser";
import { workflowInterrupted, workflowStopped } from "./browserModel";
import { subjectFromBlock, type WorkflowSubject } from "./subject";

/**
 * The transcript's whole record of a workflow: the same quiet two-line row an
 * agent gets, with the run browsed in a full view.
 *
 *   ● alpha-beta-demo   workflow                     2s ›
 *     1/2 agents · 2 phases
 *
 * A dot carries the state; the second line is the run's progress while it
 * runs and its outcome once it ends. Everything the old inline card drew
 * lives in `WorkflowBrowser`, and this row is what opens it.
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

  /** The second line, one phrase: progress while live, the outcome after. */
  const parts: string[] = [];
  if (totals && totals.agents > 0) {
    parts.push(
      copy("supermux.harness.workflow.browser.agentCount", {
        done: totals.done,
        total: totals.agents
      })
    );
  }
  if (subject.workflow && subject.workflow.phases.length > 0) {
    parts.push(
      plural(
        copy,
        subject.workflow.phases.length,
        "supermux.harness.workflow.phasesOne",
        "supermux.harness.workflow.phases"
      )
    );
  }
  const outcome = failed
    ? copy("supermux.harness.workflow.state.error")
    : stopped
      ? subject.durationMs
        ? copy("supermux.harness.workflow.stoppedAfter", {
            duration: formatCompactDuration(subject.durationMs, copy)
          })
        : copy("supermux.harness.workflow.stopped")
      : copy("supermux.harness.workflow.state.done");
  const line = running
    ? parts.length > 0
      ? parts.join(" · ")
      : copy("supermux.harness.workflow.starting")
    : parts.length > 0
      ? `${outcome} · ${parts.join(" · ")}`
      : outcome;

  const dot = failed ? "is-error" : stopped ? "is-stopped" : "is-done";

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
        {running ? (
          <WorkingGlyph className="agent-row-glyph" />
        ) : (
          <span className={`agent-dot ${dot}`} aria-hidden="true" />
        )}
        <span className="wf-row-main">
          <span className="wf-row-head">
            <span className="wf-row-name">
              {subject.name ?? copy("supermux.harness.workflow.untitled")}
            </span>
            <span className="wf-row-badge">{copy("supermux.harness.workflow.badge")}</span>
            <span className="wf-row-spacer" />
            {running && subject.startedAtMs ? (
              <Elapsed className="wf-row-elapsed tnum" startedAtMs={subject.startedAtMs} />
            ) : null}
            <ChevronRight size={11} className="wf-row-chev" aria-hidden="true" />
          </span>
          <span className="wf-row-summary tnum" title={subject.description}>
            {line}
          </span>
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

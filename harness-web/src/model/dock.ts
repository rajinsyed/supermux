import { flattenThreads, isThreadRunning } from "./agentThreads";
import { isTaskSettled } from "./tasks";
import type { HarnessView } from "../ui/views/viewStack";
import type { TranscriptModel } from "./types";

/**
 * The dock's rows, derived once so the list, the keyboard walker, and the tests
 * cannot disagree about what is in it or in what order.
 *
 * The CLI's dock is a HISTORY, not a live set: a row appears when its work
 * starts and stays for the session, dimmed, once it finishes. That is the whole
 * difference from the round-3 tasks strip, whose membership came from
 * `background_tasks_changed` and emptied the moment the CLI said nothing was
 * backgrounded — which is exactly when a user goes looking for what an agent
 * just did.
 *
 * Shells keep the strip's rule, though, and for the same reason it existed:
 * `task_started` fires for FOREGROUND Bash too, so a dock fed by task frames
 * alone would list every command the session ever ran. A shell earns its row by
 * having been in the background set, and keeps it afterwards.
 */
export type DockRowKind = "main" | "agent" | "workflow" | "shell";

export interface DockRow {
  id: string;
  kind: DockRowKind;
  /** Tree depth; agents nest one level per ancestor, everything else is 0. */
  depth: number;
  label: string;
  /** The agent type, workflow name, or command — the row's second field. */
  detail?: string;
  running: boolean;
  /** completed | failed | killed | stopped | running | undefined. */
  status?: string;
  startedAtMs?: number;
  /**
   * How long the work took, once it is over.
   *
   * NOT `endedAtMs - startedAtMs`. Those are two different clocks: the start is
   * the local instant the pane first heard of the task, while `end_time` on the
   * `task_updated` patch is the CLI's own epoch. Subtracting one from the other
   * produced "1ms" for a shell that had been running for sixteen seconds — and
   * would produce a wilder number on a resumed session, where the two clocks
   * are days apart. The wire's own `usage.duration_ms` is the authority; the
   * local difference is the fallback for a task that never reported one.
   */
  durationMs?: number;
  endedAtMs?: number;
  totalTokens?: number;
  /** `3/5` for workflows; undefined elsewhere. */
  agentsDone?: number;
  agentsTotal?: number;
  /** What opening this row shows. */
  view: HarnessView;
  /** The task to stop, when the row owns one that is still running. */
  stopTaskId?: string;
}

/**
 * The wire's own duration, or the local elapsed when it never sent one.
 *
 * The local difference is only meaningful when BOTH ends came from this
 * process's clock, and `end_time` never does — so it is used only as the
 * fallback, and only when it is positive.
 */
function settledDuration(
  reported: number | undefined,
  startedAtMs: number | undefined,
  endedAtMs: number | undefined
): number | undefined {
  if (reported !== undefined && reported > 0) return reported;
  if (startedAtMs === undefined || endedAtMs === undefined) return undefined;
  const local = endedAtMs - startedAtMs;
  return local > 0 ? local : undefined;
}

export function dockRows(model: TranscriptModel): DockRow[] {
  const rows: DockRow[] = [];
  const mainRunning =
    model.activity.sessionState === "running" ||
    model.activity.status === "requesting" ||
    model.turns.some((turn) => turn.state === "streaming");
  const lastTurn = model.turns[model.turns.length - 1];
  rows.push({
    id: "main",
    kind: "main",
    depth: 0,
    label: "",
    running: mainRunning,
    startedAtMs: mainRunning ? lastTurn?.startedAtMs : undefined,
    view: { kind: "main" }
  });

  for (const { thread, depth } of flattenThreads(model)) {
    const running = isThreadRunning(thread);
    rows.push({
      id: `agent:${thread.toolUseId}`,
      kind: "agent",
      depth: depth + 1,
      label: thread.description ?? "",
      detail: thread.subagentType,
      running,
      status: thread.status,
      startedAtMs: thread.startedAtMs,
      durationMs: settledDuration(thread.durationMs, thread.startedAtMs, thread.endedAtMs),
      endedAtMs: thread.endedAtMs,
      totalTokens: thread.totalTokens,
      view: { kind: "agent", toolUseId: thread.toolUseId },
      stopTaskId: running ? thread.taskId : undefined
    });
  }

  for (const record of Object.values(model.tasksById)) {
    if (record.taskType === "local_workflow") {
      const workflow = record.workflow;
      const agents = workflow?.agents ?? [];
      const running = !isTaskSettled(record.status);
      rows.push({
        id: `workflow:${record.taskId}`,
        kind: "workflow",
        depth: 1,
        label: record.workflowName ?? workflow?.name ?? "",
        detail: record.description,
        running,
        status: record.status,
        startedAtMs: record.startedAtMs,
        durationMs: settledDuration(record.durationMs, record.startedAtMs, record.endedAtMs),
        endedAtMs: record.endedAtMs,
        totalTokens: record.totalTokens,
        agentsDone: agents.filter((agent) => agent.state === "done" || agent.state === "cached")
          .length,
        agentsTotal: agents.length,
        view: { kind: "workflow", taskId: record.taskId },
        stopTaskId: running ? record.taskId : undefined
      });
      continue;
    }
    // Shells only: `local_agent` rows come from threads (which carry the tree),
    // and an unrecognised future task_type is admitted as a shell-shaped row
    // rather than dropped — it still has an output file and a Stop.
    if (record.taskType === "local_agent") continue;
    if (!record.isBackgrounded) continue;
    const running = !isTaskSettled(record.status);
    const label = record.description ?? "";
    // The CLI writes the task's own description into `summary` on the stop
    // notification, so a settled shell had the same sentence twice on one row.
    // The detail field only earns its place when it says something the label
    // does not.
    const detail = running ? record.activity ?? record.lastToolName : record.summary;
    rows.push({
      id: `shell:${record.taskId}`,
      kind: "shell",
      depth: 1,
      label,
      detail: detail === label ? undefined : detail,
      running,
      status: record.status,
      startedAtMs: record.startedAtMs,
      durationMs: settledDuration(record.durationMs, record.startedAtMs, record.endedAtMs),
      endedAtMs: record.endedAtMs,
      view: { kind: "shell", taskId: record.taskId },
      stopTaskId: running ? record.taskId : undefined
    });
  }

  return rows;
}

/** The agent thread a view is showing, if it is showing one. */
export function threadForView(model: TranscriptModel, view: HarnessView) {
  return view.kind === "agent" ? model.agentThreads[view.toolUseId] : undefined;
}

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
    rows.push({
      id: `shell:${record.taskId}`,
      kind: "shell",
      depth: 1,
      label: record.description ?? "",
      detail: running ? record.activity ?? record.lastToolName : record.summary,
      running,
      status: record.status,
      startedAtMs: record.startedAtMs,
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

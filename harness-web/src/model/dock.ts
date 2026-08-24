import { flattenThreads, isThreadRunning } from "./agentThreads";
import { isTaskSettled } from "./tasks";
import type { HarnessView } from "../ui/views/viewStack";
import type { TranscriptModel } from "./types";

/**
 * The dock's rows, derived once so the list, the keyboard walker, and the tests
 * cannot disagree about what is in it or in what order.
 *
 * The dock is a LIVE SET, not a history: a row appears while its work is
 * running and is REMOVED the moment the work is terminal (completed, failed,
 * killed, stopped). Round 4 persisted settled rows, dimmed, on the theory that
 * a just-finished agent is what a user goes looking for. Dogfood said the
 * opposite — the dock filled with dead rows the user had to read past to find
 * the one thing still working, and nothing cleared them.
 *
 * Finished work stays REACHABLE without being docked: the compact agent and
 * workflow rows in the transcript sit where the work was launched and open the
 * same views. The dock answers "what is running right now"; the transcript
 * answers "what happened".
 *
 * Shells keep the extra rule they always had: `task_started` fires for
 * FOREGROUND Bash too, so a dock fed by task frames alone would list every
 * command the session ever ran. A shell earns its row by being in the
 * background set AND still running.
 */
export type DockRowKind = "main" | "agent" | "workflow" | "shell";

export interface DockRow {
  id: string;
  kind: DockRowKind;
  /**
   * Tree depth; agents nest one level per VISIBLE ancestor, everything else
   * is 1 (main is 0).
   *
   * Counted over visible ancestors rather than real ones because a parent can
   * finish while its child is still running. The child stays — it is live work
   * — and it is promoted to the level its vanished parent occupied, instead of
   * hanging an indent and a `└` guide off a row that is no longer there.
   */
  depth: number;
  label: string;
  /** The agent type, workflow name, or command — the row's second field. */
  detail?: string;
  running: boolean;
  /** The wire's status token, for the dot's tint while the row is live. */
  status?: string;
  /** The model doing the work, for agent rows — the frames name it live. */
  model?: string;
  startedAtMs?: number;
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
    // A session waiting on a permission prompt is not idle: it is the user's
    // move, and the row that says so must not read as finished.
    model.activity.sessionState === "requires_action" ||
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

  /**
   * `base[d]` is how many VISIBLE ancestors a thread at real depth `d` has.
   * `flattenThreads` is depth-first with the parent before its children, so a
   * node's base is always written before it is read.
   */
  const base: number[] = [0];
  for (const { thread, depth } of flattenThreads(model)) {
    const running = isThreadRunning(thread);
    const ancestors = base[depth] ?? 0;
    base[depth + 1] = ancestors + (running ? 1 : 0);
    if (!running) continue;
    rows.push({
      id: `agent:${thread.toolUseId}`,
      kind: "agent",
      depth: ancestors + 1,
      label: thread.description ?? "",
      // Live activity, the way Cursor's panel reads ("Planning next moves"),
      // falling back to the static type only before the first progress frame.
      detail: thread.activity ?? thread.lastToolName ?? thread.subagentType,
      running: true,
      status: thread.status,
      model: thread.model,
      startedAtMs: thread.startedAtMs,
      totalTokens: thread.totalTokens,
      view: { kind: "agent", toolUseId: thread.toolUseId },
      stopTaskId: thread.taskId
    });
  }

  for (const record of Object.values(model.tasksById)) {
    if (isTaskSettled(record.status)) continue;
    if (record.taskType === "local_workflow") {
      const workflow = record.workflow;
      const agents = workflow?.agents ?? [];
      rows.push({
        id: `workflow:${record.taskId}`,
        kind: "workflow",
        depth: 1,
        label: record.workflowName ?? workflow?.name ?? "",
        detail: record.description,
        running: true,
        status: record.status,
        startedAtMs: record.startedAtMs,
        totalTokens: record.totalTokens,
        agentsDone: agents.filter((agent) => agent.state === "done" || agent.state === "cached")
          .length,
        agentsTotal: agents.length,
        view: { kind: "workflow", taskId: record.taskId },
        stopTaskId: record.taskId
      });
      continue;
    }
    // Shells only: `local_agent` rows come from threads (which carry the tree),
    // and an unrecognised future task_type is admitted as a shell-shaped row
    // rather than dropped — it still has an output file and a Stop.
    if (record.taskType === "local_agent") continue;
    if (!record.isBackgrounded) continue;
    const label = record.description ?? "";
    const detail = record.activity ?? record.lastToolName;
    rows.push({
      id: `shell:${record.taskId}`,
      kind: "shell",
      depth: 1,
      label,
      detail: detail === label ? undefined : detail,
      running: true,
      status: record.status,
      startedAtMs: record.startedAtMs,
      view: { kind: "shell", taskId: record.taskId },
      stopTaskId: record.taskId
    });
  }

  return rows;
}

/** The agent thread a view is showing, if it is showing one. */
export function threadForView(model: TranscriptModel, view: HarnessView) {
  return view.kind === "agent" ? model.agentThreads[view.toolUseId] : undefined;
}

import type { TaskRecord, ToolBlock, WorkflowProgress } from "../../model/types";

/**
 * One workflow, described in the terms the browser renders — regardless of
 * whether the caller holds the launching ToolBlock (the inline row) or only a
 * TaskRecord (the agents dock, whose rows outlive their turn).
 *
 * The two sources carry the same facts under different names and with different
 * gaps: a block knows the `runId` from its `tool_use_result` before any task
 * frame lands, a record knows the live status after the turn has settled and
 * folded. Normalising here is what lets ONE browser serve both.
 */
export interface WorkflowSubject {
  workflow?: WorkflowProgress;
  name?: string;
  description?: string;
  /** The stop target: `control_request {subtype: "stop_task"}` takes this. */
  taskId?: string;
  /** `wf_…` — with `agentId`, the disk-transcript address of every agent. */
  runId?: string;
  status?: string;
  startedAtMs?: number;
  durationMs?: number;
  /** Bumped on every task frame, so an open disk read can re-fetch on it. */
  progressTick?: number;
}

export function subjectFromBlock(block: ToolBlock): WorkflowSubject {
  const info = block.subagent ?? {};
  const workflow = block.workflow;
  return {
    workflow,
    name: workflow?.name ?? info.workflowName ?? asText(block.input.name),
    description: info.description ?? info.summary,
    taskId: info.taskId,
    // The block's own result is the EARLIEST source of the runId — a workflow's
    // task frames never carry it at all.
    runId: info.workflowRunId ?? workflow?.runId,
    status: info.status ?? workflow?.status,
    startedAtMs: info.startedAtMs ?? block.startedAtMs,
    durationMs: info.durationMs,
    progressTick: info.progressTick
  };
}

export function subjectFromTask(record: TaskRecord): WorkflowSubject {
  return {
    workflow: record.workflow,
    name: record.workflowName ?? record.workflow?.name,
    description: record.description ?? record.summary,
    taskId: record.taskId,
    runId: record.workflowRunId ?? record.workflow?.runId,
    status: record.status,
    startedAtMs: record.startedAtMs,
    durationMs: record.durationMs,
    progressTick: record.progressTick
  };
}

function asText(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

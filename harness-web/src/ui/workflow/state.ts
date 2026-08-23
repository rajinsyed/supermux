import type { CopyKey } from "../../copyKeys";
import type { WorkflowAgentState } from "../../model/types";

/**
 * One vocabulary for an agent's state, wherever the agent is rendered — the
 * workflow browser, the tasks strip, the compact inline row.
 *
 * It lived on the old inline WorkflowCard, which the browser replaces; the map
 * itself is shared vocabulary rather than card chrome, so it moved here instead
 * of dying with it.
 */
export const STATE_LABELS: Record<WorkflowAgentState, CopyKey> = {
  queued: "supermux.harness.workflow.state.queued",
  running: "supermux.harness.workflow.state.running",
  done: "supermux.harness.workflow.state.done",
  error: "supermux.harness.workflow.state.error",
  blocked: "supermux.harness.workflow.state.blocked",
  cached: "supermux.harness.workflow.state.cached"
};

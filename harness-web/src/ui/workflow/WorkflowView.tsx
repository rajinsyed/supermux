import { useCallback, useContext, useMemo } from "react";
import type { TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { OpenViewContext } from "../views/OpenViewContext";
import { WorkflowBrowser } from "./WorkflowBrowser";
import { subjectFromTask } from "./subject";

/**
 * The router's `{kind: "workflow", taskId}` view.
 *
 * Resolved from `tasksById` rather than from the launching ToolBlock, because
 * the block is the one source that can go away: a workflow's turn settles the
 * instant it is launched (`async_launched`), folds, and may be scrolled out of
 * the window entirely while the run carries on for another minute. The record
 * outlives all of that, which is exactly why the reducer keeps it.
 */
export function WorkflowView({
  model,
  taskId,
  onBack
}: {
  model: TranscriptModel;
  taskId: string;
  onBack(): void;
}) {
  const copy = useCopy();
  const openView = useContext(OpenViewContext);
  const record = model.tasksById[taskId];
  const subject = useMemo(() => (record ? subjectFromTask(record) : undefined), [record]);

  /**
   * "Open full transcript" → the standard agent chat view.
   *
   * A workflow agent has no `tool_use` of its own — it never appears on the
   * wire as an Agent tool call — so it only has a thread when one was built for
   * its `agentId`. Answering FALSE when there is none is what lets the browser
   * keep its disk-backed inline fallback for the rest, instead of routing to an
   * empty agent view or offering a button that does nothing.
   */
  const openAgentChat = useCallback(
    (target: { agentId?: string }): boolean => {
      if (!target.agentId) return false;
      const thread = Object.values(model.agentThreads).find(
        (candidate) => candidate.agentId === target.agentId
      );
      if (!thread) return false;
      openView({ kind: "agent", toolUseId: thread.toolUseId });
      return true;
    },
    [model.agentThreads, openView]
  );

  if (!subject) {
    return (
      <div className="view-body">
        <div className="drill-status">{copy("supermux.harness.workflow.browser.gone")}</div>
      </div>
    );
  }

  return (
    <div className="view-body">
      <WorkflowBrowser subject={subject} onClose={onBack} onOpenAgentChat={openAgentChat} />
    </div>
  );
}

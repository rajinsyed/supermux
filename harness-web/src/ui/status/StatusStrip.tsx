import type { ActivityState, RunPhase, TranscriptModel } from "../../model/types";
import { useCopy } from "../CopyContext";
import { Refresh } from "../Icons";
import { formatTokens } from "../format";
import { Elapsed } from "../primitives/Elapsed";
import { WorkingDots } from "../primitives/Spinner";

function liveTool(model: TranscriptModel): { name: string; startedAtMs: number } | undefined {
  for (let i = model.turns.length - 1; i >= 0; i -= 1) {
    const turn = model.turns[i];
    if (turn.state !== "streaming") continue;
    const walk = (blocks: typeof turn.blocks): { name: string; startedAtMs: number } | undefined => {
      for (let j = blocks.length - 1; j >= 0; j -= 1) {
        const block = blocks[j];
        if (block.kind !== "tool") continue;
        const nested = walk(block.children);
        if (nested) return nested;
        if (block.status === "running" || block.status === "pending") {
          return { name: block.name, startedAtMs: block.startedAtMs };
        }
      }
      return undefined;
    };
    const found = walk(turn.blocks);
    if (found) return found;
  }
  return undefined;
}

export function StatusStrip({
  model,
  runPhase,
  activity,
  onRestart
}: {
  model: TranscriptModel;
  runPhase: RunPhase;
  activity: ActivityState;
  onRestart: () => void;
}) {
  const copy = useCopy();
  const pending = model.pending.length > 0;
  const tool = liveTool(model);
  const running = activity.sessionState === "running" || activity.status === "requesting";

  let tone = "idle";
  let content: React.ReactNode = copy("supermux.harness.status.idle");
  let live = false;

  if (runPhase === "exited" && model.exitError) {
    tone = "error";
    content = (
      <>
        <span>{model.exitError}</span>
        <button type="button" className="btn btn-tiny" onClick={onRestart}>
          <Refresh size={11} />
          {copy("supermux.harness.status.restart")}
        </button>
      </>
    );
  } else if (pending) {
    tone = "attention";
    content = copy("supermux.harness.status.waitingApproval");
  } else if (activity.status === "compacting") {
    tone = "busy";
    live = true;
    content = copy("supermux.harness.status.compacting");
  } else if (tool) {
    tone = "busy";
    live = true;
    content = (
      <>
        <span>{copy("supermux.harness.status.running", { tool: tool.name })}</span>
        <Elapsed className="tnum status-elapsed" startedAtMs={tool.startedAtMs} prefix=" · " />
      </>
    );
  } else if (running) {
    tone = "busy";
    live = true;
    content = activity.thinkingTokens
      ? copy("supermux.harness.status.thinkingTokens", {
          tokens: formatTokens(activity.thinkingTokens)
        })
      : copy("supermux.harness.status.thinking");
  } else if (runPhase === "starting") {
    tone = "busy";
    live = true;
    content = copy("supermux.harness.status.starting");
  }

  return (
    <div className={`status-strip is-${tone}`} role="status" aria-live="polite">
      {live ? <WorkingDots /> : <span className={`status-dot is-${tone}`} />}
      <span className="status-text">{content}</span>
      {live ? (
        <span className="status-hint">{copy("supermux.harness.composer.hintInterrupt")}</span>
      ) : null}
    </div>
  );
}

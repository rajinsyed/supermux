import type { ActivityState, RunPhase, TranscriptModel } from "../../model/types";
import { plural, useCopy } from "../CopyContext";
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
  cliUnavailable,
  restarting,
  onRestart
}: {
  model: TranscriptModel;
  runPhase: RunPhase;
  activity: ActivityState;
  /** No CLI on disk: the pane cannot start, so the strip must not read "Ready". */
  cliUnavailable: boolean;
  /** The old process is down and the new one is not up yet. */
  restarting?: boolean;
  onRestart: () => void;
}) {
  const copy = useCopy();
  const pending = model.pending.length > 0;
  const tool = liveTool(model);
  const running = activity.sessionState === "running" || activity.status === "requesting";
  // Stranded messages are queued work too — they are waiting on the next run.
  // Counting only `queued` would print "Ready" over a strip full of chips, which
  // is the contradiction this strip exists to avoid.
  const queued = model.queued.length + model.stranded.length;

  let tone = "idle";
  let content: React.ReactNode = copy("supermux.harness.status.idle");
  let live = false;

  if (cliUnavailable) {
    tone = "error";
    content = copy("supermux.harness.status.noCli");
  } else if (restarting) {
    tone = "busy";
    live = true;
    content = copy("supermux.harness.status.restarting");
  } else if (runPhase === "exited") {
    tone = "error";
    content = (
      <>
        <span>{model.exitError ?? copy("supermux.harness.status.exited")}</span>
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
  } else if (queued > 0) {
    // Messages are waiting to be sent, so the pane is NOT ready — it had been
    // printing "Ready" over a full queue strip, which is where the impression
    // that a later message had jumped the line came from.
    tone = "busy";
    live = true;
    content = plural(
      copy,
      queued,
      "supermux.harness.status.queuedOne",
      "supermux.harness.status.queued"
    );
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

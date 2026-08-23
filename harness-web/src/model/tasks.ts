import type { Block, ToolBlock, TranscriptModel, Turn } from "./types";

/** Task statuses that mean the CLI is finished with it, one way or another. */
export const SETTLED_TASK_STATUSES = new Set(["completed", "failed", "killed", "stopped"]);

export function isTaskSettled(status: string | undefined): boolean {
  return status !== undefined && SETTLED_TASK_STATUSES.has(status);
}

/**
 * The turn owns a background task that is still running.
 *
 * Scoped to BACKGROUND work deliberately: an ordinary tool card is settled by
 * `settleTurn` before this is ever consulted, so the only thing that can still
 * be live is work the CLI carries on with AFTER the turn ends — a workflow, an
 * async agent, a backgrounded shell.
 */
export function hasLiveBackgroundWork(turn: Turn): boolean {
  const scan = (blocks: Block[]): boolean => {
    for (const block of blocks) {
      if (block.kind !== "tool") continue;
      const info = block.subagent;
      const asyncLaunched =
        (block.name === "Task" || block.name === "Agent") &&
        block.structured?.status === "async_launched";
      if (((info?.taskId && info.background) || asyncLaunched) && !isTaskSettled(info?.status)) {
        return true;
      }
      if (scan(block.children)) return true;
    }
    return false;
  };
  return scan(turn.blocks);
}

/**
 * When the work a card describes actually started.
 *
 * A tool card and its strip row are two views of ONE running command, so they
 * must count from one instant. The TASK record's start is the authority — it is
 * what the strip reads — and the block's own `startedAtMs` is the fallback for a
 * card whose task the CLI has not announced yet (or that never had one).
 */
export function workStartedAtMs(block: ToolBlock): number {
  return block.subagent?.startedAtMs ?? block.startedAtMs;
}

/**
 * The tool_use_id of the Bash currently BLOCKING the turn, if there is one.
 *
 * "Blocking" is the whole point: a command with `run_in_background: true`, or
 * one already moved to the background, is not holding the turn up and must not
 * be what Ctrl+B moves. Searching from the newest turn backwards means the key
 * always acts on the command the user is actually waiting on.
 */
export function runningForegroundBash(model: TranscriptModel): string | undefined {
  const scan = (blocks: Block[]): string | undefined => {
    for (let i = blocks.length - 1; i >= 0; i -= 1) {
      const block = blocks[i];
      if (block.kind !== "tool") continue;
      const nested = scan(block.children);
      if (nested) return nested;
      if (block.name !== "Bash") continue;
      // `running` and not `pending`: a pending block is one whose input is still
      // streaming in, so the CLI has not started the command and there is
      // nothing to move — and, worse, its `run_in_background` flag has not
      // arrived yet, so treating it as foreground would background a command
      // that was about to launch in the background anyway.
      if (block.status !== "running") continue;
      if (block.subagent?.background === true) continue;
      if (block.input.run_in_background === true) continue;
      return block.toolUseId;
    }
    return undefined;
  };
  for (let i = model.turns.length - 1; i >= 0; i -= 1) {
    const found = scan(model.turns[i].blocks);
    if (found) return found;
  }
  return undefined;
}

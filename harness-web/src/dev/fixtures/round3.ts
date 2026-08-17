import type { ProtocolLine } from "../../protocol/types";
import { initializeResponse } from "./build";
import { parseJsonl } from "./parse";
import { bgRound3Raw } from "./round3BgRaw";
import { nestedRound3Raw } from "./round3NestedRaw";
import { shellsRound3Raw } from "./round3ShellsRaw";
import { workflowRound3Raw } from "./round3WorkflowRaw";

/**
 * The four round-3 live probes, verbatim off the wire (claude CLI 2.1.233), with
 * the `initialize` handshake reply prepended so the model menu and slash-command
 * popover have the same catalog every other scenario gets. Nothing else is
 * synthesized: every task frame, every `workflow_progress` array and every
 * `background_tasks_changed` REPLACE below is what the CLI actually sent.
 */
function probe(raw: string): ProtocolLine[] {
  return [initializeResponse(), ...parseJsonl(raw)];
}

/** Background shell: launch → strip → stop_task kill → stopped notification. */
export const shellsFixture: ProtocolLine[] = probe(shellsRound3Raw);

/** Foreground Bash backgrounded mid-run (ctrl+B), `is_backgrounded` patch. */
export const bgFixture: ProtocolLine[] = probe(bgRound3Raw);

/** Dynamic workflow: phases Gather/Merge, 3 agents, post-result completion. */
export const workflowFixture: ProtocolLine[] = probe(workflowRound3Raw);

/** Nested subagents: outer Agent spawns an inner one, both complete. */
export const nestedFixture: ProtocolLine[] = probe(nestedRound3Raw);

/**
 * Where each probe stops being "history" and starts being live.
 *
 * The scenarios replay the leading slice, then drive the tail on a timer so the
 * pane is genuinely mid-flight — a workflow card with an agent still running,
 * a shell still in the strip — rather than a finished transcript of one.
 */
/**
 * Where each probe stops being history and starts being live. Indices are into
 * the assembled arrays above, so they already account for the prepended
 * `initializeResponse()`.
 */
export const ROUND3_CUTS = {
  /**
   * Through the backgrounded shell's `tool_result`. The turn is still open, so
   * the scenario can put a FOREGROUND Bash in flight next to the strip — which
   * is the only state in which "Move to background" is reachable.
   *
   * The probe has already begun STREAMING its next tool call by this point, so
   * `shellsOpening` trims those partial frames: a card whose input is half an
   * arrival renders as a nameless "Bash · Preparing" row that never resolves,
   * and the scenario supplies its own complete foreground Bash instead.
   */
  shells: 27,
  /** Through the foreground Bash's `tool_use`, before it is backgrounded. */
  bg: 17,
  /**
   * Through the FIRST `task_progress`, where phase Gather is declared and both
   * its agents are still queued. Everything after streams live: the agents
   * advance, the launching turn's `result` lands mid-workflow (proving task
   * frames never reopen it), the workflow settles in the background, and the
   * CLI opens its own summary turn.
   */
  workflow: 31,
  /** Through the inner agent's `tool_use`: a two-level tree, both running. */
  nested: 30
} as const;

/**
 * The CLI's answer to `background_tasks {tool_use_id}` — task_started, the strip
 * gaining the task, the `is_backgrounded` patch, and the "backgrounded by user"
 * tool_result. Replayed by the mock when the scenario's Move-to-background
 * button (or Ctrl+B) is used, so the affordance is verifiable end to end.
 *
 * `keep` are the task ids ALREADY in the strip. `background_tasks_changed` is a
 * REPLACE, so a canned frame carrying only the new task would silently evict
 * every shell already running — which is what the real CLI would never do, and
 * exactly the bug a scenario has to be able to show the absence of.
 */
export function bgBackgroundResponse(keep: BackgroundTaskSummary[] = []): ProtocolLine[] {
  return bgFixture.slice(21, 25).map((line) => {
    const frame = line as { subtype?: string; tasks?: BackgroundTaskSummary[] };
    if (frame.subtype !== "background_tasks_changed") return line;
    const added = frame.tasks ?? [];
    const seen = new Set(keep.map((task) => task.task_id));
    return {
      ...frame,
      tasks: keep.concat(added.filter((task) => !seen.has(task.task_id)))
    } as ProtocolLine;
  });
}

export interface BackgroundTaskSummary {
  task_id?: string;
  task_type?: string;
  description?: string;
}

/**
 * The shells scenario's opening slice, minus the partial frames of the tool call
 * the CLI had already started streaming at the cut. A `content_block_start` with
 * no matching `content_block_stop` leaves a permanently half-built card.
 */
export const shellsOpening: ProtocolLine[] = shellsFixture
  .slice(0, ROUND3_CUTS.shells)
  .filter((line) => {
    const frame = line as { type?: string; event?: { type?: string; index?: number } };
    if (frame.type !== "stream_event") return true;
    return frame.event?.index !== 2;
  });

/** The bg probe's own foreground Bash `tool_use`, with no result behind it. */
export const foregroundBashLaunch: ProtocolLine[] = bgFixture.slice(16, 17);

/** The tool_use_id that `foregroundBashLaunch` announces. */
export const FOREGROUND_BASH_TOOL_USE_ID = "toolu_016i2VPvtvJzj3Vqxz3gpkZS";

/** The CLI's answer to `stop_task`: empty set, killed patch, stopped notice. */
export const shellsStopResponse: ProtocolLine[] = shellsFixture.slice(46);

/** The shells probe's own tail: the foreground Bash and the turn's result. */
export const shellsTail: ProtocolLine[] = shellsFixture.slice(28, 46);

/** The workflow probe after its first progress frame: agents advance, then settle. */
export const workflowTail: ProtocolLine[] = workflowFixture.slice(ROUND3_CUTS.workflow);

/** The nested probe's completions, inner agent first. */
export const nestedTail: ProtocolLine[] = nestedFixture.slice(ROUND3_CUTS.nested);

/** When the probes were recorded — the base every wire epoch below sits on. */
const PROBE_EPOCH_MS = 1786991412505;

const EPOCH_KEYS = new Set([
  "startedAt",
  "queuedAt",
  "lastProgressAt",
  "end_time",
  "endTime"
]);

/**
 * Shift every wire epoch in a probe so it reads as having happened just now.
 *
 * Live elapsed on a workflow agent is `now - startedAt`, and `startedAt` is the
 * CLI's own epoch. Replayed verbatim in the dev harness, an agent that ran for
 * 1.7 seconds in August reports "1h 03m" and climbing — which makes the one
 * number the card exists to show impossible to check.
 *
 * The DEV path only. The fixtures themselves stay byte-exact, so the model
 * tests keep asserting against what the CLI actually sent.
 */
export function rebaseRound3(lines: ProtocolLine[], nowMs = Date.now()): ProtocolLine[] {
  const delta = nowMs - PROBE_EPOCH_MS;
  const shift = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(shift);
    if (typeof value !== "object" || value === null) return value;
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] =
        EPOCH_KEYS.has(key) && typeof item === "number" && item > 1_000_000_000_000
          ? item + delta
          : shift(item);
    }
    return out;
  };
  return lines.map((line) => shift(line) as ProtocolLine);
}

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

/** When the probes were recorded — the last-resort base for epoch rebasing. */
const PROBE_EPOCH_MS = 1786991412505;

const EPOCH_KEYS = new Set([
  "startedAt",
  "queuedAt",
  "lastProgressAt",
  "end_time",
  "endTime"
]);

/**
 * The FIRST wire epoch a fixture carries — the moment its live story begins.
 *
 * This, not the probe's session init, is what a rebase must anchor on: the
 * workflow's first `startedAt` sits 7.5 seconds after init, so shifting by
 * `now - init` lands every agent's start 7.5 seconds in the FUTURE relative to
 * the moment its row appears. `formatDuration` clamps the negative to 0, and an
 * agent that settles before wall-clock catches up reads 0s for its entire
 * lifetime — the one number the card exists to show, unverifiable in the
 * scenario pinned to verify it. Anchoring on the fixture's own first epoch
 * makes t=0 on screen t=0 in the fixture.
 */
export function epochBaseOf(lines: ProtocolLine[]): number {
  let base: number | undefined;
  const scan = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const item of value) scan(item);
      return;
    }
    if (typeof value !== "object" || value === null) return;
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      if (EPOCH_KEYS.has(key) && typeof item === "number" && item > 1_000_000_000_000) {
        if (base === undefined || item < base) base = item;
      } else {
        scan(item);
      }
    }
  };
  for (const line of lines) {
    scan(line);
    // The first epoch-carrying LINE anchors the story; later lines only carry
    // later moments of it.
    if (base !== undefined) return base;
  }
  return PROBE_EPOCH_MS;
}

/**
 * Shift every wire epoch in a probe so it reads as having happened just now.
 *
 * Live elapsed on a workflow agent is `now - startedAt`, and `startedAt` is the
 * CLI's own epoch. Replayed verbatim in the dev harness, an agent that ran for
 * 1.7 seconds in August reports "1h 03m" and climbing — which makes the one
 * number the card exists to show impossible to check.
 *
 * `baseMs` must be shared across every slice of one scenario (opening AND live
 * tail), or an agent's `startedAt` would shift between frames and its elapsed
 * would reset on every progress tick. Callers pass `epochBaseOf(fixture)`.
 *
 * The DEV path only. The fixtures themselves stay byte-exact, so the model
 * tests keep asserting against what the CLI actually sent.
 */
export function rebaseRound3(
  lines: ProtocolLine[],
  baseMs = PROBE_EPOCH_MS,
  nowMs = Date.now()
): ProtocolLine[] {
  const delta = nowMs - baseMs;
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

/**
 * The log lines the pinned workflow scenario feeds the card's log strip.
 *
 * The live probe happened to run a workflow that never called `log()`, so the
 * strip — implemented, styled, unit-tested — was unreachable in every scenario
 * and had never been SEEN rendered. ROUND3.md sanctions hand-extending the
 * fixture with the documented `workflow_log` shape (§B.5) so the pinned
 * scenario covers everything the card can draw. The list is cumulative, like
 * the CLI's own resend-the-whole-list semantics.
 */
const WORKFLOW_LOGS = [
  "workflow alpha-beta-demo: 2 phases, 3 agents declared",
  "Phase Gather: dispatching agent-alpha and agent-beta in parallel",
  "agent-alpha: done in 1.7s",
  "agent-beta: done in 2.1s — phase Gather complete",
  "Phase Merge: dispatching merger with both results",
  "merger: done in 1.9s — workflow complete"
];

export function withWorkflowLogs(
  lines: ProtocolLine[],
  logs: string[] = WORKFLOW_LOGS
): ProtocolLine[] {
  let progressFrames = 0;
  return lines.map((line) => {
    const frame = line as { subtype?: string; workflow_progress?: unknown[] };
    if (
      frame.subtype !== "task_progress" ||
      !Array.isArray(frame.workflow_progress) ||
      frame.workflow_progress.length === 0
    ) {
      return line;
    }
    progressFrames += 1;
    const visible = Math.min(logs.length, progressFrames + 1);
    return {
      ...frame,
      workflow_progress: [
        ...frame.workflow_progress,
        ...logs.slice(0, visible).map((message) => ({ type: "workflow_log", message }))
      ]
    } as ProtocolLine;
  });
}

/**
 * What each agent is DOING while it runs, keyed by the agent's label.
 *
 * The probe's agents each answered in one shot with no tools, so every
 * `workflow_agent` item it sent carries neither `lastToolName` nor
 * `lastToolSummary` — which leaves the browser's Activity section reading "No
 * tool activity reported" for the entire pinned scenario, i.e. the one section
 * whose whole job is to be live could never be seen alive. ROUND3.md §B.5
 * documents both fields; they are hand-added here on RUNNING agents only, the
 * way the CLI sends them, and cleared the moment an agent finishes (the wire
 * replaces the item wholesale on each frame).
 *
 * The byte-exact fixture is untouched, so the model tests keep asserting
 * against what the CLI actually sent.
 */
const WORKFLOW_ACTIVITY: Record<string, { tool: string; summary: string }> = {
  "agent-alpha": { tool: "Bash", summary: "echo alpha | tr -d '\\n'" },
  "agent-beta": { tool: "Read", summary: "Reading gather-notes.md" },
  merger: { tool: "Bash", summary: "echo alphabeta" }
};

export function withWorkflowActivity(lines: ProtocolLine[]): ProtocolLine[] {
  return lines.map((line) => {
    const frame = line as { subtype?: string; workflow_progress?: unknown[] };
    if (frame.subtype !== "task_progress" || !Array.isArray(frame.workflow_progress)) return line;
    return {
      ...frame,
      workflow_progress: frame.workflow_progress.map((item) => {
        const raw = item as Record<string, unknown>;
        if (raw.type !== "workflow_agent") return item;
        // Running means `state: "start"` WITH a startedAt: a queued agent has
        // not touched a tool, and a done one has stopped.
        const running = raw.state === "start" && typeof raw.startedAt === "number";
        const activity = WORKFLOW_ACTIVITY[String(raw.label)];
        if (!running || !activity) return item;
        return { ...raw, lastToolName: activity.tool, lastToolSummary: activity.summary };
      })
    } as ProtocolLine;
  });
}

/**
 * The nested probe's agents did pure arithmetic, so their AgentOutputs carry no
 * `toolStats` and the completion summary ("read N files, +X −Y") — promised by
 * ROUND3.md §1 and pinned to this scenario — was undemonstrable. Hand-extended
 * with the documented shape (§A.7); the byte-exact fixture stays untouched for
 * the model tests.
 */
export function withNestedToolStats(lines: ProtocolLine[]): ProtocolLine[] {
  return lines.map((line) => {
    const frame = line as { type?: string; tool_use_result?: Record<string, unknown> };
    if (frame.type !== "user") return line;
    const result = frame.tool_use_result;
    if (!result || result.agentId !== "a273351272d38e227") return line;
    return {
      ...frame,
      tool_use_result: {
        ...result,
        totalToolUseCount: 3,
        toolStats: {
          readCount: 1,
          searchCount: 0,
          bashCount: 1,
          editFileCount: 0,
          linesAdded: 0,
          linesRemoved: 0,
          otherToolCount: 1
        }
      }
    } as ProtocolLine;
  });
}

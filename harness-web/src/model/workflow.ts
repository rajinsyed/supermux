import { asNumber, asString, isPlainObject } from "./helpers";
import type {
  WorkflowAgent,
  WorkflowAgentState,
  WorkflowPhase,
  WorkflowProgress,
  WorkflowTotals
} from "./types";

export function emptyWorkflow(name?: string, runId?: string): WorkflowProgress {
  return {
    name,
    runId,
    phases: [],
    agents: [],
    logs: [],
    totals: { agents: 0, done: 0, running: 0, failed: 0, tokens: 0, toolCalls: 0 }
  };
}

/**
 * The wire's three-value `state` (start | done | error) plus the flags that ride
 * alongside it, resolved to the one chip a row shows.
 *
 * `start` covers two visibly different things: an agent the scheduler has
 * accepted but not begun (no `startedAt`) and one that is mid-run. Rendering
 * both as "running" is what made a workflow's whole agent list light up the
 * instant the first phase was declared, which is the opposite of the progress
 * the card exists to show. `blocked` and `cached` outrank the rest because they
 * explain why an agent will never move.
 */
export function agentStateOf(raw: Record<string, unknown>): WorkflowAgentState {
  const wire = asString(raw.state);
  if (wire === "error") return "error";
  if (raw.blocked === true) return "blocked";
  if (raw.cached === true) return "cached";
  if (wire === "done") return "done";
  return asNumber(raw.startedAt) === undefined ? "queued" : "running";
}

function parseAgent(raw: Record<string, unknown>, index: number): WorkflowAgent {
  return {
    index,
    label: asString(raw.label) ?? `#${index}`,
    phaseIndex: asNumber(raw.phaseIndex),
    phaseTitle: asString(raw.phaseTitle),
    agentId: asString(raw.agentId),
    agentType: asString(raw.agentType),
    isolation: asString(raw.isolation),
    model: asString(raw.model),
    fallbackModel: asString(raw.fallbackModel),
    state: agentStateOf(raw),
    wireState: asString(raw.state),
    queuedAt: asNumber(raw.queuedAt),
    startedAt: asNumber(raw.startedAt),
    lastProgressAt: asNumber(raw.lastProgressAt),
    attempt: asNumber(raw.attempt),
    lastAttemptReason: asString(raw.lastAttemptReason),
    lastToolName: asString(raw.lastToolName),
    lastToolSummary: asString(raw.lastToolSummary),
    promptPreview: asString(raw.promptPreview),
    tokens: asNumber(raw.tokens),
    toolCalls: asNumber(raw.toolCalls),
    durationMs: asNumber(raw.durationMs),
    resultPreview: asString(raw.resultPreview),
    error: asString(raw.error),
    blocked: raw.blocked === true,
    cached: raw.cached === true
  };
}

function totalsFor(agents: WorkflowAgent[]): WorkflowTotals {
  let done = 0;
  let running = 0;
  let failed = 0;
  let tokens = 0;
  let toolCalls = 0;
  for (const agent of agents) {
    if (agent.state === "done" || agent.state === "cached") done += 1;
    else if (agent.state === "running") running += 1;
    else if (agent.state === "error") failed += 1;
    tokens += agent.tokens ?? 0;
    toolCalls += agent.toolCalls ?? 0;
  }
  return { agents: agents.length, done, running, failed, tokens, toolCalls };
}

/**
 * Merge one `workflow_progress` array into the running snapshot.
 *
 * The array is cumulative and its items are keyed by `(type, index)`: a later
 * frame carries the SAME agent at a new state, so items are upserted in place
 * and array order is preserved. Logs have no index — the CLI appends them and
 * trims the oldest when it hits its own item cap — so they are matched by
 * position in the log list, which is what keeps a trimmed frame from replaying
 * the whole strip as new lines.
 *
 * Frames that carry no `workflow_progress` at all (about half of them on the
 * wire) must leave the snapshot alone rather than blanking a populated card.
 */
export function mergeWorkflowProgress(
  previous: WorkflowProgress | undefined,
  items: unknown,
  meta?: { name?: string; runId?: string; status?: string }
): WorkflowProgress | undefined {
  const hasItems = Array.isArray(items) && items.length > 0;
  const name = meta?.name ?? previous?.name;
  const runId = meta?.runId ?? previous?.runId;
  const status = meta?.status ?? previous?.status;
  // A frame with no progress array — about half of them on the wire — must not
  // blank a populated card, and must not manufacture an empty one either.
  if (!hasItems) {
    if (!previous) return name === undefined && runId === undefined ? undefined : emptyWorkflow(name, runId);
    if (name === previous.name && runId === previous.runId && status === previous.status) {
      return previous;
    }
    return { ...previous, name, runId, status };
  }
  const base = previous ?? emptyWorkflow(name, runId);
  const merged: WorkflowProgress = { ...base, name, runId, status };
  const list = items as unknown[];

  const phases = merged.phases.slice();
  const agents = merged.agents.slice();
  const logs = merged.logs.slice();
  let logCursor = 0;

  for (const item of list) {
    if (!isPlainObject(item)) continue;
    const raw = item as Record<string, unknown>;
    const type = asString(raw.type);
    if (type === "workflow_phase") {
      const index = asNumber(raw.index);
      if (index === undefined) continue;
      const phase: WorkflowPhase = {
        index,
        title: asString(raw.title) ?? `#${index}`,
        kind: asString(raw.kind)
      };
      const at = phases.findIndex((existing) => existing.index === index);
      if (at >= 0) phases[at] = phase;
      else phases.push(phase);
      continue;
    }
    if (type === "workflow_agent") {
      const index = asNumber(raw.index);
      if (index === undefined) continue;
      const agent = parseAgent(raw, index);
      const at = agents.findIndex((existing) => existing.index === index);
      if (at >= 0) agents[at] = agent;
      else agents.push(agent);
      continue;
    }
    if (type === "workflow_log") {
      const message = asString(raw.message);
      if (message === undefined) continue;
      // Replay of a line already held, matched positionally: the CLI resends the
      // whole (possibly trimmed) list every frame.
      if (logCursor < logs.length) {
        logs[logCursor] = message;
        logCursor += 1;
        continue;
      }
      logs.push(message);
      logCursor = logs.length;
    }
  }

  merged.phases = phases;
  merged.agents = agents;
  merged.logs = logs;
  merged.totals = totalsFor(agents);
  return merged;
}

/** Agents grouped under their phase, in phase order, then in array order. */
export function groupByPhase(
  workflow: WorkflowProgress
): Array<{ phase?: WorkflowPhase; agents: WorkflowAgent[] }> {
  const groups: Array<{ phase?: WorkflowPhase; agents: WorkflowAgent[] }> = [];
  const byIndex = new Map<number, { phase?: WorkflowPhase; agents: WorkflowAgent[] }>();
  for (const phase of workflow.phases) {
    const group = { phase, agents: [] as WorkflowAgent[] };
    byIndex.set(phase.index, group);
    groups.push(group);
  }
  // An agent whose phase was never declared still has to render: the CLI
  // announces phases as the script reaches them, so a workflow that calls
  // `agent()` before its first `phase()` produces exactly this.
  let loose: { phase?: WorkflowPhase; agents: WorkflowAgent[] } | undefined;
  for (const agent of workflow.agents) {
    const group = agent.phaseIndex !== undefined ? byIndex.get(agent.phaseIndex) : undefined;
    if (group) {
      group.agents.push(agent);
      continue;
    }
    if (!loose) {
      loose = { agents: [] };
      groups.push(loose);
    }
    loose.agents.push(agent);
  }
  return groups.filter((group) => group.agents.length > 0 || group.phase !== undefined);
}

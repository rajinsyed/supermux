import type { WorkflowAgent, WorkflowAgentState, WorkflowProgress } from "../../model/types";

/**
 * The workflow browser's left column: one row per phase, carrying the counts
 * the CLI prints beside each title.
 *
 * `groupByPhase` in the model already answers "which agents belong to which
 * phase"; this adds the per-phase tallies and a stable `key`, because the
 * browser SELECTS a phase and a selection keyed on array position would jump to
 * a different phase the moment the workflow declares a new one mid-run.
 */
export interface PhaseGroup {
  key: string;
  /** Absent for the loose group holding agents whose phase was never declared. */
  index?: number;
  title?: string;
  agents: WorkflowAgent[];
  done: number;
  total: number;
  running: number;
  failed: number;
  /** Every agent has finished one way or another (and there is at least one). */
  complete: boolean;
}

const LOOSE_KEY = "loose";

function keyOf(index: number | undefined): string {
  return index === undefined ? LOOSE_KEY : `phase-${index}`;
}

/**
 * Phases in declaration order, each with its agents and its done count.
 *
 * A phase the script has declared but not reached yet keeps its row with zero
 * agents — the CLI announces phases ahead of running them, and dropping the
 * empty ones would make the plan appear one phase at a time. Agents whose phase
 * was never declared fall into a trailing loose group rather than vanishing.
 */
export function phaseGroups(workflow: WorkflowProgress | undefined): PhaseGroup[] {
  if (!workflow) return [];
  const groups: PhaseGroup[] = [];
  const byIndex = new Map<number, PhaseGroup>();
  for (const phase of workflow.phases) {
    const group: PhaseGroup = {
      key: keyOf(phase.index),
      index: phase.index,
      title: phase.title,
      agents: [],
      done: 0,
      total: 0,
      running: 0,
      failed: 0,
      complete: false
    };
    byIndex.set(phase.index, group);
    groups.push(group);
  }
  let loose: PhaseGroup | undefined;
  for (const agent of workflow.agents) {
    let group = agent.phaseIndex !== undefined ? byIndex.get(agent.phaseIndex) : undefined;
    if (!group) {
      if (!loose) {
        loose = {
          key: LOOSE_KEY,
          agents: [],
          done: 0,
          total: 0,
          running: 0,
          failed: 0,
          complete: false
        };
        groups.push(loose);
      }
      group = loose;
    }
    group.agents.push(agent);
    group.total += 1;
    // `cached` counts as done: the agent produced its result, the workflow just
    // did not have to pay for it again. A cached agent parked in the "not done"
    // column would make a fully-resolved phase read as stalled.
    if (agent.state === "done" || agent.state === "cached") group.done += 1;
    else if (agent.state === "running") group.running += 1;
    else if (agent.state === "error") group.failed += 1;
  }
  for (const group of groups) {
    group.complete = group.total > 0 && group.done + group.failed === group.total;
  }
  return groups;
}

/**
 * The phase the workflow is working on right now: the first with a running
 * agent, else the first that has not finished, else the last one (a settled
 * workflow's "current" phase is the one it ended in).
 */
export function currentPhaseKey(groups: PhaseGroup[]): string | undefined {
  if (groups.length === 0) return undefined;
  const running = groups.find((group) => group.running > 0);
  if (running) return running.key;
  const unfinished = groups.find((group) => !group.complete);
  if (unfinished) return unfinished.key;
  return groups[groups.length - 1].key;
}

export interface Selection {
  phaseKey: string;
  /**
   * The `index` of the selected agent — the wire's own stable key — NOT its
   * position in the list. A workflow that declares a new agent mid-run reorders
   * nothing, but a positional selection would still slide onto a different
   * agent the moment one arrives ahead of it.
   */
  agentIndex?: number;
}

export function agentAt(groups: PhaseGroup[], selection: Selection | undefined): WorkflowAgent | undefined {
  if (!selection || selection.agentIndex === undefined) return undefined;
  const group = groups.find((candidate) => candidate.key === selection.phaseKey);
  return group?.agents.find((agent) => agent.index === selection.agentIndex);
}

export function groupAt(groups: PhaseGroup[], selection: Selection | undefined): PhaseGroup | undefined {
  if (!selection) return undefined;
  return groups.find((candidate) => candidate.key === selection.phaseKey);
}

/**
 * Keep a selection pointing at something that still exists.
 *
 * The workflow advances underneath the browser: phases are declared, agents
 * appear, and a selection made three frames ago has to survive all of it. A
 * phase that disappears (it cannot today, but the wire is cumulative rather
 * than guaranteed) falls back to the current phase; an agent that disappears
 * falls back to its phase with no agent selected.
 */
export function normalizeSelection(
  groups: PhaseGroup[],
  selection: Selection | undefined
): Selection | undefined {
  if (groups.length === 0) return undefined;
  const fallback = currentPhaseKey(groups);
  if (!selection) return fallback ? { phaseKey: fallback } : undefined;
  const group = groups.find((candidate) => candidate.key === selection.phaseKey);
  if (!group) return fallback ? { phaseKey: fallback } : undefined;
  if (selection.agentIndex === undefined) return selection;
  const agent = group.agents.find((candidate) => candidate.index === selection.agentIndex);
  return agent ? selection : { phaseKey: group.key };
}

/**
 * ↑ / ↓ in whichever column the reader is in.
 *
 * With an agent selected the keys walk the agents of that phase and stop at its
 * ends — stepping off the end into the neighbouring phase's list would change
 * BOTH panes on one keypress, which is disorienting when the right pane is a
 * detail view. With no agent selected they walk the phase list.
 */
export function moveSelection(
  groups: PhaseGroup[],
  selection: Selection | undefined,
  delta: number
): Selection | undefined {
  const current = normalizeSelection(groups, selection);
  if (!current) return undefined;
  const groupAtIndex = groups.findIndex((candidate) => candidate.key === current.phaseKey);
  if (current.agentIndex === undefined) {
    if (groups.length === 0) return current;
    const next = clamp(groupAtIndex + delta, 0, groups.length - 1);
    return { phaseKey: groups[next].key };
  }
  const agents = groups[groupAtIndex]?.agents ?? [];
  const at = agents.findIndex((agent) => agent.index === current.agentIndex);
  if (at < 0) return { phaseKey: current.phaseKey };
  const next = clamp(at + delta, 0, agents.length - 1);
  return { phaseKey: current.phaseKey, agentIndex: agents[next].index };
}

/** ⏎ / → : step INTO the selected phase, landing on its first agent. */
export function descend(
  groups: PhaseGroup[],
  selection: Selection | undefined
): Selection | undefined {
  const current = normalizeSelection(groups, selection);
  if (!current || current.agentIndex !== undefined) return current;
  const group = groups.find((candidate) => candidate.key === current.phaseKey);
  const first = group?.agents[0];
  return first ? { phaseKey: current.phaseKey, agentIndex: first.index } : current;
}

/**
 * Esc / ← : one level out. `undefined` means there is no level left and the
 * browser itself should close — the view stack above decides where that goes.
 */
export function ascend(selection: Selection | undefined): Selection | undefined {
  if (selection && selection.agentIndex !== undefined) return { phaseKey: selection.phaseKey };
  return undefined;
}

function clamp(value: number, low: number, high: number): number {
  return value < low ? low : value > high ? high : value;
}

/**
 * What an agent's row and detail should SAY, given that the workflow itself has
 * settled.
 *
 * A run the user stopped freezes its last progress frame forever, so an agent
 * caught mid-flight reports `running` for the rest of the session. No further
 * frame will ever demote it — displaying it as running means a spinner and a
 * climbing clock on work that is already dead, which is the stop latch the
 * reducer keeps and the browser has to render.
 */
export type DisplayState = WorkflowAgentState | "stopped";

export function displayState(agent: WorkflowAgent, interrupted: boolean): DisplayState {
  return interrupted && agent.state === "running" ? "stopped" : agent.state;
}

/** A workflow status the user (or a failure) has ended. */
export function workflowInterrupted(status: string | undefined): boolean {
  return status === "completed" || status === "failed" || status === "killed" || status === "stopped";
}

export function workflowStopped(status: string | undefined): boolean {
  return status === "killed" || status === "stopped";
}

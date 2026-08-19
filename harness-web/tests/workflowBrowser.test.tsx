import { afterEach, describe, expect, test } from "bun:test";
import { useState } from "react";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { taskBridgeStub } from "./bridgeStub";
import {
  withWorkflowActivity,
  withWorkflowLogs,
  workflowFixture
} from "../src/dev/fixtures/round3";
import { round3SubagentTranscripts } from "../src/dev/fixtures/subagentTranscripts";
import { applyLine, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { Block, ToolBlock, TranscriptModel, WorkflowAgent } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { ToolCard } from "../src/ui/tools/ToolCard";
import { OpenViewContext } from "../src/ui/views/OpenViewContext";
import type { HarnessView } from "../src/ui/views/viewStack";
import { WorkflowBrowser } from "../src/ui/workflow/WorkflowBrowser";
import { WorkflowView } from "../src/ui/workflow/WorkflowView";
import {
  ascend,
  currentPhaseKey,
  descend,
  displayState,
  moveSelection,
  normalizeSelection,
  phaseGroups,
  type Selection
} from "../src/ui/workflow/browserModel";
import { agentDocumentFromLines } from "../src/ui/workflow/agentDocument";
import { subjectFromBlock, subjectFromTask } from "../src/ui/workflow/subject";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

/** The probe, plus the log lines and per-agent activity the dev scenario feeds. */
const FLOW = withWorkflowActivity(withWorkflowLogs(workflowFixture));

function replayThrough(lines: ProtocolLine[], count: number): TranscriptModel {
  const index = createIndex();
  let model = createModel();
  for (const line of lines.slice(0, count)) model = applyLine(model, index, line, Date.now());
  return model;
}

function tools(model: TranscriptModel): ToolBlock[] {
  const out: ToolBlock[] = [];
  const walk = (blocks: Block[]) => {
    for (const block of blocks) {
      if (block.kind !== "tool") continue;
      out.push(block);
      walk(block.children);
    }
  };
  for (const turn of model.turns) walk(turn.blocks);
  return out;
}

function workflowBlock(model: TranscriptModel): ToolBlock {
  return tools(model).find((tool) => tool.name === "Workflow")!;
}

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

function installBridge(overrides: Partial<HarnessBridge> = {}): { calls: string[] } {
  const calls: string[] = [];
  window.supermuxHarnessMock = {
    ...taskBridgeStub,
    stopTask: (params) => {
      calls.push(`stopTask:${params.taskId}`);
      return Promise.resolve();
    },
    loadSubagentTranscript: (params) => {
      calls.push(`load:${params.workflowRunId ?? ""}/${params.agentId ?? ""}`);
      const events =
        round3SubagentTranscripts[`${params.workflowRunId}/${params.agentId}`] ?? undefined;
      return Promise.resolve(
        events
          ? { events, truncated: false }
          : { events: [], truncated: false, missing: true }
      );
    },
    ...overrides
  } as HarnessBridge;
  return { calls };
}

async function flush(ms = 40) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

/**
 * The row and the router together, which is how a workflow is actually reached:
 * the row hands the run's task id to `openView`, and the router mounts
 * `WorkflowView` for it. Rendering both means every browser assertion below is
 * also an assertion that the row routes to the right run.
 */
function RoutedPane({ model }: { model: TranscriptModel }) {
  const [view, setView] = useState<HarnessView>({ kind: "main" });
  return (
    <OpenViewContext.Provider value={setView}>
      {view.kind === "workflow" ? (
        <WorkflowView model={model} taskId={view.taskId} onBack={() => setView({ kind: "main" })} />
      ) : (
        <ToolCard block={workflowBlock(model)} />
      )}
    </OpenViewContext.Provider>
  );
}

function openBrowser(model: TranscriptModel) {
  const result = mount(<RoutedPane model={model} />);
  fireEvent.click(result.container.querySelector<HTMLElement>(".wf-row")!);
  return result;
}

function texts(root: ParentNode, selector: string): (string | null)[] {
  return Array.from(root.querySelectorAll(selector)).map((node) => node.textContent);
}

// ---------------------------------------------------------------------------
// Pure model
// ---------------------------------------------------------------------------

describe("phase grouping and done counts", () => {
  const finished = replayLines(FLOW);
  const workflow = workflowBlock(finished).workflow!;

  test("agents group under their declared phase, in declaration order", () => {
    const groups = phaseGroups(workflow);
    expect(groups.map((group) => group.title)).toEqual(["Gather", "Merge"]);
    expect(groups[0].agents.map((agent) => agent.label)).toEqual(["agent-alpha", "agent-beta"]);
    expect(groups[1].agents.map((agent) => agent.label)).toEqual(["merger"]);
  });

  test("each phase counts its own done, not the workflow's", () => {
    // Cut where Gather's first agent is done and its second is still running:
    // a per-phase count that summed the whole run would read 1/3 in both rows.
    const midway = replayThrough(FLOW, 39);
    const groups = phaseGroups(workflowBlock(midway).workflow);
    expect(groups[0].done).toBe(1);
    expect(groups[0].total).toBe(2);
    expect(groups[1].total).toBe(0);
  });

  test("a cached agent counts as done", () => {
    // It produced its result; the workflow just did not pay for it again.
    // Parked in the "not done" column, a fully resolved phase reads as stalled.
    const groups = phaseGroups({
      ...workflow,
      agents: workflow.agents.map((agent, i) =>
        i === 0 ? ({ ...agent, state: "cached", cached: true } as WorkflowAgent) : agent
      )
    });
    expect(groups[0].done).toBe(2);
    expect(groups[0].complete).toBe(true);
  });

  test("a declared phase with no agents yet keeps its row", () => {
    // The CLI announces phases ahead of running them; dropping the empty ones
    // would reveal the plan one phase at a time.
    const early = replayThrough(FLOW, 33);
    const groups = phaseGroups(workflowBlock(early).workflow);
    expect(groups.length).toBe(2);
    expect(groups[1].total).toBe(0);
  });

  test("an agent whose phase was never declared still gets a group", () => {
    const groups = phaseGroups({
      ...workflow,
      phases: [],
      agents: workflow.agents
    });
    expect(groups.length).toBe(1);
    expect(groups[0].title).toBeUndefined();
    expect(groups[0].agents.length).toBe(3);
  });

  test("the current phase is the one with work in it", () => {
    const midway = replayThrough(FLOW, 39);
    const groups = phaseGroups(workflowBlock(midway).workflow);
    expect(currentPhaseKey(groups)).toBe(groups[0].key);
    // Everything finished: the last phase is where the run ended.
    expect(currentPhaseKey(phaseGroups(workflow))).toBe("phase-2");
  });
});

describe("the selection model", () => {
  const groups = phaseGroups(replayLines(FLOW).turns.flatMap(() => [])[0] ?? undefined);
  const full = phaseGroups(workflowBlock(replayLines(FLOW)).workflow);

  test("no selection resolves to the current phase", () => {
    expect(normalizeSelection(full, undefined)).toEqual({ phaseKey: "phase-2" });
    expect(groups.length).toBe(0);
  });

  test("↑↓ walk the phase list while no agent is selected", () => {
    let selection: Selection | undefined = { phaseKey: "phase-1" };
    selection = moveSelection(full, selection, 1);
    expect(selection).toEqual({ phaseKey: "phase-2" });
    // And stop at the end rather than wrapping round to the top.
    expect(moveSelection(full, selection, 1)).toEqual({ phaseKey: "phase-2" });
    expect(moveSelection(full, { phaseKey: "phase-1" }, -1)).toEqual({ phaseKey: "phase-1" });
  });

  test("⏎ steps into the phase, landing on its first agent", () => {
    expect(descend(full, { phaseKey: "phase-1" })).toEqual({
      phaseKey: "phase-1",
      agentIndex: 1
    });
  });

  test("↑↓ then walk the agents of THAT phase, and stop at its ends", () => {
    const inside: Selection = { phaseKey: "phase-1", agentIndex: 1 };
    expect(moveSelection(full, inside, 1)).toEqual({ phaseKey: "phase-1", agentIndex: 2 });
    // Stepping off the end would change BOTH panes on one keypress.
    expect(moveSelection(full, { phaseKey: "phase-1", agentIndex: 2 }, 1)).toEqual({
      phaseKey: "phase-1",
      agentIndex: 2
    });
    expect(moveSelection(full, inside, -1)).toEqual(inside);
  });

  test("esc steps out one level, then leaves the browser", () => {
    expect(ascend({ phaseKey: "phase-1", agentIndex: 2 })).toEqual({ phaseKey: "phase-1" });
    expect(ascend({ phaseKey: "phase-1" })).toBeUndefined();
  });

  test("a selection is keyed on the agent's wire index, not its position", () => {
    // A workflow that declares an agent mid-run must not slide the selection
    // onto a different agent.
    const reordered = full.map((group) => ({ ...group, agents: group.agents.slice().reverse() }));
    expect(normalizeSelection(reordered, { phaseKey: "phase-1", agentIndex: 2 })).toEqual({
      phaseKey: "phase-1",
      agentIndex: 2
    });
  });

  test("a selection whose agent has gone falls back to its phase", () => {
    expect(normalizeSelection(full, { phaseKey: "phase-1", agentIndex: 99 })).toEqual({
      phaseKey: "phase-1"
    });
    expect(normalizeSelection(full, { phaseKey: "phase-99" })).toEqual({ phaseKey: "phase-2" });
  });
});

describe("the stop latch", () => {
  const finished = replayLines(FLOW);
  const running = workflowBlock(replayThrough(FLOW, 37)).workflow!.agents.find(
    (agent) => agent.state === "running"
  )!;

  test("a running agent caught by a stop displays as stopped, not running", () => {
    // The workflow's last progress frame says `running` forever — no further
    // frame will ever demote it — so a spinner and a climbing clock would be
    // counting work that is already dead.
    expect(displayState(running, true)).toBe("stopped");
    expect(displayState(running, false)).toBe("running");
  });

  test("an agent that finished before the stop keeps its own verdict", () => {
    const done = workflowBlock(finished).workflow!.agents[0];
    expect(displayState(done, true)).toBe("done");
  });
});

describe("the subject normalises both sources", () => {
  test("a launching block carries the runId the task frames never do", () => {
    const block = workflowBlock(replayLines(FLOW));
    const subject = subjectFromBlock(block);
    expect(subject.runId).toBe("wf_c0f60243-4f1");
    expect(subject.taskId).toBe("wxajrgc4u");
    expect(subject.name).toBe("alpha-beta-demo");
  });

  test("a task record answers the same questions after the turn folds away", () => {
    const model = replayLines(FLOW);
    const subject = subjectFromTask(model.tasksById.wxajrgc4u);
    expect(subject.runId).toBe("wf_c0f60243-4f1");
    expect(subject.name).toBe("alpha-beta-demo");
    expect(subject.workflow?.totals.agents).toBe(3);
  });
});

describe("the disk document", () => {
  test("the first user row is the prompt and the last assistant text the outcome", () => {
    const document = agentDocumentFromLines(
      round3SubagentTranscripts["wf_c0f60243-4f1/a3591a4cc25d2d4ab"]
    );
    expect(document.prompt).toContain("Combine these two words");
    expect(document.outcome).toContain("alphabeta, betaalpha");
    // Longer than the preview — otherwise expanding would swap one string for
    // the identical string and demonstrate nothing.
    expect(document.outcome!.length).toBeGreaterThan("alphabeta, betaalpha".length);
  });
});

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

describe("the inline row replaces the card", () => {
  test("a Workflow tool renders one row, not a phase tree", () => {
    const { container } = mount(<ToolCard block={workflowBlock(replayLines(FLOW))} />);
    expect(container.querySelector(".wf-row")).not.toBeNull();
    expect(container.querySelector(".workflow-card")).toBeNull();
    expect(container.querySelector(".wf-phases")).toBeNull();
    expect(container.querySelector(".wfb-panes")).toBeNull();
  });

  test("the row says what the run is and how far it got", () => {
    const { container } = mount(<ToolCard block={workflowBlock(replayLines(FLOW))} />);
    const row = container.querySelector(".wf-row")!;
    expect(container.querySelector(".wf-row-name")!.textContent).toBe("alpha-beta-demo");
    expect(row.textContent).toContain("3/3 agents");
    expect(row.textContent).toContain("2 phases");
  });

  test("clicking it opens the browser", () => {
    const { container } = openBrowser(replayLines(FLOW));
    expect(container.querySelector(".wf-browser")).not.toBeNull();
    expect(texts(container, ".wfb-phase-title")).toEqual(["Gather", "Merge"]);
  });
});

describe("the browser's panes", () => {
  test("the phases column carries per-phase done counts", () => {
    const { container } = openBrowser(replayThrough(FLOW, 39));
    const counts = texts(container, ".wfb-phase-count");
    expect(counts[0]).toBe("1 of 2 done");
    // A phase the script declared but has not reached says so rather than
    // reporting "0 agents", which reads as a phase that ran empty.
    expect(counts[1]).toBe("Not started");
  });

  test("the right pane lists the selected phase's agents with model and metrics", () => {
    const { container } = openBrowser(replayLines(FLOW));
    // Opens on the CURRENT phase, which for a finished run is the last one.
    expect(texts(container, ".wfb-agent-label")).toEqual(["merger"]);
    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-phase-row")[0]);
    expect(texts(container, ".wfb-agent-label")).toEqual(["agent-alpha", "agent-beta"]);
    expect(container.querySelectorAll(".wfb-agent-row .subagent-model").length).toBe(2);
    expect(container.querySelector(".wfb-agent-tokens")!.textContent).toBe("17k");
  });

  test("a settled agent row carries a state dot; a RUNNING one carries the delegated mark", () => {
    // Round 7's item 4: the browser was the last surface still drawing a
    // breathing dot for running work, so "this agent is working" wore one mark
    // here and a different one in the transcript and the dock two views away. A
    // running agent takes the pixel-grid comet — the same `WorkingGlyph`
    // variant="orbit" the inline agent rows and the dock use — and every
    // SETTLED state keeps its dot.
    const { container } = openBrowser(replayThrough(FLOW, 39));
    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-phase-row")[0]);
    const rows = Array.from(container.querySelectorAll<HTMLElement>(".wfb-agent-row"));

    const done = rows[0].querySelector(".wfb-dot")!;
    expect(done.className).toContain("is-done");
    expect(rows[0].querySelector(".pxgrid")).toBeNull();

    // The running row draws the grid and NO dot — one mark per row, always.
    expect(rows[1].querySelector(".wfb-dot")).toBeNull();
    expect(rows[1].querySelector(".pxgrid.is-orbit")).not.toBeNull();
  });

  test("no surface in the browser animates the retired pulsing dot", async () => {
    // The keyframe both `.wfb-dot.is-running` and `.agent-dot.is-running` drove
    // is gone, and the state colour that stayed behind must never grow an
    // animation back — that is the round-5 mark the loading family exists to be
    // rid of.
    // Comments stripped: both sheets DOCUMENT the retirement, and an assertion
    // that forbids the name outright would forbid saying why it went.
    const strip = async (name: string) =>
      (await Bun.file(new URL(`../src/styles/${name}`, import.meta.url).pathname).text()).replace(
        /\/\*[\s\S]*?\*\//g,
        ""
      );
    const sheet = await strip("workflow.css");
    const agents = await strip("agents.css");
    expect(sheet).not.toContain("dot-breathe");
    expect(agents).not.toContain("dot-breathe");
    expect(/\.wfb-dot\.is-running\s*\{([^}]*)\}/.exec(sheet)![1]).not.toMatch(/animation/);
    // The inline rows never draw a running dot at all.
    expect(agents).not.toMatch(/\.agent-dot\.is-running\s*\{/);
  });

  test("selecting an agent swaps the pane for its detail", () => {
    const { container } = openBrowser(replayLines(FLOW));
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    const detail = container.querySelector(".wfb-detail")!;
    expect(detail.querySelector(".wfb-detail-name")!.textContent).toBe("merger");
    expect(detail.querySelector(".wfb-state")!.textContent).toContain("Done");
    expect(container.querySelector(".wfb-agent-list")).toBeNull();
  });
});

describe("the agent detail", () => {
  function openMerger() {
    const view = openBrowser(replayLines(FLOW));
    fireEvent.click(view.container.querySelector<HTMLElement>(".wfb-agent-row")!);
    return view;
  }

  test("the metrics line is tokens, tool calls, and duration", () => {
    const { container } = openMerger();
    const metrics = container.querySelector(".wfb-detail-metrics")!.textContent!;
    expect(metrics).toContain("17k tokens");
    expect(metrics).toContain("0 tool calls");
    expect(metrics).toContain("2s");
  });

  test("Prompt shows the wire's preview before any bridge call", () => {
    installBridge();
    const { container } = openMerger();
    const sections = texts(container, ".wfb-section-title");
    expect(sections).toEqual(["Prompt", "Activity", "Outcome"]);
    expect(container.querySelector(".wfb-section-body")!.textContent).toBe(
      'Combine these two words into a short result, return both: "alpha" and "beta"'
    );
  });

  test("Activity reports the live tool line, and says so when there is none", () => {
    const live = replayThrough(FLOW, 39);
    const { container } = openBrowser(live);
    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-phase-row")[0]);
    // agent-beta is the one still running, so it is the one with activity.
    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-agent-row")[1]);
    const activity = container.querySelector(".wfb-section-body.is-activity")!;
    expect(activity.textContent).toBe("Reading gather-notes.md");

    cleanup();
    const done = openMerger();
    expect(done.container.querySelector(".wfb-section-body.is-activity")!.textContent).toBe(
      "No tool activity reported."
    );
  });

  test("Outcome shows the preview, and expanding reads the full text from disk", async () => {
    const bridge = installBridge();
    const { container, getAllByText } = openMerger();
    const outcome = () => container.querySelectorAll(".wfb-section")[2];
    expect(outcome().querySelector(".wfb-section-body")!.textContent).toBe("alphabeta, betaalpha");
    expect(bridge.calls).toEqual([]);

    fireEvent.click(getAllByText("Expand")[1]!);
    await flush();
    expect(bridge.calls).toEqual(["load:wf_c0f60243-4f1/a3591a4cc25d2d4ab"]);
    expect(outcome().querySelector(".wfb-section-body")!.textContent).toContain(
      "Both orderings verified against the shell"
    );
  });

  test("expanding the Prompt reads the same file once, and shows the full brief", async () => {
    const bridge = installBridge();
    const { container, getAllByText } = openMerger();
    fireEvent.click(getAllByText("Expand")[0]!);
    await flush();
    expect(bridge.calls.length).toBe(1);
    expect(container.querySelector(".wfb-section-body")!.textContent).toContain(
      "Return the forward concatenation first"
    );
    // The second section expands off the SAME document, with no second read.
    fireEvent.click(getAllByText("Expand")[0]!);
    await flush();
    expect(bridge.calls.length).toBe(1);
  });

  test("a missing transcript keeps the preview and says the rest is unavailable", async () => {
    installBridge({
      async loadSubagentTranscript() {
        return { events: [], truncated: false, missing: true };
      }
    });
    const { container, getAllByText } = openMerger();
    fireEvent.click(getAllByText("Expand")[1]!);
    await flush();
    const outcome = container.querySelectorAll(".wfb-section")[2];
    expect(outcome.querySelector(".wfb-section-body")!.textContent).toBe("alphabeta, betaalpha");
    expect(outcome.querySelector(".wfb-section-note")!.textContent).toContain("not on disk yet");
  });

  test("an errored agent shows its error as the outcome, in the error tone", () => {
    const model = replayLines(FLOW);
    const block = workflowBlock(model);
    const failed: ToolBlock = {
      ...block,
      workflow: {
        ...block.workflow!,
        agents: block.workflow!.agents.map((agent, i) =>
          i === 2
            ? ({ ...agent, state: "error", error: "merger exited 1: no inputs", resultPreview: undefined } as WorkflowAgent)
            : agent
        )
      }
    };
    const { container } = mount(
      <WorkflowBrowser subject={subjectFromBlock(failed)} onClose={() => undefined} />
    );
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    const outcome = container.querySelectorAll(".wfb-section")[2];
    expect(outcome.classList.contains("is-error")).toBe(true);
    expect(outcome.querySelector(".wfb-section-body")!.textContent).toBe(
      "merger exited 1: no inputs"
    );
  });

  test("attempt > 1 and cached earn badges", () => {
    const model = replayLines(FLOW);
    const block = workflowBlock(model);
    const retried: ToolBlock = {
      ...block,
      workflow: {
        ...block.workflow!,
        agents: block.workflow!.agents.map((agent, i) =>
          i === 2 ? ({ ...agent, attempt: 3, cached: true } as WorkflowAgent) : agent
        )
      }
    };
    const { container } = mount(
      <WorkflowBrowser subject={subjectFromBlock(retried)} onClose={() => undefined} />
    );
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    const badges = texts(container, ".wfb-detail-head .tool-badge");
    expect(badges).toContain("Attempt 3");
    expect(badges).toContain("Cached");
  });

  test("Open full transcript routes to the agent chat when there is one", () => {
    const opened: unknown[] = [];
    const model = replayLines(FLOW);
    const { container, getByText } = mount(
      <WorkflowBrowser
        subject={subjectFromBlock(workflowBlock(model))}
        onClose={() => undefined}
        onOpenAgentChat={(target) => {
          opened.push(target);
          return true;
        }}
      />
    );
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    fireEvent.click(getByText("Open full transcript"));
    expect(opened).toEqual([
      { workflowRunId: "wf_c0f60243-4f1", agentId: "a3591a4cc25d2d4ab", label: "merger" }
    ]);
    // It routed, so nothing opened in place.
    expect(container.querySelector(".drill-transcript")).toBeNull();
  });

  test("and falls back to the disk transcript when the router cannot route", async () => {
    // A workflow agent never appears on the wire as an Agent tool_use, so most
    // of them have no thread to open. The affordance must still do something.
    installBridge();
    const model = replayLines(FLOW);
    const { container, getByText } = mount(
      <WorkflowBrowser
        subject={subjectFromBlock(workflowBlock(model))}
        onClose={() => undefined}
        onOpenAgentChat={() => false}
      />
    );
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    fireEvent.click(getByText("Open full transcript"));
    await flush(60);
    expect(container.querySelector(".drill-transcript")).not.toBeNull();
  });
});

describe("the footer hints are real keyboard handlers", () => {
  function browser(model = replayLines(FLOW)) {
    return mount(
      <WorkflowBrowser subject={subjectFromBlock(workflowBlock(model))} onClose={() => undefined} />
    );
  }

  function key(root: ParentNode, name: string) {
    fireEvent.keyDown(root.querySelector(".wf-browser")!, { key: name });
  }

  test("the bar advertises exactly the bindings that exist — and no pause", () => {
    // There is no pause on the wire for workflows (TUI-only), so offering one
    // would be a control that cannot work.
    const { container } = browser(replayThrough(FLOW, 37));
    const hints = container.querySelector(".wfb-hints")!.textContent!;
    expect(hints).toContain("select");
    expect(hints).toContain("Stop workflow");
    expect(hints).toContain("back");
    expect(hints.toLowerCase()).not.toContain("pause");
  });

  test("↑↓ move the phase selection", () => {
    const { container } = browser();
    const active = () => container.querySelector(".wfb-phase-row.is-active")!.textContent;
    expect(active()).toContain("Merge");
    key(container, "ArrowUp");
    expect(active()).toContain("Gather");
    key(container, "ArrowDown");
    expect(active()).toContain("Merge");
  });

  test("⏎ descends into the phase and ↑↓ then move between agents", () => {
    const { container } = browser();
    key(container, "ArrowUp");
    key(container, "Enter");
    expect(container.querySelector(".wfb-detail-name")!.textContent).toBe("agent-alpha");
    key(container, "ArrowDown");
    expect(container.querySelector(".wfb-detail-name")!.textContent).toBe("agent-beta");
  });

  test("esc steps back out one level before leaving the browser", () => {
    let closed = 0;
    const model = replayLines(FLOW);
    const { container } = mount(
      <WorkflowBrowser
        subject={subjectFromBlock(workflowBlock(model))}
        onClose={() => {
          closed += 1;
        }}
      />
    );
    fireEvent.click(container.querySelector<HTMLElement>(".wfb-agent-row")!);
    expect(container.querySelector(".wfb-detail")).not.toBeNull();

    key(container, "Escape");
    // Out of the detail, still in the browser.
    expect(container.querySelector(".wfb-detail")).toBeNull();
    expect(closed).toBe(0);

    key(container, "Escape");
    expect(closed).toBe(1);
  });

  test("x stops the workflow the browser is showing", async () => {
    const bridge = installBridge();
    const { container } = browser(replayThrough(FLOW, 37));
    key(container, "x");
    await flush();
    expect(bridge.calls).toEqual(["stopTask:wxajrgc4u"]);
  });

  test("the Stop hint is a button too, and goes through the same path", async () => {
    const bridge = installBridge();
    const { getByText } = browser(replayThrough(FLOW, 37));
    fireEvent.click(getByText("Stop workflow"));
    await flush();
    expect(bridge.calls).toEqual(["stopTask:wxajrgc4u"]);
  });

  test("x does nothing on a workflow that has already settled", async () => {
    const bridge = installBridge();
    const { container, queryByText } = browser();
    expect(queryByText("Stop workflow")).toBeNull();
    key(container, "x");
    await flush();
    expect(bridge.calls).toEqual([]);
  });

  test("a failed stop says so rather than pretending it worked", async () => {
    installBridge({
      async stopTask() {
        throw new Error("no such task");
      }
    });
    const { container, getByText } = browser(replayThrough(FLOW, 37));
    fireEvent.click(getByText("Stop workflow"));
    await flush();
    expect(container.querySelector(".wf-error")!.textContent).toBe(
      "Could not stop the workflow."
    );
  });
});

describe("a stopped workflow tells the truth about how far it got", () => {
  function stopped(): TranscriptModel {
    const index = createIndex();
    let model = createModel();
    for (const line of FLOW.slice(0, 37)) model = applyLine(model, index, line, Date.now());
    return applyLine(
      model,
      index,
      {
        type: "system",
        subtype: "task_notification",
        task_id: "wxajrgc4u",
        status: "stopped",
        summary: "stopped by user",
        uuid: "wfb-stop-1"
      } as ProtocolLine,
      Date.now()
    );
  }

  test("the header says stopped, with the partial counts kept", () => {
    const { container } = openBrowser(stopped());
    expect(container.querySelector(".wf-stopped-chip")!.textContent).toBe("Stopped");
    const summary = container.querySelector(".wfb-summary")!.textContent!;
    expect(summary).toContain("Stopped");
    expect(summary).toContain("of 2 agents finished");
    expect(container.querySelector(".wfb-hints .btn-kbd")).not.toBeNull();
  });

  test("an agent caught mid-run freezes as stopped, not running", () => {
    const { container } = openBrowser(stopped());
    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-phase-row")[0]);
    const dots = Array.from(container.querySelectorAll(".wfb-agent-row .wfb-dot")).map(
      (node) => node.className
    );
    expect(dots[1]).toContain("is-stopped");

    fireEvent.click(container.querySelectorAll<HTMLElement>(".wfb-agent-row")[1]);
    const state = container.querySelector(".wfb-state")!;
    expect(state.textContent).toContain("Stopped");
    expect(state.className).toContain("is-stopped");
    // No spinner on work that is already dead.
    expect(container.querySelector(".wfb-detail .spinner")).toBeNull();
  });

  test("and the run offers no way to stop it a second time", () => {
    const { container, queryByText } = openBrowser(stopped());
    expect(queryByText("Stop workflow")).toBeNull();
    expect(container.querySelector(".wfb-head .spinner")).toBeNull();
  });
});

describe("the log strip survives the move into the browser", () => {
  test("logs are listed in order behind a toggle", () => {
    const { container, getByText } = openBrowser(replayLines(FLOW));
    const toggle = () => container.querySelector(".wf-logs-toggle")!;
    // `keepMounted`, so the strip's scroll position survives a collapse — its
    // state is the toggle's, not the node's presence.
    expect(toggle().getAttribute("aria-expanded")).toBe("false");
    fireEvent.click(getByText("6 log lines"));
    expect(toggle().getAttribute("aria-expanded")).toBe("true");
    const lines = texts(container, ".wf-logs li");
    expect(lines[0]).toContain("2 phases, 3 agents declared");
    expect(lines[lines.length - 1]).toContain("workflow complete");
  });
});

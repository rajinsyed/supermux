import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { taskBridgeStub } from "./bridgeStub";
import {
  nestedFixture,
  shellsFixture,
  withWorkflowLogs,
  workflowFixture
} from "../src/dev/fixtures/round3";
import { applyLine, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { BannerStack } from "../src/ui/status/BannerStack";
import { TasksStrip } from "../src/ui/status/TasksStrip";
import { ToolCard } from "../src/ui/tools/ToolCard";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

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

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

/** A mock bridge on `window`, which is where `getBridge()` looks in tests. */
function installBridge(overrides: Partial<HarnessBridge>): { calls: string[] } {
  const calls: string[] = [];
  const record = <T,>(name: string, value: T) => {
    calls.push(name);
    return Promise.resolve(value);
  };
  window.supermuxHarnessMock = {
    ...taskBridgeStub,
    stopTask: (params) => record(`stopTask:${params.taskId}`, undefined as void),
    backgroundTask: (params) =>
      record(`backgroundTask:${params.toolUseId ?? "*"}`, { backgrounded: true }),
    readTaskOutput: () => record("readTaskOutput", { text: "", truncated: false, missing: true }),
    loadSubagentTranscript: () =>
      record("loadSubagentTranscript", { events: [], truncated: false, missing: true }),
    ...overrides
  } as HarnessBridge;
  return { calls };
}

async function flush(ms = 30) {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, ms));
  });
}

describe("WorkflowCard", () => {
  const model = replayLines(workflowFixture);
  const block = tools(model).find((tool) => tool.name === "Workflow")!;

  test("a Workflow tool renders the workflow card, not a subagent card", () => {
    const { container } = mount(<ToolCard block={block} />);
    expect(container.querySelector(".workflow-card")).not.toBeNull();
    expect(container.querySelector(".subagent-card")).toBeNull();
  });

  test("phases group their agents, in declaration order", () => {
    const { container } = mount(<ToolCard block={block} />);
    const titles = Array.from(container.querySelectorAll(".wf-phase-title")).map(
      (node) => node.textContent
    );
    expect(titles).toEqual(["Gather", "Merge"]);
    const labels = Array.from(container.querySelectorAll(".wf-agent-label")).map(
      (node) => node.textContent
    );
    expect(labels).toEqual(["agent-alpha", "agent-beta", "merger"]);
  });

  test("every agent carries a state chip and its model", () => {
    const { container } = mount(<ToolCard block={block} />);
    const states = Array.from(container.querySelectorAll(".wf-state")).map((n) => n.textContent);
    expect(states).toEqual(["Done", "Done", "Done"]);
    expect(container.querySelectorAll(".subagent-model").length).toBe(3);
  });

  test("a result preview is behind a disclosure, not printed inline", () => {
    const { container, getAllByText } = mount(<ToolCard block={block} />);
    expect(container.querySelector(".wf-agent-result")).toBeNull();
    fireEvent.click(getAllByText("Show result")[0]);
    expect(container.querySelector(".wf-agent-result")!.textContent).toBe("alpha");
  });

  test("a finished workflow offers no Stop button", () => {
    const { queryByText } = mount(<ToolCard block={block} />);
    expect(queryByText("Stop workflow")).toBeNull();
  });

  test("a RUNNING workflow stops the task it actually launched", async () => {
    const bridge = installBridge({});
    // Cut before the completion frames: agents mid-flight, task still live.
    const live = replayThrough(workflowFixture, 37);
    const running = tools(live).find((tool) => tool.name === "Workflow")!;
    const { getByText } = mount(<ToolCard block={running} />);
    fireEvent.click(getByText("Stop workflow"));
    await flush();
    expect(bridge.calls).toEqual(["stopTask:wxajrgc4u"]);
  });

  test("a STOPPED workflow shows a muted Stopped chip, not a green check", () => {
    // The CLI's kill sequence ends with `task_notification {status: "stopped"}`
    // — replay exactly that against the mid-flight workflow. The card must
    // settle (no spinner, no Stop button) and must NOT claim success.
    const index = createIndex();
    let model = createModel();
    for (const line of workflowFixture.slice(0, 37)) {
      model = applyLine(model, index, line, Date.now());
    }
    model = applyLine(
      model,
      index,
      {
        type: "system",
        subtype: "task_notification",
        task_id: "wxajrgc4u",
        status: "stopped",
        summary: "stopped by user",
        uuid: "stop-test-1"
      } as ProtocolLine,
      Date.now()
    );
    const stoppedBlock = tools(model).find((tool) => tool.name === "Workflow")!;
    const { container, queryByText } = mount(<ToolCard block={stoppedBlock} />);
    const card = container.querySelector(".workflow-card")!;
    expect(card.classList.contains("is-stopped")).toBe(true);
    expect(card.classList.contains("is-done")).toBe(false);
    expect(card.querySelector(".mark-ok")).toBeNull();
    expect(card.querySelector(".wf-stopped-chip")!.textContent).toBe("Stopped");
    expect(queryByText("Stop workflow")).toBeNull();
    expect(card.querySelector(".wf-head .spinner")).toBeNull();
  });

  /**
   * Round-3 critic finding 6: the workflow card was 643px tall expanded with no
   * way to put it away, in a pane where every other card folds from its head.
   */
  describe("the card folds from its head, like every other card", () => {
    test("it opens expanded and the head offers a collapse", () => {
      const { container } = mount(<ToolCard block={block} />);
      const fold = container.querySelector<HTMLElement>(".wf-fold")!;
      expect(fold).not.toBeNull();
      expect(fold.getAttribute("aria-expanded")).toBe("true");
      expect(container.querySelector(".wf-phases")).not.toBeNull();
    });

    test("collapsed, the phases go away and the head is the summary", () => {
      const { container } = mount(<ToolCard block={block} />);
      fireEvent.click(container.querySelector<HTMLElement>(".wf-fold")!);

      const card = container.querySelector(".workflow-card")!;
      expect(card.classList.contains("is-open")).toBe(false);
      expect(container.querySelector<HTMLElement>(".wf-fold")!.getAttribute("aria-expanded")).toBe(
        "false"
      );
      // The head already carries everything a one-line summary would: the name,
      // the badge, the counts, the duration, the tokens, and the outcome mark.
      // Adding a SECOND line repeating them is the duplication finding 7 is
      // about, in a new place.
      expect(container.querySelector(".wf-name")!.textContent).toBe("alpha-beta-demo");
      const meta = container.querySelector(".wf-meta")!.textContent!;
      expect(meta).toContain("Workflow");
      expect(meta).toContain("2 phases");
      expect(meta).toContain("3 of 3 done");
      expect(meta).toContain("tokens");
      expect(card.querySelector(".mark-ok")).not.toBeNull();
      // ...and nothing repeats it.
      expect(container.querySelector(".wf-collapsed")).toBeNull();
    });

    test("reopening finds an expanded log strip exactly where it was", () => {
      // Folding must never be destructive: the body stays mounted, so a reader
      // who collapsed a card to scroll past it gets their state back.
      const withLogs = replayLines(withWorkflowLogs(workflowFixture));
      const logged = tools(withLogs).find((tool) => tool.name === "Workflow")!;
      const { container } = mount(<ToolCard block={logged} />);
      fireEvent.click(container.querySelector<HTMLElement>(".wf-logs-toggle")!);
      const logs = container.querySelector(".wf-logs");
      expect(logs).not.toBeNull();

      fireEvent.click(container.querySelector<HTMLElement>(".wf-fold")!);
      fireEvent.click(container.querySelector<HTMLElement>(".wf-fold")!);
      // The same NODE, which is what carries the scroll position.
      expect(container.contains(logs)).toBe(true);
      expect(container.querySelector<HTMLElement>(".wf-logs-toggle")!.getAttribute("aria-expanded")).toBe(
        "true"
      );
    });
  });

  test("a mid-flight workflow distinguishes queued from running", () => {
    // The wire says `start` for BOTH of these; only the presence of `startedAt`
    // separates an agent the scheduler has accepted from one that has actually
    // begun, and rendering them alike lights up the whole phase at once.
    const live = replayThrough(workflowFixture, 31);
    const running = tools(live).find((tool) => tool.name === "Workflow")!;
    const { container } = mount(<ToolCard block={running} />);
    const states = Array.from(container.querySelectorAll(".wf-state")).map((n) => n.textContent);
    expect(states).toEqual(["Running", "Queued"]);
  });
});

describe("SubagentCard", () => {
  const model = replayLines(nestedFixture);
  const outer = model.turns
    .flatMap((turn) => turn.blocks)
    .find((b): b is ToolBlock => b.kind === "tool" && b.name === "Agent")!;

  test("the nested agent renders as a full card inside its parent", () => {
    const { container, getByText } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Show subagent work"));
    const cards = container.querySelectorAll(".subagent-card");
    expect(cards.length).toBe(2);
    expect(container.querySelector(".subagent-children .subagent-card")).not.toBeNull();
  });

  test("the parent advertises how many agents it nested", () => {
    const { container } = mount(<ToolCard block={outer} />);
    expect(container.textContent).toContain("1 nested agent");
  });

  test("the model chip comes from AgentOutput", () => {
    const { container } = mount(<ToolCard block={outer} />);
    expect(container.querySelector(".subagent-model")!.textContent).toContain("claude-sonnet-5");
  });

  test("Open transcript asks the bridge for THIS agent's task", async () => {
    const bridge = installBridge({});
    const { getByText } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Open transcript"));
    await flush(60);
    expect(bridge.calls).toContain("loadSubagentTranscript");
  });

  test("an absent transcript says so rather than erroring", async () => {
    installBridge({});
    const { getByText, container } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Open transcript"));
    await flush(60);
    expect(container.querySelector(".drill-status")!.textContent).toContain(
      "No transcript on disk yet"
    );
  });

  test("a loaded transcript renders through the ordinary block renderers", async () => {
    installBridge({
      async loadSubagentTranscript() {
        return {
          events: [
            {
              type: "assistant",
              message: {
                id: "m1",
                role: "assistant",
                content: [
                  {
                    type: "tool_use",
                    id: "toolu_drill",
                    name: "Bash",
                    input: { command: "echo drilled" }
                  }
                ]
              },
              uuid: "drill-1"
            } as ProtocolLine
          ],
          truncated: false
        };
      }
    });
    const { getByText, container } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Open transcript"));
    await flush(60);
    const drill = container.querySelector(".subagent-drill")!;
    expect(drill.querySelector(".tool-card")).not.toBeNull();
    expect(drill.textContent).toContain("echo drilled");
  });

  /**
   * A drill-in transcript containing one nested Agent card, whose identity is
   * whatever `agentId` the caller names. A transcript replayed off disk has no
   * system/task_started frames, so that field is the ONLY id the inner card
   * gets — which is what the agentId fallback in SubagentCard exists for.
   */
  function drillWithNestedAgent(agentId: string, description = "Compute 17*3") {
    return [
      {
        type: "assistant",
        message: {
          id: "m_outer",
          role: "assistant",
          content: [
            {
              type: "tool_use",
              id: `toolu_drill_${agentId}`,
              name: "Agent",
              input: { description, prompt: "17*3" }
            }
          ]
        },
        uuid: "outer-drill-1"
      } as ProtocolLine,
      {
        type: "user",
        message: {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: `toolu_drill_${agentId}`, content: "51" }
          ]
        },
        tool_use_result: {
          status: "completed",
          agentId,
          content: [{ type: "text", text: "51" }]
        },
        uuid: "outer-drill-2"
      } as ProtocolLine
    ];
  }

  test("drilling RECURSES: an agent card inside a loaded transcript can open its own", async () => {
    // The agent in the transcript is NOT one the card renders inline, so it is
    // a genuinely new card and must be fully drawn and itself drillable.
    const bridge = installBridge({
      loadSubagentTranscript: (params) => {
        bridge.calls.push(`loadSubagentTranscript:${params.taskId ?? ""}`);
        if (params.taskId === outer.subagent!.taskId) {
          return Promise.resolve({
            events: drillWithNestedAgent("a_disk_only_agent", "Audit the tests"),
            truncated: false
          });
        }
        return Promise.resolve({
          events: [
            {
              type: "assistant",
              message: {
                id: "m_inner",
                role: "assistant",
                content: [{ type: "text", text: "51" }]
              },
              uuid: "inner-drill-1"
            } as ProtocolLine
          ],
          truncated: false
        });
      }
    });
    const { container, getByText } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Open transcript"));
    await flush(60);
    const innerCard = container.querySelector(".drill-transcript .subagent-card")!;
    expect(innerCard).not.toBeNull();
    // The inner card must offer the SAME affordance...
    const innerOpen = Array.from(
      innerCard.querySelectorAll(".subagent-toggle.is-drill")
    );
    expect(innerOpen.length).toBe(1);
    fireEvent.click(innerOpen[0]!);
    await flush(60);
    // ...and drill by the inner agent's own id.
    expect(bridge.calls).toContain("loadSubagentTranscript:a_disk_only_agent");
    // The nested drill-in header carries the breadcrumb of the descent.
    const trail = container.querySelector(".drill-trail");
    expect(trail).not.toBeNull();
    expect(trail!.textContent).toContain("Audit the tests");
  });

  test("a drill-in does NOT redraw an agent the card already shows inline", async () => {
    // The card's inline children are the frames this session streamed; the
    // drill-in is the same agent's file on disk, and that file contains the very
    // same nested tool_use. Rendering both drew ONE agent as TWO full cards
    // inside one card, wearing different chips — the disk copy has an agentId
    // but no task frames, so no live metrics — which reads as two agents that
    // did identical work.
    installBridge({
      loadSubagentTranscript: () =>
        // a9728442495aacb2c is the inner agent the fixture already nests inline.
        Promise.resolve({ events: drillWithNestedAgent("a9728442495aacb2c"), truncated: false })
    });
    const { container, getByText, getAllByText } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Show subagent work"));
    // The revealed inner card offers its own "Open transcript"; the outer card's
    // is the first in document order.
    fireEvent.click(getAllByText("Open transcript")[0]!);
    await flush(60);

    // The inline child keeps its full card...
    expect(container.querySelector(".subagent-children .subagent-card")).not.toBeNull();
    // ...and the drill-in's copy is a marker pointing at it, not a second card.
    expect(container.querySelector(".drill-transcript .subagent-card")).toBeNull();
    const marker = container.querySelector(".drill-transcript .subagent-dup")!;
    expect(marker).not.toBeNull();
    expect(marker.textContent).toContain("Compute 17*3");
    expect(marker.textContent).toContain("shown above");
    // Exactly one card for the inner agent anywhere in the tree.
    expect(container.querySelectorAll(".subagent-card").length).toBe(2);
  });

  test("completed toolStats render as a files/lines summary", () => {
    const withStats: ToolBlock = {
      ...outer,
      subagent: {
        ...outer.subagent,
        toolStats: {
          readCount: 12,
          editFileCount: 3,
          searchCount: 4,
          bashCount: 1,
          linesAdded: 40,
          linesRemoved: 7
        }
      }
    };
    const { container } = mount(<ToolCard block={withStats} />);
    const stats = container.querySelector(".subagent-stats")!.textContent!;
    expect(stats).toContain("edited 3 files");
    expect(stats).toContain("+40 −7");
    expect(stats).toContain("read 12 files");
    expect(stats).toContain("1 command");
  });
});

describe("background Bash card", () => {
  test("a backgrounded command wears a badge and a live status chip", () => {
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { container } = mount(<ToolCard block={bash} />);
    const badges = container.querySelector(".tool-badges")!.textContent!;
    expect(badges).toContain("Background");
    expect(badges).toContain("Still running");
  });

  test("its card chrome follows the TASK, not the instant tool_result", () => {
    // A backgrounded Bash's tool_result lands immediately ("running in
    // background with ID…"), which is a success — but the command is still
    // running, and a green check beside a "Still running" badge is one row
    // contradicting itself.
    // Through index 27: the backgrounded Bash's own tool_result has landed.
    const live = replayThrough(shellsFixture, 27);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    expect(bash.status).toBe("success"); // the block itself settled
    const { container } = mount(<ToolCard block={bash} />);
    const card = container.querySelector(".tool-card")!;
    expect(card.classList.contains("is-running")).toBe(true);
    expect(card.querySelector(".tool-status .mark-ok")).toBeNull();
    expect(card.querySelector(".tool-status .spinner")).not.toBeNull();
  });

  test("once the task is stopped the card settles as stopped, not success", () => {
    const settled = replayThrough(shellsFixture, shellsFixture.length);
    const bash = tools(settled).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    expect(bash.subagent?.status).toBe("stopped");
    const { container } = mount(<ToolCard block={bash} />);
    const card = container.querySelector(".tool-card")!;
    expect(card.classList.contains("is-running")).toBe(false);
    expect(card.querySelector(".tool-status .mark-ok")).toBeNull();
  });

  test("Show output tails the task file rather than the transcript", async () => {
    const bridge = installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { getByText } = mount(<ToolCard block={bash} />);
    fireEvent.click(getByText("Show output"));
    await flush(60);
    expect(bridge.calls).toContain("readTaskOutput");
  });

  test("a RUNNING foreground command offers Move to background", async () => {
    const bridge = installBridge({});
    const live = replayThrough(shellsFixture, 32);
    const foreground = tools(live).find(
      (tool) => tool.name === "Bash" && tool.subagent === undefined && tool.status === "running"
    );
    // The probe's second Bash returns within the same slice, so drive the state
    // this affordance exists for explicitly rather than asserting on a shape the
    // fixture does not hold.
    const block: ToolBlock = foreground ?? {
      ...tools(live).find((tool) => tool.name === "Bash" && tool.subagent === undefined)!,
      status: "running",
      endedAtMs: undefined,
      resultText: undefined,
      structured: undefined
    };
    const { getByText } = mount(<ToolCard block={block} />);
    fireEvent.click(getByText("Move to background"));
    await flush();
    expect(bridge.calls).toEqual([`backgroundTask:${block.toolUseId}`]);
  });

  /**
   * Round-3 critic finding 7: a settled background-Bash card printed its own
   * description twice — once as the head's subtitle, once as bare grey prose
   * below — because `task_notification.summary` for a shell is very often the
   * command's `description` verbatim.
   */
  describe("a settled card does not repeat what its head already says", () => {
    test("a summary equal to the description is suppressed", () => {
      const settled = replayThrough(shellsFixture, shellsFixture.length);
      const bash = tools(settled).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
      // The probe really does send them identical — that is the finding.
      const summary = bash.subagent!.summary!;
      expect(summary).toBe(String(bash.input.description));
      const { container } = mount(<ToolCard block={bash} />);
      expect(container.querySelector(".bash-bg-summary")).toBeNull();
      // Said exactly once, by the head.
      expect(container.textContent!.split(summary).length - 1).toBe(1);
    });

    test("a summary that carries real news still gets its row", () => {
      // Suppression is scoped to repeats: an outcome the head cannot show is
      // exactly what this row is for.
      const settled = replayThrough(shellsFixture, shellsFixture.length);
      const bash = tools(settled).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
      const informative: ToolBlock = {
        ...bash,
        subagent: { ...bash.subagent, summary: "exit 1: no such file or directory" }
      };
      const { container } = mount(<ToolCard block={informative} />);
      expect(container.querySelector(".bash-bg-summary")!.textContent).toBe(
        "exit 1: no such file or directory"
      );
    });

    test("a summary equal to the COMMAND is suppressed too", () => {
      // The head's headline is the command's first line, so that is a repeat as
      // much as the description is.
      const settled = replayThrough(shellsFixture, shellsFixture.length);
      const bash = tools(settled).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
      const echoed: ToolBlock = {
        ...bash,
        subagent: { ...bash.subagent, summary: String(bash.input.command).split("\n")[0] }
      };
      const { container } = mount(<ToolCard block={echoed} />);
      expect(container.querySelector(".bash-bg-summary")).toBeNull();
    });
  });

  test("a backgrounded command offers Stop, not Move to background", () => {
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { queryByText, getByText } = mount(<ToolCard block={bash} />);
    expect(queryByText("Move to background")).toBeNull();
    expect(getByText("Stop")).toBeDefined();
  });
});

/**
 * Round-3 critic finding 10: Escape closed the Bash card's output tail and
 * neither of the two agent drill-ins, so on those it fell through to the
 * composer and interrupted the turn the reader was inspecting.
 */
describe("Escape closes every inline drill-in, and only when focus is in one", () => {
  /**
   * Escape from a real focused element, as the browser delivers it — a window
   * capture listener is what the shared contract installs, so a synthetic
   * fireEvent on the React tree would not exercise it.
   */
  function escapeFrom(node: HTMLElement): KeyboardEvent {
    node.focus();
    const event = new KeyboardEvent("keydown", {
      key: "Escape",
      bubbles: true,
      cancelable: true
    });
    act(() => {
      node.dispatchEvent(event);
    });
    return event;
  }

  /** `aria-expanded` on the toggle, which is the state the disclosure reflects. */
  function expanded(node: Element | null): string | null {
    return node?.getAttribute("aria-expanded") ?? null;
  }

  test("the Bash card's output tail", async () => {
    installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { container, getByText } = mount(<ToolCard block={bash} />);
    fireEvent.click(getByText("Show output"));
    await flush(60);
    const toggle = () => container.querySelector('.bash-bg-actions button[aria-expanded]');
    expect(expanded(toggle())).toBe("true");

    const event = escapeFrom(toggle() as HTMLElement);
    // Consumed here rather than reaching the composer, whose Escape interrupts.
    expect(event.defaultPrevented).toBe(true);
    await flush(60);
    expect(expanded(toggle())).toBe("false");
  });

  test("a subagent card's drill-in transcript", async () => {
    installBridge({});
    const model = replayLines(nestedFixture);
    const outer = model.turns
      .flatMap((turn) => turn.blocks)
      .find((b): b is ToolBlock => b.kind === "tool" && b.name === "Agent")!;
    const { container, getByText } = mount(<ToolCard block={outer} />);
    fireEvent.click(getByText("Open transcript"));
    await flush(60);
    const toggle = () => container.querySelector(".subagent-toggle.is-drill");
    expect(expanded(toggle())).toBe("true");

    const event = escapeFrom(toggle() as HTMLElement);
    expect(event.defaultPrevented).toBe(true);
    await flush(60);
    expect(expanded(toggle())).toBe("false");
  });

  test("a workflow card's per-agent drill-in", async () => {
    installBridge({});
    const model = replayLines(workflowFixture);
    const wf = tools(model).find((tool) => tool.name === "Workflow")!;
    const { container, getAllByText } = mount(<ToolCard block={wf} />);
    const drillToggle = () =>
      Array.from(container.querySelectorAll(".wf-agent .wf-agent-toggle")).find((node) =>
        /transcript/i.test(node.textContent ?? "")
      );
    fireEvent.click(getAllByText("Open agent transcript")[0]!);
    await flush(60);
    expect(expanded(drillToggle() ?? null)).toBe("true");

    const event = escapeFrom(drillToggle() as HTMLElement);
    expect(event.defaultPrevented).toBe(true);
    await flush(60);
    expect(expanded(drillToggle() ?? null)).toBe("false");
  });

  test("the tasks strip's per-agent drill-in, and then the row detail itself", async () => {
    // Two nested disclosures, so Escape steps out ONE level at a time rather
    // than collapsing everything the reader opened at once.
    installBridge({});
    const live = replayThrough(workflowFixture, 35);
    const { container, getByText } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    fireEvent.click(getByText("View"));
    await flush(60);
    const agent = () => container.querySelector(".task-wf-agent .wf-agent-toggle");
    const row = () => container.querySelector(".task-action[aria-expanded]");
    fireEvent.click(agent() as HTMLElement);
    await flush(60);
    expect(expanded(agent())).toBe("true");
    expect(expanded(row())).toBe("true");

    expect(escapeFrom(agent() as HTMLElement).defaultPrevented).toBe(true);
    await flush(60);
    expect(expanded(agent())).toBe("false");
    // The row detail is still open — one level, one Escape.
    expect(expanded(row())).toBe("true");

    expect(escapeFrom(row() as HTMLElement).defaultPrevented).toBe(true);
    await flush(60);
    expect(expanded(row())).toBe("false");
  });

  test("Escape with nothing open is left alone, so the composer still interrupts", async () => {
    // The whole point of scoping to focus: a global handler would swallow
    // Escape-to-interrupt for as long as any drill-in was open anywhere.
    installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { container } = mount(<ToolCard block={bash} />);
    const event = escapeFrom(
      container.querySelector<HTMLElement>(".bash-bg-actions button[aria-expanded]")!
    );
    expect(event.defaultPrevented).toBe(false);
  });

  test("Escape from OUTSIDE an open drill-in is left alone too", async () => {
    installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { container, getByText } = mount(<ToolCard block={bash} />);
    fireEvent.click(getByText("Show output"));
    await flush(60);

    // A composer-shaped element outside the card: its Escape is the interrupt.
    const outside = document.createElement("textarea");
    document.body.appendChild(outside);
    const event = escapeFrom(outside);
    expect(event.defaultPrevented).toBe(false);
    expect(expanded(container.querySelector(".bash-bg-actions button[aria-expanded]"))).toBe(
      "true"
    );
    outside.remove();
  });
});

describe("the finished-task banner", () => {
  test("renders the outcome, with the task's name as its subject", () => {
    const model = replayLines(shellsFixture);
    const { container } = mount(
      <BannerStack banners={model.banners} onDismiss={() => {}} />
    );
    expect(container.querySelector(".banner-title")!.textContent).toBe(
      "Background task stopped — Print six ticks with 4-second sleeps between each"
    );
  });

  test("a banner with no key still renders its own text verbatim", () => {
    // Most banners arrive off the wire already phrased; the key is the exception.
    const { container } = mount(
      <BannerStack
        banners={[
          { id: "b1", severity: "warning", title: "Rate limit reached", createdAtMs: 0 }
        ]}
        onDismiss={() => {}}
      />
    );
    expect(container.querySelector(".banner-title")!.textContent).toBe("Rate limit reached");
  });
});

describe("TasksStrip", () => {
  test("an empty background set renders nothing at all", () => {
    const { container } = mount(<TasksStrip tasks={[]} tasksById={{}} />);
    expect(container.querySelector(".tasks-strip")).toBeNull();
  });

  test("a row names the task and reports its live activity", () => {
    const live = replayThrough(workflowFixture, 35);
    const { container } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    expect(container.querySelector(".task-name")!.textContent).toBe(
      "Two agents return alpha and beta, merged into one result"
    );
    expect(container.querySelector(".task-activity")!.textContent).toContain("Gather");
    expect(container.querySelector(".task-type.is-local_workflow")).not.toBeNull();
  });

  test("Stop sends the row's own task id", async () => {
    const bridge = installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const { getByText } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    fireEvent.click(getByText("Stop"));
    await flush();
    expect(bridge.calls).toEqual(["stopTask:bnopezzr7"]);
  });

  test("View on a shell opens the output tail", async () => {
    const bridge = installBridge({});
    const live = replayThrough(shellsFixture, 26);
    const { getByText } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    fireEvent.click(getByText("View"));
    await flush(60);
    expect(bridge.calls).toContain("readTaskOutput");
  });

  test("View on a workflow offers its agents; picking one drills by runId+agentId", async () => {
    // A workflow ROOT has no transcript file — only its agents do — so the row
    // must never fire `loadSubagentTranscript` for the run itself. The bridge
    // contract rejects `{taskId, workflowRunId}` outright: taskId alone or
    // workflowRunId+agentId are the only legal shapes.
    const bridge = installBridge({
      loadSubagentTranscript: (params) => {
        const isLocal =
          params.taskId !== undefined &&
          params.workflowRunId === undefined &&
          params.agentId === undefined;
        const isWorkflow =
          params.taskId === undefined &&
          params.workflowRunId !== undefined &&
          params.agentId !== undefined;
        if (!isLocal && !isWorkflow) {
          return Promise.reject(new Error("invalid loadSubagentTranscript payload"));
        }
        bridge.calls.push(
          `loadSubagentTranscript:${params.workflowRunId ?? params.taskId}/${params.agentId ?? ""}`
        );
        return Promise.resolve({ events: [], truncated: false, missing: true });
      }
    });
    const live = replayThrough(workflowFixture, 35);
    const { container, getByText } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    fireEvent.click(getByText("View"));
    await flush(60);
    // No transcript request yet — the detail is an agent picker.
    expect(bridge.calls).toEqual([]);
    const agents = container.querySelectorAll(".task-wf-agent .wf-agent-toggle");
    expect(agents.length).toBeGreaterThan(0);
    fireEvent.click(agents[0]!);
    await flush(60);
    expect(bridge.calls).toEqual([
      "loadSubagentTranscript:wf_c0f60243-4f1/aec2c2f1b40b1481e"
    ]);
    expect(bridge.calls).not.toContain("readTaskOutput");
  });

  test("a settled row shows catalog copy and a glyph, never the raw wire token", () => {
    const settled = replayThrough(shellsFixture, shellsFixture.length);
    // Keep the strip populated: re-add the (now stopped) shell as membership.
    const { container } = mount(
      <TasksStrip
        tasks={[{ taskId: "bnopezzr7", taskType: "local_bash" }]}
        tasksById={settled.tasksById}
      />
    );
    const status = container.querySelector(".task-status")!;
    expect(status.classList.contains("is-stopped")).toBe(true);
    expect(status.textContent).toBe("Stopped");
    expect(status.querySelector("svg")).not.toBeNull();
  });

  test("an unknown task type is admitted as a generic Task, not asserted a shell", () => {
    const { container } = mount(
      <TasksStrip
        tasks={[{ taskId: "t-x", taskType: "local_mcp", description: "Future thing" }]}
        tasksById={{}}
      />
    );
    const type = container.querySelector(".task-type")!;
    expect(type.classList.contains("is-unknown")).toBe(true);
    expect(type.getAttribute("title")).toBe("Task");
  });

  test("only one detail stays open at a time", async () => {
    installBridge({});
    const { container, getAllByText } = mount(
      <TasksStrip
        tasks={[
          { taskId: "s1", taskType: "local_bash", description: "one" },
          { taskId: "s2", taskType: "local_bash", description: "two" }
        ]}
        tasksById={{}}
      />
    );
    const views = getAllByText("View");
    fireEvent.click(views[0]!);
    await flush(40);
    fireEvent.click(views[1]!);
    // The closing Disclosure keeps its content mounted for the collapse
    // animation (~450ms worst case) before unmounting.
    await flush(600);
    expect(container.querySelectorAll(".task-output").length).toBe(1);
  });
});

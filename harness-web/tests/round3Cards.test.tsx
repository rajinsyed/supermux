import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { taskBridgeStub } from "./bridgeStub";
import { nestedFixture, shellsFixture, workflowFixture } from "../src/dev/fixtures/round3";
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

  test("a backgrounded command offers Stop, not Move to background", () => {
    const live = replayThrough(shellsFixture, 26);
    const bash = tools(live).find((tool) => tool.subagent?.taskId === "bnopezzr7")!;
    const { queryByText, getByText } = mount(<ToolCard block={bash} />);
    expect(queryByText("Move to background")).toBeNull();
    expect(getByText("Stop")).toBeDefined();
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

  test("View on a workflow opens the transcript drill-in instead", async () => {
    const bridge = installBridge({});
    const live = replayThrough(workflowFixture, 35);
    const { getByText } = mount(
      <TasksStrip tasks={live.backgroundTasks} tasksById={live.tasksById} />
    );
    fireEvent.click(getByText("View"));
    await flush(60);
    expect(bridge.calls).toContain("loadSubagentTranscript");
    expect(bridge.calls).not.toContain("readTaskOutput");
  });
});

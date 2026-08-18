import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import type { HarnessBridge } from "../src/bridge";
import { taskBridgeStub } from "./bridgeStub";
import { nestedFixture, shellsFixture, withWorkflowLogs } from "../src/dev/fixtures/round3";
import { applyLine, createIndex, createModel, replayLines } from "../src/model/transcript";
import type { Block, ToolBlock, TranscriptModel } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { BannerStack } from "../src/ui/status/BannerStack";
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

/**
 * The WorkflowCard suite that stood here moved to workflowBrowser.test.tsx with
 * the card itself: round 4 replaced the inline card — 600px of nested
 * disclosures inside a conversation — with a one-line row and a multi-pane
 * browser, so the phases, state chips, result disclosures and head fold it
 * asserted are now assertions about the browser.
 */

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


  // The strip's two-level Escape walk went with the TasksStrip; the equivalent
  // multi-level walk is now the view stack's, covered in dockAndViews.test.tsx.

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

describe("the banner stack, now that only failures reach it", () => {
  test("a session whose background work all finished has an EMPTY stack", () => {
    // The finished-task banner is gone: every terminal task used to add one,
    // and the user had to close each by hand. An empty stack renders nothing
    // at all, not an empty container.
    const model = replayLines(shellsFixture);
    const { container } = mount(
      <BannerStack banners={model.banners} onDismiss={() => {}} />
    );
    expect(model.banners).toEqual([]);
    expect(container.querySelector(".banner-stack")).toBeNull();
  });

  test("a hard failure still renders — that is what the stack is FOR", () => {
    const { container } = mount(
      <BannerStack
        banners={[
          {
            id: "b0",
            severity: "error",
            title: "Authentication failed — check your API key",
            createdAtMs: 0
          }
        ]}
        onDismiss={() => {}}
      />
    );
    expect(container.querySelector(".banner-title")!.textContent).toContain(
      "Authentication failed"
    );
    expect(container.querySelector(".banner")!.className).toContain("is-error");
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

/*
 * The TasksStrip suite that stood here went with the strip itself: the round-4
 * agents dock (dockAndViews.test.tsx) replaced the strip as the docked task
 * surface, and its concerns are re-asserted there — membership and persistence
 * by dockRows, Stop by task id on the dock row, opening a shell's output tail
 * as the ShellView, and a workflow's agents through the workflow browser
 * (workflowBrowser.test.tsx), which also owns the runId+agentId drill contract.
 */

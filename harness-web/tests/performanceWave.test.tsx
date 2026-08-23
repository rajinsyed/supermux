import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { createRef } from "react";
import type { HarnessBridge } from "../src/bridge";
import type { Block, ToolBlock, Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { AnsiOutput } from "../src/ui/primitives/AnsiOutput";
import { CodeBlock } from "../src/ui/primitives/CodeBlock";
import { Markdown } from "../src/ui/primitives/Markdown";
import { WorkingDots } from "../src/ui/primitives/Spinner";
import { TaskOutputView } from "../src/ui/tools/TaskOutput";
import { TranscriptList } from "../src/ui/transcript/TranscriptList";
import { TurnView } from "../src/ui/transcript/TurnView";

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

function turn(id: string, text = `message ${id}`, blocks: Block[] = []): Turn {
  return {
    id,
    seq: Number(id.replace(/\D/g, "")) || 1,
    userUuid: id,
    userText: text,
    startedAtMs: 1,
    endedAtMs: 2,
    state: "complete",
    blocks,
    folded: false,
    revision: 0
  };
}

function tool(
  key: string,
  name: string,
  input: ToolBlock["input"],
  structured?: ToolBlock["structured"],
  extras: Partial<ToolBlock> = {}
): ToolBlock {
  return {
    kind: "tool",
    key,
    messageId: `message-${key}`,
    toolUseId: key,
    name,
    input,
    inputComplete: true,
    status: "success",
    streaming: false,
    structured,
    startedAtMs: 1,
    endedAtMs: 2,
    children: [],
    ...extras
  };
}

function mountTranscript(turns: Turn[], resetKey = 0) {
  const scrollRef = createRef<HTMLDivElement>();
  const contentRef = createRef<HTMLDivElement>();
  const props = (rows: Turn[], generation: number) => (
    <CopyProvider dict={undefined}>
      <TranscriptList
        turns={rows}
        resetKey={generation}
        scrollRef={scrollRef}
        contentRef={contentRef}
        showPill={false}
        onJump={() => {}}
      />
    </CopyProvider>
  );
  const mounted = render(props(turns, resetKey));
  return {
    ...mounted,
    rerenderTurns: (rows: Turn[], generation = resetKey) => mounted.rerender(props(rows, generation))
  };
}

describe("the transcript window stays bounded in both directions", () => {
  test("traversing one thousand variable-height turns never mounts an unbounded prefix", () => {
    const turns = Array.from({ length: 1000 }, (_, index) =>
      turn(`turn-${index + 1}`, `message ${index + 1}\n${"detail\n".repeat(index % 7)}`)
    );
    const { container } = mountTranscript(turns);

    for (let step = 0; step < 70; step += 1) {
      const earlier = container.querySelector<HTMLButtonElement>(".transcript-earlier .link-btn");
      if (!earlier) break;
      fireEvent.click(earlier);
    }

    expect(container.querySelectorAll(".turn").length).toBeLessThanOrEqual(48);
    expect(container.querySelector("[data-turn-id='turn-1']")).not.toBeNull();
    expect(container.querySelector("[data-turn-id='turn-1000']")).toBeNull();
  });

  test("a conversation generation reset discards the old presentation window", () => {
    const first = Array.from({ length: 240 }, (_, index) => turn(`old-${index + 1}`));
    const mounted = mountTranscript(first, 0);
    for (let step = 0; step < 10; step += 1) {
      const earlier = mounted.container.querySelector<HTMLButtonElement>(".transcript-earlier .link-btn");
      if (!earlier) break;
      fireEvent.click(earlier);
    }
    expect(mounted.container.querySelectorAll(".turn").length).toBeGreaterThan(48);

    const replacement = Array.from({ length: 120 }, (_, index) => turn(`new-${index + 1}`));
    mounted.rerenderTurns(replacement, 1);

    expect(mounted.container.querySelectorAll(".turn").length).toBeLessThanOrEqual(48);
    expect(mounted.container.querySelector("[data-turn-id='new-120']")).not.toBeNull();
  });
});

describe("reader choices survive fold and virtual unmount", () => {
  const longMessage = Array.from({ length: 14 }, (_, index) => `line ${index + 1}`).join("\n");
  const longCode = Array.from({ length: 80 }, (_, index) => `const line${index} = ${index};`).join("\n");
  const longOutput = Array.from({ length: 80 }, (_, index) => `output ${index + 1}`).join("\n");
  const patchLines = Array.from({ length: 60 }, (_, index) => `+added line ${index + 1}`);
  const blocks: Block[] = [
    {
      kind: "thinking",
      key: "thinking-1",
      messageId: "thinking-message",
      text: "A long reasoning trace",
      tokens: 20,
      streaming: false,
      startedAtMs: 1,
      endedAtMs: 2
    },
    tool(
      "read-1",
      "Read",
      { file_path: "/tmp/demo.ts" },
      { file: { filePath: "/tmp/demo.ts", content: longCode, totalLines: 80 } }
    ),
    tool("bash-1", "Bash", { command: "run" }, { stdout: longOutput }),
    tool(
      "edit-1",
      "Edit",
      { file_path: "/tmp/demo.ts" },
      {
        structuredPatch: [
          { oldStart: 1, oldLines: 0, newStart: 1, newLines: 60, lines: patchLines }
        ]
      }
    ),
    tool("background-1", "Bash", { command: "watch" }, undefined, {
      subagent: {
        taskId: "task-background",
        taskType: "local_bash",
        background: true,
        status: "running"
      }
    }),
    tool("workflow-1", "Workflow", { name: "performance wave" }, undefined, {
      workflow: {
        name: "performance wave",
        status: "completed",
        phases: [],
        agents: [],
        logs: [],
        totals: { agents: 0, done: 0, running: 0, failed: 0, tokens: 0, toolCalls: 0 }
      }
    })
  ];

  test("user, thinking, tool, code, ANSI, diff, output, and workflow state returns", () => {
    window.supermuxHarnessMock = {
      readTaskOutput() {
        return new Promise(() => undefined);
      }
    } as unknown as HarnessBridge;
    const row = turn("disclosures", longMessage, blocks);
    const mounted = mountTranscript([row]);
    const { container } = mounted;

    fireEvent.click(container.querySelector(".user-msg-actions .link-btn")!);
    fireEvent.click(container.querySelector(".thinking-head")!);
    fireEvent.click(container.querySelector(".tool-card[data-family='read'] .tool-head")!);
    fireEvent.click(container.querySelector(".tool-card[data-family='read'] .code-block-more")!);
    fireEvent.click(container.querySelector(".tool-card[data-family='read'] .code-block-head .icon-btn")!);
    fireEvent.click(container.querySelector(".tool-card[data-family='bash'] .terminal-more")!);
    fireEvent.click(container.querySelector(".tool-card[data-family='edit'] .diff-more")!);
    fireEvent.click(container.querySelector(".bash-bg-actions .btn")!);
    fireEvent.click(container.querySelector(".wf-row")!);

    fireEvent.click(container.querySelector(".fold-head")!);
    expect(container.querySelector(".turn-work .tool-card")).toBeNull();
    fireEvent.click(container.querySelector(".fold-head")!);
    expect(container.querySelector(".tool-card[data-family='read']")).not.toBeNull();

    expect(container.querySelector(".user-msg-body")!.classList.contains("is-clipped")).toBe(false);
    expect(container.querySelector(".thinking-head")!.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector(".tool-card[data-family='read']")!.classList.contains("is-open")).toBe(true);
    expect(container.querySelector(".tool-card[data-family='read'] .code-block-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(
      container.querySelector(".tool-card[data-family='read'] .code-block-head .icon-btn")!.getAttribute("aria-pressed")
    ).toBe("true");
    expect(container.querySelector(".tool-card[data-family='bash'] .terminal-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(container.querySelector(".tool-card[data-family='edit'] .diff-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(container.querySelector(".bash-bg-actions .btn")!.textContent).toContain("Hide output");
    expect(container.querySelector(".wfb-overlay")).not.toBeNull();

    mounted.rerenderTurns([]);
    expect(container.querySelector(".turn")).toBeNull();
    mounted.rerenderTurns([row]);

    expect(container.querySelector(".user-msg-body")!.classList.contains("is-clipped")).toBe(false);
    expect(container.querySelector(".thinking-head")!.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector(".tool-card[data-family='read']")!.classList.contains("is-open")).toBe(true);
    expect(container.querySelector(".tool-card[data-family='read'] .code-block-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(
      container.querySelector(".tool-card[data-family='read'] .code-block-head .icon-btn")!.getAttribute("aria-pressed")
    ).toBe("true");
    expect(container.querySelector(".tool-card[data-family='bash'] .terminal-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(container.querySelector(".tool-card[data-family='edit'] .diff-more")!.textContent).toContain(
      "Collapse output"
    );
    expect(container.querySelector(".bash-bg-actions .btn")!.textContent).toContain("Hide output");
    expect(container.querySelector(".wfb-overlay")).not.toBeNull();
  });

  test("a block that was live remains in the streaming tail after virtual unmount", () => {
    const previouslyLive = tool(
      "previously-live",
      "Read",
      { file_path: "/tmp/live.txt" },
      undefined,
      { status: "running", streaming: true, endedAtMs: undefined }
    );
    const rest = Array.from({ length: 6 }, (_, index) =>
      tool(`later-${index}`, "CustomTool", { index })
    );
    const streaming: Turn = {
      ...turn("durable-live", "streaming", [previouslyLive, ...rest]),
      state: "streaming",
      endedAtMs: undefined,
      result: undefined
    };
    const mounted = mountTranscript([streaming]);
    expect(mounted.container.querySelector(".tool-card[data-family='read']")).not.toBeNull();

    mounted.rerenderTurns([]);
    const settledBlock = { ...previouslyLive, status: "success" as const, streaming: false };
    mounted.rerenderTurns([{ ...streaming, blocks: [settledBlock, ...rest], revision: 1 }]);

    expect(mounted.container.querySelector(".tool-card[data-family='read']")).not.toBeNull();
  });
});

describe("TaskOutput polling follows presentation and tolerates transient reads", () => {
  test("a visible running tail retries after a transient failure without blanking cached text", async () => {
    const polls: Array<() => void> = [];
    const originalSetTimeout = window.setTimeout;
    window.setTimeout = ((handler: TimerHandler, timeout?: number, ...args: unknown[]) => {
      if (timeout === 1200 && typeof handler === "function") {
        polls.push(handler as () => void);
        return 9000 + polls.length;
      }
      return originalSetTimeout(handler, timeout, ...args);
    }) as typeof window.setTimeout;
    let calls = 0;
    window.supermuxHarnessMock = {
      async readTaskOutput() {
        calls += 1;
        if (calls === 1) return { text: "cached output", truncated: false, missing: false };
        if (calls === 2) throw new Error("transient read failure");
        return { text: "recovered output", truncated: false, missing: false };
      }
    } as unknown as HarnessBridge;

    try {
      const mounted = render(
        <CopyProvider dict={undefined}>
          <TaskOutputView taskId="task-retry" running />
        </CopyProvider>
      );
      await waitFor(() => expect(mounted.container.textContent).toContain("cached output"));
      expect(polls).toHaveLength(1);

      await act(async () => {
        polls.shift()!();
        await Promise.resolve();
        await Promise.resolve();
      });
      expect(mounted.container.textContent).toContain("cached output");
      expect(polls).toHaveLength(1);

      await act(async () => {
        polls.shift()!();
        await Promise.resolve();
        await Promise.resolve();
      });
      await waitFor(() => expect(mounted.container.textContent).toContain("recovered output"));
    } finally {
      window.setTimeout = originalSetTimeout;
    }
  });
});

describe("streaming Markdown avoids expensive mutable rendering without semantic drift", () => {
  test("an unfinished fenced block is escaped plain text without Highlight.js tokens", () => {
    const { container } = render(
      <CopyProvider dict={undefined}>
        <Markdown text={"```javascript\nconst answer = 42;\n"} streaming />
      </CopyProvider>
    );

    expect(container.textContent).toContain("const answer = 42;");
    expect(container.querySelector(".hljs-keyword")).toBeNull();
  });

  test("large incomplete GFM containers remain one semantic document", () => {
    const table = [
      "| index | value |",
      "| ---: | :--- |",
      ...Array.from({ length: 1800 }, (_, index) => `| ${index} | row-${index} |`)
    ].join("\n");
    const tableView = render(
      <CopyProvider dict={undefined}>
        <Markdown text={table} streaming />
      </CopyProvider>
    );
    expect(tableView.container.querySelectorAll("table")).toHaveLength(1);
    expect(
      Array.from(tableView.container.querySelectorAll("p")).some((node) => node.textContent?.includes("row-"))
    ).toBe(false);
    tableView.unmount();

    const list = Array.from(
      { length: 1800 },
      (_, index) => `1. item ${index}\n   continuation ${index}`
    ).join("\n");
    const listView = render(
      <CopyProvider dict={undefined}>
        <Markdown text={list} streaming />
      </CopyProvider>
    );
    expect(listView.container.querySelectorAll("ol")).toHaveLength(1);
    expect(listView.container.querySelector("ol")!.textContent).toContain("continuation 0");
    listView.unmount();

    const quote = Array.from({ length: 2200 }, (_, index) => `> quoted line ${index}`).join("\n");
    const quoteView = render(
      <CopyProvider dict={undefined}>
        <Markdown text={quote} streaming />
      </CopyProvider>
    );
    expect(quoteView.container.querySelectorAll("blockquote")).toHaveLength(1);
    expect(
      Array.from(quoteView.container.querySelectorAll("p")).every(
        (node) => node.closest("blockquote") !== null
      )
    ).toBe(true);
  });

  test("fenced code identity survives open, close, settle, duplicates, wrap, and virtual unmount", () => {
    const body = Array.from(
      { length: 2200 },
      (_, index) => `const duplicateLine${index} = ${index};`
    ).join("\n");
    const open = `\`\`\`javascript\n${body}`;
    const closed = `${open}\n\`\`\`\n\n\`\`\`javascript\n${body}\n\`\`\``;
    const row = (text: string, streaming: boolean, revision: number): Turn => ({
      ...turn("markdown-identity", "show code", [
        {
          kind: "text",
          key: "markdown-code-block",
          messageId: "markdown-code-message",
          text,
          streaming
        }
      ]),
      state: streaming ? "streaming" : "complete",
      endedAtMs: streaming ? undefined : 10,
      revision
    });
    const mounted = mountTranscript([row(open, true, 0)]);
    const initial = mounted.container.querySelector<HTMLElement>(".code-block")!;
    expect(initial.querySelector(".code-block-body")!.textContent!.length).toBeLessThan(body.length);
    fireEvent.click(initial.querySelector(".code-block-more")!);
    fireEvent.click(initial.querySelector(".icon-btn")!);
    expect(initial.querySelector(".code-block-body")!.textContent).toBe(body);
    expect(initial.querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("true");

    mounted.rerenderTurns([row(closed, true, 1)]);
    let codeBlocks = mounted.container.querySelectorAll<HTMLElement>(".code-block");
    expect(codeBlocks).toHaveLength(2);
    expect(codeBlocks[0].querySelector(".code-block-body")!.textContent).toBe(body);
    expect(codeBlocks[0].querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("true");
    expect(codeBlocks[1].querySelector(".code-block-body")!.textContent!.length).toBeLessThan(body.length);
    expect(codeBlocks[1].querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("false");

    mounted.rerenderTurns([row(closed, false, 2)]);
    codeBlocks = mounted.container.querySelectorAll<HTMLElement>(".code-block");
    expect(codeBlocks[0].querySelector(".code-block-body")!.textContent).toBe(body);
    expect(codeBlocks[0].querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("true");
    expect(codeBlocks[1].querySelector(".code-block-body")!.textContent!.length).toBeLessThan(body.length);

    mounted.rerenderTurns([]);
    mounted.rerenderTurns([row(closed, false, 2)]);
    codeBlocks = mounted.container.querySelectorAll<HTMLElement>(".code-block");
    expect(codeBlocks[0].querySelector(".code-block-body")!.textContent).toBe(body);
    expect(codeBlocks[0].querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("true");
    expect(codeBlocks[1].querySelector(".icon-btn")!.getAttribute("aria-pressed")).toBe("false");
  });

  test("a giant open fence stays byte-bounded while settled output is exact", () => {
    const payload = Array.from({ length: 9000 }, (_, index) => `const line${index} = ${index};`).join("\n");
    const mounted = render(
      <CopyProvider dict={undefined}>
        <Markdown text={`\`\`\`javascript\n${payload}`} streaming />
      </CopyProvider>
    );
    expect(mounted.container.querySelector(".code-block-body")!.textContent!.length).toBeLessThan(
      payload.length
    );

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown text={`\`\`\`javascript\n${payload}\n\`\`\``} />
      </CopyProvider>
    );
    fireEvent.click(mounted.container.querySelector(".code-block-more")!);
    expect(mounted.container.querySelector(".code-block-body")!.textContent).toBe(payload);
    expect(mounted.container.querySelector(".hljs-keyword")).not.toBeNull();
  });

  test("settled output returns to exact ReactMarkdown plus GFM semantics", () => {
    const settled = [
      "| state | value |",
      "| --- | --- |",
      "| done | ~~old~~ |",
      "",
      "- [x] complete",
      "",
      "```javascript",
      "const answer = 42;",
      "```"
    ].join("\n");
    const mounted = render(
      <CopyProvider dict={undefined}>
        <Markdown text={settled.slice(0, -4)} streaming />
      </CopyProvider>
    );
    expect(mounted.container.querySelector(".hljs-keyword")).toBeNull();

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown text={settled} />
      </CopyProvider>
    );
    expect(mounted.container.querySelectorAll("table")).toHaveLength(1);
    expect(mounted.container.querySelector("del")!.textContent).toBe("old");
    expect(mounted.container.querySelector("input[type='checkbox']")).not.toBeNull();
    expect(mounted.container.querySelector(".hljs-keyword")!.textContent).toBe("const");
  });

  test("a giant one-line code payload is bounded until the reader asks for all of it", () => {
    const payload = "x".repeat(180_000);
    const { container } = render(
      <CopyProvider dict={undefined}>
        <CodeBlock code={payload} language="plaintext" />
      </CopyProvider>
    );

    const body = container.querySelector(".code-block-body")!;
    expect(body.textContent!.length).toBeLessThan(payload.length);
    fireEvent.click(container.querySelector(".code-block-more")!);
    expect(body.textContent).toBe(payload);
  });
});

describe("ANSI previews clip safely", () => {
  test("a byte cap never exposes a split escape, control byte, or broken code point", () => {
    const prefix = "🙂".repeat(6143);
    const payload = `${prefix}[38;5;196mRED[0mDONE`;
    const { container } = render(
      <CopyProvider dict={undefined}>
        <AnsiOutput text={payload} maxLines={100000} />
      </CopyProvider>
    );

    const preview = container.querySelector(".terminal-body")!.textContent ?? "";
    expect(preview).not.toContain("");
    expect(preview).not.toContain("[38;5;");
    expect(preview).not.toContain("");
    expect(preview.endsWith("�")).toBe(false);
    expect(preview.length).toBeLessThan(payload.length);

    fireEvent.click(container.querySelector(".terminal-more")!);
    const expanded = container.querySelector(".terminal-body")!.textContent ?? "";
    expect(expanded).toContain("RED");
    expect(expanded).toContain("DONE");
    expect(expanded).not.toContain("");
    expect(expanded).not.toContain("");
    expect(expanded).not.toContain("�");
  });
});

describe("active text uses a compositable indicator", () => {
  test("the turn mark has visible transform/opacity children of its own", () => {
    const { container } = render(<WorkingDots />);
    expect(container.querySelector(".working-dots")!.children.length).toBeGreaterThan(0);
  });
});

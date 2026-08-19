import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, waitFor } from "@testing-library/react";
import { useLayoutEffect, useRef, type ReactElement } from "react";
import type { HarnessBridge } from "../src/bridge";
import { applyLine, createIndex, createModel } from "../src/model/transcript";
import type { Block, TextBlock, ToolBlock, Turn } from "../src/model/types";
import type { ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { parseAnsi, stripAnsi } from "../src/ui/ansi";
import { PresentationStateProvider } from "../src/ui/presentationState";
import {
  codePreviewDiagnostics,
  resetCodePreviewDiagnostics
} from "../src/ui/primitives/CodeBlock";
import {
  Markdown,
  resetStreamingMarkdownDiagnostics,
  streamingMarkdownDiagnostics
} from "../src/ui/primitives/Markdown";
import { WorkingDots } from "../src/ui/primitives/Spinner";
import { SubagentTranscriptView } from "../src/ui/tools/SubagentTranscript";
import { TaskOutputView } from "../src/ui/tools/TaskOutput";
import { BlockView } from "../src/ui/transcript/BlockView";
import { TranscriptList } from "../src/ui/transcript/TranscriptList";
import { TurnView } from "../src/ui/transcript/TurnView";
import { useTranscriptWindow } from "../src/ui/transcript/useTranscriptWindow";
import { clipAnsiUtf8 } from "../src/ui/utf8";

function mount(node: ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

function turn(id: string, blocks: Block[] = [], text = `message ${id}`): Turn {
  return {
    id,
    seq: Number(id.replace(/\D/g, "")) || 1,
    userUuid: id,
    userText: text,
    startedAtMs: 1,
    state: "streaming",
    blocks,
    folded: false,
    revision: 0
  };
}

function tool(key: string, status: ToolBlock["status"]): ToolBlock {
  return {
    kind: "tool",
    key,
    messageId: `message-${key}`,
    toolUseId: key,
    name: "CustomTool",
    input: { key },
    inputComplete: true,
    status,
    streaming: status === "running" || status === "pending",
    startedAtMs: 1,
    endedAtMs: status === "running" || status === "pending" ? undefined : 2,
    children: []
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function transcriptEvents(label: string): ProtocolLine[] {
  return [
    {
      type: "user",
      uuid: `${label}-user`,
      message: { role: "user", content: label }
    } as ProtocolLine,
    {
      type: "assistant",
      uuid: `${label}-assistant`,
      message: {
        id: `${label}-message`,
        role: "assistant",
        content: [{ type: "text", text: `${label} transcript` }]
      }
    } as ProtocolLine
  ];
}

afterEach(() => {
  cleanup();
  delete window.supermuxHarnessMock;
});

describe("streaming text carries exact append provenance", () => {
  test("deltas retain one epoch and an authoritative replacement advances it", () => {
    const index = createIndex();
    let model = createModel();
    const lines: ProtocolLine[] = [
      {
        type: "stream_event",
        uuid: "epoch-message",
        event: { type: "message_start", message: { id: "epoch-message-id" } }
      } as ProtocolLine,
      {
        type: "stream_event",
        uuid: "epoch-start",
        event: {
          type: "content_block_start",
          index: 0,
          content_block: { type: "text", text: "" }
        }
      } as ProtocolLine,
      {
        type: "stream_event",
        uuid: "epoch-delta-1",
        event: {
          type: "content_block_delta",
          index: 0,
          delta: { type: "text_delta", text: "one" }
        }
      } as ProtocolLine,
      {
        type: "stream_event",
        uuid: "epoch-delta-2",
        event: {
          type: "content_block_delta",
          index: 0,
          delta: { type: "text_delta", text: " two" }
        }
      } as ProtocolLine
    ];
    for (const line of lines) model = applyLine(model, index, line, 1);
    let block = model.turns[0].blocks[0] as TextBlock;
    expect(block.text).toBe("one two");
    expect(block.textEpoch).toBe(0);

    model = applyLine(
      model,
      index,
      {
        type: "assistant",
        uuid: "epoch-authoritative",
        message: {
          id: "epoch-message-id",
          role: "assistant",
          content: [{ type: "text", text: "authoritative replacement" }]
        }
      } as ProtocolLine,
      2
    );
    block = model.turns[0].blocks[0] as TextBlock;
    expect(block.text).toBe("authoritative replacement");
    expect(block.textEpoch).toBe(1);
  });

  test("BlockView forwards the reducer epoch so production appends never validate the old prefix", () => {
    const payload = "q".repeat(100_000);
    const block = (text: string): TextBlock => ({
      kind: "text",
      key: "provenance-block",
      messageId: "provenance-message",
      text,
      streaming: true,
      textEpoch: 7
    });
    resetStreamingMarkdownDiagnostics();
    const mounted = mount(<BlockView block={block(`\`\`\`text\n${payload}`)} />);
    const initial = streamingMarkdownDiagnostics();
    for (let index = 1; index <= 20; index += 1) {
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <BlockView block={block(`\`\`\`text\n${payload}${"r".repeat(index)}`)} />
        </CopyProvider>
      );
    }
    const after = streamingMarkdownDiagnostics();
    expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
    expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(20);
    expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
  });

  test("a new conversation generation resets reused block and epoch identities", () => {
    const block = (text: string): TextBlock => ({
      kind: "text",
      key: "reused-block",
      messageId: "reused-message",
      text,
      streaming: true,
      textEpoch: 0
    });
    const mounted = mount(
      <BlockView
        block={block("old committed\n\nold mutable")}
        generation={4}
      />
    );
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <BlockView
          block={block("old committed\n\nold mutable\n\n```text\nold code")}
          generation={4}
        />
      </CopyProvider>
    );
    expect(mounted.container.textContent).toContain("old committed");
    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe("old code");

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <BlockView
          block={block("new generation\n\n```python\nnew code")}
          generation={5}
        />
      </CopyProvider>
    );

    expect(mounted.container.textContent).not.toContain("old committed");
    expect(mounted.container.textContent).not.toContain("old code");
    expect(mounted.container.querySelector(".code-chip")?.textContent).toBe("python");
    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe("new code");
  });
});

describe("streaming Markdown keeps one correct GFM document", () => {
  test("a later reference definition resolves an earlier reference across a blank line", () => {
    const mounted = mount(<Markdown text={"Read [the guide][guide].\n\n"} streaming />);
    expect(mounted.container.querySelector("a")).toBeNull();

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={"Read [the guide][guide].\n\n[guide]: https://example.com/guide\n"}
          streaming
        />
      </CopyProvider>
    );

    const link = mounted.container.querySelector<HTMLAnchorElement>("a");
    expect(link?.textContent).toBe("the guide");
    expect(link?.getAttribute("href")).toBe("https://example.com/guide");
  });

  test("a list-indented fence and its post-blank continuation stay in the same list item", () => {
    const source = [
      "- parent item",
      "  ```javascript",
      "  const nested = true;",
      "  ```",
      "",
      "  continuation after the fence"
    ].join("\n");
    const mounted = mount(<Markdown text={source} streaming />);

    const item = mounted.container.querySelector("li");
    expect(item).not.toBeNull();
    expect(item!.querySelector(".code-block")?.textContent).toContain("const nested = true;");
    expect(item!.textContent).toContain("continuation after the fence");
    expect(mounted.container.querySelector("li")?.contains(mounted.container.querySelector(".code-block"))).toBe(
      true
    );
  });

  test("an exact middle replacement followed by an append never leaves the old chunk rendered", () => {
    const prefix = `prefix ${"a".repeat(96)}`;
    const suffix = `suffix ${"z".repeat(96)}`;
    const initial = `${prefix}\n\nOLD-MIDDLE\n\n${suffix}\n\nwaiting`;
    const replacement = `${prefix}\n\nNEW-MIDDLE\n\n${suffix}\n\nwaiting plus append`;
    const mounted = mount(<Markdown text={initial} streaming />);
    expect(mounted.container.textContent).toContain("OLD-MIDDLE");

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown text={replacement} streaming />
      </CopyProvider>
    );

    expect(mounted.container.textContent).toContain("NEW-MIDDLE");
    expect(mounted.container.textContent).not.toContain("OLD-MIDDLE");
    expect(mounted.container.textContent).toContain("waiting plus append");
  });

  test("epoch and fallback replacements atomically discard an open fence", () => {
    const versioned = mount(
      <Markdown
        text={"```javascript\nold versioned body"}
        streaming
        streamGeneration={2}
        streamEpoch={8}
      />
    );
    versioned.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={"```python\nnew versioned body"}
          streaming
          streamGeneration={2}
          streamEpoch={9}
        />
      </CopyProvider>
    );
    expect(versioned.container.querySelector(".code-chip")?.textContent).toBe("python");
    expect(versioned.container.querySelector(".code-block-body")?.textContent).toBe(
      "new versioned body"
    );
    expect(versioned.container.textContent).not.toContain("old versioned body");

    const fallback = mount(<Markdown text={"```javascript\nold fallback body"} streaming />);
    fallback.rerender(
      <CopyProvider dict={undefined}>
        <Markdown text={"```python\nnew fallback body"} streaming />
      </CopyProvider>
    );
    expect(fallback.container.querySelector(".code-chip")?.textContent).toBe("python");
    expect(fallback.container.querySelector(".code-block-body")?.textContent).toBe(
      "new fallback body"
    );
    expect(fallback.container.textContent).not.toContain("old fallback body");
  });

  test("a long no-newline open fence scans only newly appended source and a bounded preview", () => {
    resetStreamingMarkdownDiagnostics();
    resetCodePreviewDiagnostics();
    const payload = "x".repeat(180_000);
    const mounted = mount(<Markdown text={`\`\`\`text\n${payload}`} streaming streamEpoch={0} />);
    const initial = streamingMarkdownDiagnostics();

    for (let index = 1; index <= 80; index += 1) {
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            text={`\`\`\`text\n${payload}${"y".repeat(index)}`}
            streaming
            streamEpoch={0}
          />
        </CopyProvider>
      );
    }

    const after = streamingMarkdownDiagnostics();
    expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
    expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBeLessThanOrEqual(100);
    expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
    expect(after.totalCodeUnits - initial.totalCodeUnits).toBeLessThanOrEqual(100);
    expect(codePreviewDiagnostics().maxScannedCodeUnitsPerRender).toBeLessThanOrEqual(24 * 1024 + 1);
    expect(mounted.container.querySelector(".code-block-body")!.textContent!.length).toBeLessThan(
      payload.length
    );
  });

  test("all valid indentation, blockquote, list, and CRLF open fences stay O(delta)", () => {
    const payload = "p".repeat(120_000);
    const cases = [
      { name: "one-space", prefix: " ```javascript\n", contentPrefix: "" },
      { name: "two-space", prefix: "  ```javascript\n", contentPrefix: "" },
      { name: "three-space-crlf", prefix: "   ```javascript\r\n", contentPrefix: "" },
      { name: "blockquote", prefix: "> ```javascript\n", contentPrefix: "> " },
      { name: "nested-blockquote-crlf", prefix: ">>  ~~~javascript\r\n", contentPrefix: ">>  " },
      { name: "list", prefix: "- item\n  ```javascript\n", contentPrefix: "  " }
    ];

    for (const fixture of cases) {
      resetStreamingMarkdownDiagnostics();
      resetCodePreviewDiagnostics();
      const initialText = `${fixture.prefix}${fixture.contentPrefix}${payload}`;
      const mounted = mount(<Markdown text={initialText} streaming streamEpoch={0} />);
      const code = mounted.container.querySelector(".code-block");
      expect({ name: fixture.name, found: code !== null }).toEqual({
        name: fixture.name,
        found: true
      });
      if (fixture.name.includes("blockquote")) expect(code!.closest("blockquote")).not.toBeNull();
      if (fixture.name === "list") expect(code!.closest("li")).not.toBeNull();
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= 40; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${initialText}${"z".repeat(index)}`}
              streaming
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(40);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(40);
      expect(codePreviewDiagnostics().maxScannedCodeUnitsPerRender).toBeLessThanOrEqual(24 * 1024 + 1);
      fireEvent.click(mounted.container.querySelector(".code-block-more")!);
      expect(mounted.container.querySelector(".code-block-body")!.textContent?.endsWith("z".repeat(40))).toBe(
        true
      );
      mounted.unmount();
    }
  });

  test("marker-line list fences and under-indented content remain O(delta)", () => {
    const payload = "l".repeat(120_000);
    const cases = [
      { name: "bullet-marker-line", prefix: "- ```javascript\n  ", container: "li" },
      { name: "ordered-marker-line", prefix: "1. ```javascript\n   ", container: "li" },
      { name: "blockquote-list-marker-line", prefix: "> - ```javascript\n>   ", container: "blockquote" },
      { name: "content-less-indented-than-opener", prefix: "- item\n    ```javascript\n   ", container: "li" }
    ];

    for (const fixture of cases) {
      resetStreamingMarkdownDiagnostics();
      const initialText = `${fixture.prefix}${payload}`;
      const mounted = mount(
        <Markdown text={initialText} streaming streamGeneration={0} streamEpoch={0} />
      );
      const code = mounted.container.querySelector(".code-block");
      expect({ name: fixture.name, found: code !== null }).toEqual({
        name: fixture.name,
        found: true
      });
      expect(code!.closest(fixture.container)).not.toBeNull();
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= 40; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${initialText}${"z".repeat(index)}`}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(40);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(40);
      fireEvent.click(mounted.container.querySelector(".code-block-more")!);
      expect(mounted.container.querySelector(".code-block-body")?.textContent?.endsWith("z".repeat(40))).toBe(
        true
      );
      mounted.unmount();
    }
  });

  test("closed fences in one mutable list do not trigger parser oracles", () => {
    const closedFences = Array.from(
      { length: 24 },
      (_, index) => `  ~~~text\n  closed-${index}\n  ~~~`
    ).join("\n");
    const source = `- item\n${closedFences}\n  trailing paragraph`;
    resetStreamingMarkdownDiagnostics();

    const mounted = mount(
      <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
    );
    const initial = streamingMarkdownDiagnostics();
    expect(mounted.container.querySelectorAll(".code-block")).toHaveLength(24);
    expect(initial.explicitParserInputCodeUnits).toBe(source.length);

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={`${source}!`}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );
    const after = streamingMarkdownDiagnostics();
    expect(after.explicitParserInputCodeUnits - initial.explicitParserInputCodeUnits).toBeLessThanOrEqual(
      source.length + 1
    );
  });

  test("closer candidates consume each streamed marker exactly once", () => {
    const opener = "`".repeat(4_000);
    const source = `${opener}text\nbody\n`;
    resetStreamingMarkdownDiagnostics();
    const mounted = mount(
      <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
    );
    const initial = streamingMarkdownDiagnostics();

    for (let index = 1; index <= 1_000; index += 1) {
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            text={`${source}${"`".repeat(index)}`}
            streaming
            streamGeneration={0}
            streamEpoch={0}
          />
        </CopyProvider>
      );
    }

    const after = streamingMarkdownDiagnostics();
    expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
    expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(1_000);
    expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
    expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(1_000);
    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe("body");
  });

  test("spaces after a complete EOF closer never reparse the fenced body", () => {
    const payload = "c".repeat(120_000);
    const source = `\`\`\`text\n${payload}\n`;
    resetStreamingMarkdownDiagnostics();
    const mounted = mount(
      <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
    );
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={`${source}\`\`\``}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );
    const closed = streamingMarkdownDiagnostics();

    for (let index = 1; index <= 100; index += 1) {
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            text={`${source}\`\`\`${" ".repeat(index)}`}
            streaming
            streamGeneration={0}
            streamEpoch={0}
          />
        </CopyProvider>
      );
    }

    const after = streamingMarkdownDiagnostics();
    expect(after.validationCodeUnits - closed.validationCodeUnits).toBe(0);
    expect(after.scannerCodeUnits - closed.scannerCodeUnits).toBe(100);
    expect(after.parserInputCodeUnits - closed.parserInputCodeUnits).toBe(0);
    expect(after.totalCodeUnits - closed.totalCodeUnits).toBe(100);
    fireEvent.click(mounted.container.querySelector(".code-block-more")!);
    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(payload);
  });

  test("CRLF split across opener and body deltas adds no blank code line", () => {
    const opener = mount(
      <Markdown
        text={"```text\r"}
        streaming
        streamGeneration={0}
        streamEpoch={0}
      />
    );
    opener.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={"```text\r\nbody"}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );
    expect(opener.container.querySelector(".code-block-body")?.textContent).toBe("body");

    const body = mount(
      <Markdown
        text={"```text\r\nfirst\r"}
        streaming
        streamGeneration={0}
        streamEpoch={0}
      />
    );
    body.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={"```text\r\nfirst\r\nsecond"}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );
    expect(body.container.querySelector(".code-block-body")?.textContent).toBe("first\r\nsecond");
  });

  test("mixed line endings copy identically at every live split and after settle", async () => {
    const source = "```text\r\nfirst\r\nsecond\nthird\r\nfourth";
    const contentStart = source.indexOf("\n") + 1;
    const copied: string[] = [];
    const clipboardDescriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
    window.supermuxHarnessMock = {
      async copyText({ text }: { text: string }) {
        copied.push(text);
      }
    } as unknown as HarnessBridge;

    const stripTrailingLineEnding = (text: string): string =>
      text.endsWith("\r\n")
        ? text.slice(0, -2)
        : text.endsWith("\r") || text.endsWith("\n")
          ? text.slice(0, -1)
          : text;

    try {
      const mounted = mount(
        <Markdown text="" streaming streamGeneration={0} streamEpoch={0} />
      );
      for (let split = 1; split <= source.length; split += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={source.slice(0, split)}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
        const button = mounted.container.querySelector<HTMLButtonElement>(".copy-btn");
        if (!button) continue;
        await act(async () => {
          fireEvent.click(button);
          await Promise.resolve();
        });
        expect(copied[copied.length - 1]).toBe(
          stripTrailingLineEnding(source.slice(contentStart, split))
        );
      }

      const finalLiveCopy = copied[copied.length - 1];
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown text={source} />
        </CopyProvider>
      );
      await act(async () => {
        fireEvent.click(mounted.container.querySelector<HTMLButtonElement>(".copy-btn")!);
        await Promise.resolve();
      });
      expect(finalLiveCopy).toBe("first\r\nsecond\nthird\r\nfourth");
      expect(copied[copied.length - 1]).toBe(finalLiveCopy);
      mounted.unmount();
    } finally {
      if (clipboardDescriptor) {
        Object.defineProperty(navigator, "clipboard", clipboardDescriptor);
      } else {
        Reflect.deleteProperty(navigator, "clipboard");
      }
    }
  });

  test("initial mount, remount, generation reset, and EOF invalidation preserve CRLF bytes", async () => {
    const copied: string[] = [];
    const clipboardDescriptor = Object.getOwnPropertyDescriptor(navigator, "clipboard");
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
    window.supermuxHarnessMock = {
      async copyText({ text }: { text: string }) {
        copied.push(text);
      }
    } as unknown as HarnessBridge;
    const clickCopy = async (container: HTMLElement): Promise<string> => {
      await act(async () => {
        fireEvent.click(container.querySelector<HTMLButtonElement>(".copy-btn")!);
        await Promise.resolve();
      });
      return copied[copied.length - 1];
    };

    try {
      const initialSource = "```text\r\nfirst\r\nsecond\nthird\rfourth";
      const expectedInitial = "first\r\nsecond\nthird\rfourth";
      const mounted = mount(
        <Markdown
          key="initial"
          text={initialSource}
          streaming
          streamGeneration={1}
          streamEpoch={0}
        />
      );
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(expectedInitial);
      expect(await clickCopy(mounted.container)).toBe(expectedInitial);

      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            key="virtual-remount"
            text={initialSource}
            streaming
            streamGeneration={1}
            streamEpoch={0}
          />
        </CopyProvider>
      );
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(expectedInitial);
      expect(await clickCopy(mounted.container)).toBe(expectedInitial);

      const replacementSource = "```text\r\nreplacement\r\nvalue";
      const expectedReplacement = "replacement\r\nvalue";
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            key="virtual-remount"
            text={replacementSource}
            streaming
            streamGeneration={2}
            streamEpoch={0}
          />
        </CopyProvider>
      );
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(
        expectedReplacement
      );
      expect(await clickCopy(mounted.container)).toBe(expectedReplacement);

      const closed = "```text\r\nfirst\r\nsecond\r\n```";
      const invalidated = `${closed}not-a-close`;
      const expectedInvalidated = "first\r\nsecond\r\n```not-a-close";
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            key="virtual-remount"
            text={closed}
            streaming
            streamGeneration={3}
            streamEpoch={0}
          />
        </CopyProvider>
      );
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            key="virtual-remount"
            text={invalidated}
            streaming
            streamGeneration={3}
            streamEpoch={0}
          />
        </CopyProvider>
      );
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(
        expectedInvalidated
      );
      expect(await clickCopy(mounted.container)).toBe(expectedInvalidated);

      const settled = mount(<Markdown text={invalidated} />);
      expect(settled.container.querySelector(".code-block-body")?.textContent).toBe(
        expectedInvalidated
      );
      expect(await clickCopy(settled.container)).toBe(expectedInvalidated);
      mounted.unmount();
      settled.unmount();
    } finally {
      if (clipboardDescriptor) {
        Object.defineProperty(navigator, "clipboard", clipboardDescriptor);
      } else {
        Reflect.deleteProperty(navigator, "clipboard");
      }
    }
  });

  test("user text matching the former fence probe token cannot capture following prose", () => {
    const userText = "\u{e000}supermux-open-fence-probe\u{e001}";
    const source = `\`\`\`text\n${userText}\n\`\`\`\n`;
    const mounted = mount(
      <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
    );
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={`${source}AFTER`}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );

    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(userText);
    expect(mounted.container.querySelector("p")?.textContent).toBe("AFTER");
  });

  test("every opener split point converges to exact settled Markdown", () => {
    const cases = [
      {
        name: "long-backtick-delimiter-info-crlf",
        source: "`````typescript\r\nbody",
        codeBlocks: 1,
        body: "body"
      },
      {
        name: "long-tilde-delimiter-info",
        source: "~~~~~shell\nbody",
        codeBlocks: 1,
        body: "body"
      },
      {
        name: "blockquote-prefix",
        source: "> ```ruby\r\n> body",
        codeBlocks: 1,
        body: "body"
      },
      {
        name: "list-prefix",
        source: "- ```go\r\n  body",
        codeBlocks: 1,
        body: "body"
      },
      {
        name: "interleaved-prefix",
        source: "> - ~~~~rust\r\n>   body",
        codeBlocks: 1,
        body: "body"
      },
      {
        name: "invalid-backtick-info",
        source: "```java`script\r\nbody",
        codeBlocks: 0,
        body: undefined
      }
    ];

    for (const fixture of cases) {
      const openerEnd = fixture.source.indexOf("\n") + 1;
      for (let split = 0; split <= openerEnd; split += 1) {
        resetStreamingMarkdownDiagnostics();
        const mounted = mount(
          <Markdown
            text={fixture.source.slice(0, split)}
            streaming
            streamGeneration={0}
            streamEpoch={0}
          />
        );
        const initial = streamingMarkdownDiagnostics();
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={fixture.source}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
        const after = streamingMarkdownDiagnostics();
        const settled = mount(<Markdown text={fixture.source} />);

        expect({
          name: fixture.name,
          split,
          liveBlocks: mounted.container.querySelectorAll(".code-block").length,
          settledBlocks: settled.container.querySelectorAll(".code-block").length
        }).toEqual({
          name: fixture.name,
          split,
          liveBlocks: fixture.codeBlocks,
          settledBlocks: fixture.codeBlocks
        });
        expect(mounted.container.textContent).toBe(settled.container.textContent);
        if (fixture.body !== undefined) {
          expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(fixture.body);
        }
        expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
        expect(after.totalCodeUnits - initial.totalCodeUnits).toBeLessThanOrEqual(
          fixture.source.length * 3
        );
        mounted.unmount();
        settled.unmount();
      }
    }
  });

  test("a 2,000-marker pending opener consumes only newly appended delimiters", () => {
    const delimiter = "`".repeat(2_000);
    resetStreamingMarkdownDiagnostics();
    const mounted = mount(
      <Markdown text={"```"} streaming streamGeneration={0} streamEpoch={0} />
    );
    const initial = streamingMarkdownDiagnostics();

    for (let length = 4; length <= delimiter.length; length += 1) {
      mounted.rerender(
        <CopyProvider dict={undefined}>
          <Markdown
            text={delimiter.slice(0, length)}
            streaming
            streamGeneration={0}
            streamEpoch={0}
          />
        </CopyProvider>
      );
    }

    const pending = streamingMarkdownDiagnostics();
    expect(mounted.container.textContent).toBe(delimiter);
    expect(pending.validationCodeUnits - initial.validationCodeUnits).toBe(0);
    expect(pending.scannerCodeUnits - initial.scannerCodeUnits).toBe(1_997);
    expect(pending.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
    expect(pending.totalCodeUnits - initial.totalCodeUnits).toBe(1_997);

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <Markdown
          text={`${delimiter}typescript\nbody`}
          streaming
          streamGeneration={0}
          streamEpoch={0}
        />
      </CopyProvider>
    );
    expect(mounted.container.querySelector(".code-chip")?.textContent).toBe("typescript");
    expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe("body");
  });

  test("pending opener DOM assignments stay linear with bounded text chunks", () => {
    const nodeValue = Object.getOwnPropertyDescriptor(CharacterData.prototype, "nodeValue");
    const setNodeValue = nodeValue?.set;
    if (!nodeValue || !setNodeValue) {
      throw new Error("CharacterData.nodeValue setter unavailable");
    }
    const originalCreateTextNode = Document.prototype.createTextNode;
    let assignedCodeUnits = 0;
    let assignments = 0;
    let maxAssignment = 0;
    const record = (value: string): void => {
      assignedCodeUnits += value.length;
      assignments += 1;
      maxAssignment = Math.max(maxAssignment, value.length);
    };

    Document.prototype.createTextNode = function createTextNode(
      this: Document,
      data: string
    ): Text {
      record(data);
      return originalCreateTextNode.call(this, data);
    };
    Object.defineProperty(CharacterData.prototype, "nodeValue", {
      ...nodeValue,
      set(this: CharacterData, value: string | null) {
        record(value ?? "");
        setNodeValue.call(this, value);
      }
    });

    try {
      const fixtures = [
        { name: "backtick", source: "`".repeat(2_000) },
        { name: "tilde", source: "~".repeat(2_000) },
        { name: "long-info", source: `\`\`\`${"x".repeat(1_997)}` }
      ];
      for (const fixture of fixtures) {
        assignedCodeUnits = 0;
        assignments = 0;
        maxAssignment = 0;
        const mounted = mount(
          <Markdown
            text={fixture.source.slice(0, 3)}
            streaming
            streamGeneration={0}
            streamEpoch={0}
          />
        );
        for (let length = 4; length <= fixture.source.length; length += 1) {
          mounted.rerender(
            <CopyProvider dict={undefined}>
              <Markdown
                text={fixture.source.slice(0, length)}
                streaming
                streamGeneration={0}
                streamEpoch={0}
              />
            </CopyProvider>
          );
        }

        const chunks = Array.from(
          mounted.container.querySelectorAll<HTMLElement>(".md-pending-opener span")
        );
        expect({ name: fixture.name, text: mounted.container.textContent }).toEqual({
          name: fixture.name,
          text: fixture.source
        });
        expect(chunks).toHaveLength(32);
        expect(Math.max(...chunks.map((chunk) => chunk.textContent?.length ?? 0))).toBe(64);
        expect(maxAssignment).toBe(64);
        expect(assignments).toBe(1_966);
        expect(assignedCodeUnits).toBe(64_579);
        mounted.unmount();
      }
    } finally {
      Document.prototype.createTextNode = originalCreateTextNode;
      Object.defineProperty(CharacterData.prototype, "nodeValue", nodeValue);
    }
  });

  test("every intermediate opener prefix is safe and converges without leaked state", () => {
    const cases = [
      "`````typescript\r\nbody",
      "~~~~~shell\nbody",
      "> ```ruby\r\n> body",
      "- ```go\r\n  body",
      "> - ~~~~rust\r\n>   body",
      "```java`script\r\nbody"
    ];

    for (const source of cases) {
      resetStreamingMarkdownDiagnostics();
      const mounted = mount(
        <Markdown text="" streaming streamGeneration={0} streamEpoch={0} />
      );
      const openerEnd = source.indexOf("\n") + 1;
      for (let split = 1; split <= source.length; split += 1) {
        const prefix = source.slice(0, split);
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={prefix}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
        if (
          split < openerEnd &&
          !prefix.endsWith("\r") &&
          !prefix.endsWith("\n") &&
          /[`~]{3}/.test(prefix)
        ) {
          expect(mounted.container.textContent).toBe(prefix);
        }
      }
      const settled = mount(<Markdown text={source} />);
      expect(mounted.container.textContent).toBe(settled.container.textContent);
      expect(mounted.container.querySelectorAll(".code-block")).toHaveLength(
        settled.container.querySelectorAll(".code-block").length
      );
      expect(streamingMarkdownDiagnostics().validationCodeUnits).toBe(0);
      mounted.unmount();
      settled.unmount();
    }
  });

  test("invalidating a parsed EOF closer preserves its physical separator", () => {
    for (const lineEnding of ["\n", "\r\n"]) {
      const marker = lineEnding === "\n" ? "```" : "~~~";
      const source = `${marker}text${lineEnding}body${lineEnding}${marker}`;
      const prose = "not-a-close";
      resetStreamingMarkdownDiagnostics();
      const mounted = mount(
        <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
      );
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= prose.length; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${source}${prose.slice(0, index)}`}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(
        `body${lineEnding}${marker}${prose}`
      );
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(prose.length);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(prose.length);
      mounted.unmount();
    }
  });

  test("a closer plus prose streamed character by character remains code", () => {
    for (const lineEnding of ["\n", "\r\n"]) {
      const marker = lineEnding === "\n" ? "```" : "~~~";
      const source = `${marker}text${lineEnding}body${lineEnding}`;
      const suffix = `${marker}not-a-close`;
      resetStreamingMarkdownDiagnostics();
      const mounted = mount(
        <Markdown text={source} streaming streamGeneration={0} streamEpoch={0} />
      );
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= suffix.length; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${source}${suffix.slice(0, index)}`}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(mounted.container.querySelector(".code-block-body")?.textContent).toBe(
        `body${lineEnding}${suffix}`
      );
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(suffix.length);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(suffix.length);
      mounted.unmount();
    }
  });

  test("interleaved containers and tab prefixes stay O(delta)", () => {
    const payload = "i".repeat(80_000);
    const cases = [
      { name: "list-blockquote", prefix: "- > ```js\n  > " },
      { name: "blockquote-list-blockquote", prefix: "> - > ```js\n>   > " },
      { name: "nested-lists-blockquote", prefix: "- 1. > ```js\n     > " },
      { name: "blockquote-tab", prefix: ">\t````js\n>\t" },
      { name: "list-tab", prefix: "-\t````js\n\t" }
    ];

    for (const fixture of cases) {
      resetStreamingMarkdownDiagnostics();
      const initialText = `${fixture.prefix}${payload}`;
      const mounted = mount(
        <Markdown text={initialText} streaming streamGeneration={0} streamEpoch={0} />
      );
      expect({ name: fixture.name, blocks: mounted.container.querySelectorAll(".code-block").length }).toEqual({
        name: fixture.name,
        blocks: 1
      });
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= 32; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${initialText}${"z".repeat(index)}`}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(32);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(32);
      fireEvent.click(mounted.container.querySelector(".code-block-more")!);
      expect(mounted.container.querySelector(".code-block-body")?.textContent?.endsWith("z".repeat(32))).toBe(
        true
      );
      mounted.unmount();
    }
  });

  test("overshooting continuation tabs feed excess columns into nested fence indentation", () => {
    const payload = "o".repeat(80_000);
    const cases = [
      { name: "list-opening-indent", prefix: "- item\n\t```text\n\t" },
      { name: "list-blockquote", prefix: "- item\n\t> ```text\n\t> " },
      { name: "blockquote-list", prefix: "> - item\n>\t```text\n>\t" },
      {
        name: "nested-lists-blockquote",
        prefix: "- outer\n  - inner\n\t  > ```text\n\t  > "
      }
    ];

    for (const fixture of cases) {
      resetStreamingMarkdownDiagnostics();
      const initialText = `${fixture.prefix}${payload}`;
      const mounted = mount(
        <Markdown text={initialText} streaming streamGeneration={0} streamEpoch={0} />
      );
      expect({ name: fixture.name, blocks: mounted.container.querySelectorAll(".code-block").length }).toEqual({
        name: fixture.name,
        blocks: 1
      });
      const initial = streamingMarkdownDiagnostics();

      for (let index = 1; index <= 32; index += 1) {
        mounted.rerender(
          <CopyProvider dict={undefined}>
            <Markdown
              text={`${initialText}${"z".repeat(index)}`}
              streaming
              streamGeneration={0}
              streamEpoch={0}
            />
          </CopyProvider>
        );
      }

      const after = streamingMarkdownDiagnostics();
      expect(after.validationCodeUnits - initial.validationCodeUnits).toBe(0);
      expect(after.scannerCodeUnits - initial.scannerCodeUnits).toBe(32);
      expect(after.parserInputCodeUnits - initial.parserInputCodeUnits).toBe(0);
      expect(after.totalCodeUnits - initial.totalCodeUnits).toBe(32);
      fireEvent.click(mounted.container.querySelector(".code-block-more")!);
      expect(mounted.container.querySelector(".code-block-body")?.textContent?.endsWith("z".repeat(32))).toBe(
        true
      );
      mounted.unmount();
    }
  });

  test("fence opener recognition matches the settled CommonMark parser", () => {
    const cases = [
      {
        name: "backtick-info-containing-backtick",
        source: "```java`script\nconst value = 1;",
        codeBlocks: 0
      },
      {
        name: "tilde-info-containing-backtick",
        source: "~~~java`script\nconst value = 1;",
        codeBlocks: 1
      }
    ];

    for (const fixture of cases) {
      const live = mount(<Markdown text={fixture.source} streaming streamEpoch={0} />);
      const settled = mount(<Markdown text={fixture.source} />);
      expect({
        name: fixture.name,
        live: live.container.querySelectorAll(".code-block").length,
        settled: settled.container.querySelectorAll(".code-block").length
      }).toEqual({
        name: fixture.name,
        live: fixture.codeBlocks,
        settled: fixture.codeBlocks
      });
      expect(live.container.textContent).toBe(settled.container.textContent);
      live.unmount();
      settled.unmount();
    }
  });

  test("backtick and tilde closing fences are complete at EOF without a newline", () => {
    for (const marker of ["```", "~~~"]) {
      const mounted = mount(
        <Markdown text={`${marker}javascript\nconst closed = true;\n${marker}`} streaming />
      );
      const body = mounted.container.querySelector(".code-block-body");
      expect(body?.textContent).toBe("const closed = true;");
      expect(mounted.container.textContent).not.toContain(`${marker}javascript`);
      mounted.unmount();
    }
  });
});

describe("TaskOutput switches identity atomically", () => {
  test("task A output disappears while task B is pending and stays gone when B fails", async () => {
    const taskB = deferred<{ text?: string; truncated: boolean; missing: boolean }>();
    window.supermuxHarnessMock = {
      readTaskOutput({ taskId }: { taskId: string }) {
        return taskId === "task-a"
          ? Promise.resolve({ text: "output from task A", truncated: false, missing: false })
          : taskB.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(<TaskOutputView taskId="task-a" running={false} />);
    await waitFor(() => expect(mounted.container.textContent).toContain("output from task A"));

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <TaskOutputView taskId="task-b" running={false} />
      </CopyProvider>
    );
    expect(mounted.container.textContent).not.toContain("output from task A");
    expect(mounted.container.textContent).toContain("Reading output…");

    await act(async () => {
      taskB.reject(new Error("task B failed"));
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("Could not read the output."));
    expect(mounted.container.textContent).not.toContain("output from task A");
  });

  test("a stale task A completion cannot overwrite pending task B", async () => {
    const taskA = deferred<{ text?: string; truncated: boolean; missing: boolean }>();
    const taskB = deferred<{ text?: string; truncated: boolean; missing: boolean }>();
    window.supermuxHarnessMock = {
      readTaskOutput({ taskId }: { taskId: string }) {
        return taskId === "task-a" ? taskA.promise : taskB.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(<TaskOutputView taskId="task-a" running={false} />);
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <TaskOutputView taskId="task-b" running={false} />
      </CopyProvider>
    );
    await act(async () => {
      taskA.resolve({ text: "late task A", truncated: false, missing: false });
      await Promise.resolve();
    });
    expect(mounted.container.textContent).not.toContain("late task A");
    expect(mounted.container.textContent).toContain("Reading output…");

    await act(async () => {
      taskB.resolve({ text: "task B output", truncated: false, missing: false });
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("task B output"));
  });
});

describe("subagent transcript identity changes are atomic", () => {
  test("ready agent A disappears immediately while agent B is pending", async () => {
    const taskB = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    window.supermuxHarnessMock = {
      loadSubagentTranscript({ taskId }: { taskId?: string }) {
        return taskId === "agent-a"
          ? Promise.resolve({ events: transcriptEvents("agent A"), truncated: false, missing: false })
          : taskB.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(
      <SubagentTranscriptView target={{ taskId: "agent-a" }} open />
    );
    await waitFor(() => expect(mounted.container.textContent).toContain("agent A transcript"));

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <SubagentTranscriptView target={{ taskId: "agent-b" }} open />
      </CopyProvider>
    );
    expect(mounted.container.textContent).not.toContain("agent A transcript");
    expect(mounted.container.querySelector(".drill-status")).not.toBeNull();
  });

  test("a failed agent B cannot retain ready agent A content", async () => {
    const taskB = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    window.supermuxHarnessMock = {
      loadSubagentTranscript({ taskId }: { taskId?: string }) {
        return taskId === "agent-a"
          ? Promise.resolve({ events: transcriptEvents("agent A"), truncated: false, missing: false })
          : taskB.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(
      <SubagentTranscriptView target={{ taskId: "agent-a" }} open />
    );
    await waitFor(() => expect(mounted.container.textContent).toContain("agent A transcript"));
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <SubagentTranscriptView target={{ taskId: "agent-b" }} open />
      </CopyProvider>
    );

    await act(async () => {
      taskB.reject(new Error("agent B failed"));
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("Could not read"));
    expect(mounted.container.textContent).not.toContain("agent A transcript");
  });

  test("local and workflow identities never share models or stale completions", async () => {
    const localFirst = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    const localSecond = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    const workflow = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    let localCalls = 0;
    window.supermuxHarnessMock = {
      loadSubagentTranscript(params: {
        taskId?: string;
        workflowRunId?: string;
        agentId?: string;
      }) {
        if (params.taskId) {
          localCalls += 1;
          return localCalls === 1 ? localFirst.promise : localSecond.promise;
        }
        return workflow.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(
      <SubagentTranscriptView target={{ taskId: "shared-agent" }} open />
    );
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <SubagentTranscriptView
          target={{ workflowRunId: "workflow-1", agentId: "shared-agent" }}
          open
        />
      </CopyProvider>
    );
    await act(async () => {
      localFirst.resolve({ events: transcriptEvents("stale local"), truncated: false, missing: false });
      await Promise.resolve();
    });
    expect(mounted.container.textContent).not.toContain("stale local transcript");
    expect(mounted.container.querySelector(".drill-status")).not.toBeNull();

    await act(async () => {
      workflow.resolve({ events: transcriptEvents("workflow"), truncated: false, missing: false });
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("workflow transcript"));

    mounted.rerender(
      <CopyProvider dict={undefined}>
        <SubagentTranscriptView target={{ taskId: "shared-agent" }} open />
      </CopyProvider>
    );
    expect(mounted.container.textContent).not.toContain("workflow transcript");
    expect(mounted.container.querySelector(".drill-status")).not.toBeNull();

    await act(async () => {
      localSecond.resolve({ events: transcriptEvents("fresh local"), truncated: false, missing: false });
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("fresh local transcript"));
  });

  test("a same-agent tick retains ready content while its refresh is pending", async () => {
    const refresh = deferred<{ events: ProtocolLine[]; truncated: boolean; missing: boolean }>();
    let calls = 0;
    window.supermuxHarnessMock = {
      loadSubagentTranscript() {
        calls += 1;
        return calls === 1
          ? Promise.resolve({ events: transcriptEvents("cached agent"), truncated: false, missing: false })
          : refresh.promise;
      }
    } as unknown as HarnessBridge;

    const mounted = mount(
      <SubagentTranscriptView target={{ taskId: "same-agent" }} open tick={1} />
    );
    await waitFor(() => expect(mounted.container.textContent).toContain("cached agent transcript"));
    mounted.rerender(
      <CopyProvider dict={undefined}>
        <SubagentTranscriptView target={{ taskId: "same-agent" }} open tick={2} />
      </CopyProvider>
    );
    expect(mounted.container.textContent).toContain("cached agent transcript");
    expect(mounted.container.querySelector(".drill-status")).toBeNull();

    await act(async () => {
      refresh.resolve({ events: transcriptEvents("refreshed agent"), truncated: false, missing: false });
      await Promise.resolve();
    });
    await waitFor(() => expect(mounted.container.textContent).toContain("refreshed agent transcript"));
    expect(mounted.container.textContent).not.toContain("cached agent transcript");
  });
});

describe("virtual transcript ranges preserve turn identity", () => {
  test("prepending rows keeps the same mounted viewport window and shifts only absolute positions", () => {
    const rows = Array.from({ length: 90 }, (_, index) => ({
      ...turn(`turn-${index + 1}`),
      state: "complete" as const,
      endedAtMs: 2
    }));
    const following = { current: false };
    const scrollRef = { current: null as HTMLDivElement | null };
    const props = (visibleRows: Turn[]) => (
      <CopyProvider dict={undefined}>
        <TranscriptList
          turns={visibleRows}
          scrollRef={scrollRef}
          following={following}
          showPill={false}
          onJump={() => {}}
        />
      </CopyProvider>
    );
    const mounted = render(props(rows));
    fireEvent.click(mounted.container.querySelector<HTMLButtonElement>(".transcript-earlier .link-btn")!);
    fireEvent.click(mounted.container.querySelector<HTMLButtonElement>(".transcript-earlier .link-btn")!);

    const before = Array.from(mounted.container.querySelectorAll<HTMLElement>(".turn"));
    const beforeIds = before.map((node) => node.dataset.turnId);
    const beforePosition = Number(before[0].getAttribute("aria-posinset"));
    expect(beforeIds.length).toBeGreaterThan(20);

    const prepended = Array.from({ length: 10 }, (_, index) => ({
      ...turn(`prepended-${index + 1}`),
      state: "complete" as const,
      endedAtMs: 2
    }));
    mounted.rerender(props([...prepended, ...rows]));

    const after = Array.from(mounted.container.querySelectorAll<HTMLElement>(".turn"));
    expect(after.map((node) => node.dataset.turnId)).toEqual(beforeIds);
    expect(Number(after[0].getAttribute("aria-posinset"))).toBe(beforePosition + prepended.length);
  });

  test("rewind removal of the mounted window falls back to a visible surviving tail", () => {
    const rows = Array.from({ length: 120 }, (_, index) => ({
      ...turn(`rewind-${index + 1}`),
      state: "complete" as const,
      endedAtMs: 2
    }));
    const following = { current: false };
    const scrollRef = { current: null as HTMLDivElement | null };
    const props = (visibleRows: Turn[]) => (
      <CopyProvider dict={undefined}>
        <TranscriptList
          turns={visibleRows}
          scrollRef={scrollRef}
          following={following}
          showPill={false}
          onJump={() => {}}
        />
      </CopyProvider>
    );
    const mounted = render(props(rows));
    expect(mounted.container.querySelector("[data-turn-id='rewind-120']")).not.toBeNull();

    mounted.rerender(props(rows.slice(0, 40)));

    const survivors = mounted.container.querySelectorAll(".turn");
    expect(survivors.length).toBeGreaterThan(0);
    expect(survivors.length).toBeLessThanOrEqual(48);
    expect(mounted.container.querySelector("[data-turn-id='rewind-40']")).not.toBeNull();
  });

  test("empty history becoming nonempty mounts the ordinary bounded tail window", () => {
    const rows = Array.from({ length: 60 }, (_, index) => ({
      ...turn(`history-${index + 1}`),
      state: "complete" as const,
      endedAtMs: 2
    }));
    const following = { current: false };
    const scrollRef = { current: null as HTMLDivElement | null };
    const props = (visibleRows: Turn[]) => (
      <CopyProvider dict={undefined}>
        <TranscriptList
          turns={visibleRows}
          scrollRef={scrollRef}
          following={following}
          showPill={false}
          onJump={() => {}}
        />
      </CopyProvider>
    );
    const mounted = render(props([]));
    mounted.rerender(props(rows));

    const visible = Array.from(mounted.container.querySelectorAll<HTMLElement>(".turn"));
    expect(visible).toHaveLength(26);
    expect(visible[0].dataset.turnId).toBe("history-35");
    expect(visible[25].dataset.turnId).toBe("history-60");
  });
});

describe("measured growth preserves the recorded viewport anchor", () => {
  test("a row growing above the viewport corrects by its height delta before accepting it", async () => {
    const originalRect = HTMLElement.prototype.getBoundingClientRect;
    const layout = { row0Height: 100, row1Top: 50 };
    let rootNode: HTMLDivElement | null = null;
    let measure: ((id: string, height: number) => void) | undefined;
    const domRect = (top: number, height: number): DOMRect => ({
      x: 0,
      y: top,
      width: 100,
      height,
      top,
      right: 100,
      bottom: top + height,
      left: 0,
      toJSON: () => ({})
    });

    HTMLElement.prototype.getBoundingClientRect = function getBoundingClientRect() {
      if (this.classList.contains("measurement-root")) return domRect(0, 400);
      const scrollTop = rootNode?.scrollTop ?? 0;
      if (this.dataset.virtualTurnId === "row-0") {
        return domRect(-120 - scrollTop, layout.row0Height);
      }
      if (this.dataset.virtualTurnId === "row-1") {
        return domRect(layout.row1Top - scrollTop, 100);
      }
      return originalRect.call(this);
    };

    function Probe() {
      const scrollRef = useRef<HTMLDivElement>(null);
      const following = useRef(false);
      const virtual = useTranscriptWindow({
        turnIds: ["row-0", "row-1"],
        scrollRef,
        following,
        resetKey: 0,
        onAnchorCorrection(delta) {
          if (scrollRef.current) scrollRef.current.scrollTop += delta;
        }
      });
      useLayoutEffect(() => {
        rootNode = scrollRef.current;
        measure = virtual.measure;
      }, [virtual.measure]);
      return (
        <div ref={scrollRef} className="measurement-root">
          <div data-virtual-turn-id="row-0" />
          <div data-virtual-turn-id="row-1" />
        </div>
      );
    }

    try {
      render(<Probe />);
      await act(async () => {
        measure!("row-0", 100);
        await new Promise((resolve) => window.setTimeout(resolve, 25));
      });

      layout.row0Height = 140;
      layout.row1Top = 90;
      act(() => measure!("row-0", 140));

      const mountedRoot = document.querySelector<HTMLDivElement>(".measurement-root")!;
      expect(mountedRoot.scrollTop).toBe(40);
      const anchor = document.querySelector<HTMLElement>("[data-virtual-turn-id='row-1']")!;
      expect(anchor.getBoundingClientRect().top).toBe(50);
    } finally {
      HTMLElement.prototype.getBoundingClientRect = originalRect;
    }
  });
});

describe("ANSI C1 controls are atomic and invisible", () => {
  test("C1 CSI, OSC, string controls, and incomplete prefixes never leak", () => {
    const text = `plain\u009b31mRED\u009b0m\u009dtitle\u009ctail\u0090private\u009cEND\u009b38;5;`;
    const stripped = stripAnsi(text);
    expect(stripped).toBe("plainREDtailEND");
    expect(stripped).not.toMatch(/[\u0080-\u009f]/);
    expect(stripped).not.toContain("38;5;");

    const parsed = parseAnsi(text);
    expect(parsed.flatMap((line) => line.spans).map((span) => span.text).join(""))
      .toBe("plainREDtailEND");
    expect(parsed.flatMap((line) => line.spans).find((span) => span.text === "RED")?.className)
      .toContain("ansi-red");
  });

  test("CAN and SUB cancel C1 CSI while subsequent visible text recovers", () => {
    for (const cancel of ["\u0018", "\u001a"]) {
      const source = `before\u009b38;5;196${cancel}RECOVERED`;
      expect(stripAnsi(source)).toBe("beforeRECOVERED");
      expect(parseAnsi(source).flatMap((line) => line.spans).map((span) => span.text).join(""))
        .toBe("beforeRECOVERED");
      const clipped = clipAnsiUtf8(source, 10_000);
      expect(stripAnsi(clipped.text)).toBe("beforeRECOVERED");
      expect(clipped.truncated).toBe(false);
    }
  });

  test("CAN and SUB cancel every ESC and C1 string control", () => {
    const esc = String.fromCharCode(0x1b);
    const introductions = [
      { name: "ESC OSC", value: `${esc}]` },
      { name: "C1 OSC", value: String.fromCharCode(0x9d) },
      { name: "ESC DCS", value: `${esc}P` },
      { name: "C1 DCS", value: String.fromCharCode(0x90) },
      { name: "ESC SOS", value: `${esc}X` },
      { name: "C1 SOS", value: String.fromCharCode(0x98) },
      { name: "ESC PM", value: `${esc}^` },
      { name: "C1 PM", value: String.fromCharCode(0x9e) },
      { name: "ESC APC", value: `${esc}_` },
      { name: "C1 APC", value: String.fromCharCode(0x9f) }
    ];
    for (const introduction of introductions) {
      for (const cancel of [String.fromCharCode(0x18), String.fromCharCode(0x1a)]) {
        const source = `before${introduction.value}private${cancel}RECOVERED`;
        const visible = "beforeRECOVERED";
        expect({ name: introduction.name, stripped: stripAnsi(source) }).toEqual({
          name: introduction.name,
          stripped: visible
        });
        expect(
          parseAnsi(source).flatMap((line) => line.spans).map((span) => span.text).join("")
        ).toBe(visible);
        const clipped = clipAnsiUtf8(source, 10_000);
        expect(stripAnsi(clipped.text)).toBe(visible);
        expect(clipped.truncated).toBe(false);
      }
    }
  });

  test("a byte boundary inside C1 CSI stops before the whole sequence", () => {
    const prefix = "a".repeat(24 * 1024 - 1);
    const clipped = clipAnsiUtf8(`${prefix}\u009b31mRED`, 24 * 1024);
    expect(clipped.text).toBe(prefix);
    expect(clipped.text).not.toMatch(/[\u0080-\u009f]/);
    expect(clipped.text).not.toContain("31m");
  });
});

describe("the turn loader has no dot constellation", () => {
  test("WorkingDots exposes a status-text slot, never pulsing dot children", () => {
    const direct = render(<WorkingDots />);
    expect(direct.container.querySelectorAll(".working-dots i")).toHaveLength(0);
    expect(direct.container.querySelector(".working-dots")!.children.length).toBeGreaterThan(0);

    const live = mount(<TurnView turn={turn("loader")} isLast />);
    const mark = live.container.querySelector(".turn-live .working-dots");
    expect(mark?.querySelectorAll("i")).toHaveLength(0);
    expect(mark?.querySelector(".turn-live-label")?.textContent).toContain("Working for");
  });
});

describe("wasLive presentation state is bounded per turn", () => {
  test("hundreds of historical live keys retain a bounded recent set after settlement", () => {
    const count = 320;
    const liveBlocks = Array.from({ length: count }, (_, index) => tool(`tool-${index}`, "running"));
    const settledBlocks = liveBlocks.map((block) => ({
      ...block,
      status: "success" as const,
      streaming: false,
      endedAtMs: 2
    }));
    const props = (blocks: ToolBlock[]) => (
      <CopyProvider dict={undefined}>
        <PresentationStateProvider generation={0}>
          <TurnView turn={turn("bounded-live", blocks)} isLast />
        </PresentationStateProvider>
      </CopyProvider>
    );
    const mounted = render(props(liveBlocks));
    expect(mounted.container.querySelectorAll(".turn-work-item")).toHaveLength(count);
    mounted.rerender(props(settledBlocks));

    const visibleHistorical = mounted.container.querySelectorAll(".turn-work-item");
    expect(visibleHistorical.length).toBeLessThan(count);
    expect(visibleHistorical.length).toBeLessThanOrEqual(257);
    const wrappers = mounted.container.querySelectorAll(".turn-work > div");
    expect(wrappers[wrappers.length - 1].classList.contains("turn-work-item")).toBe(true);
    expect(wrappers[0].classList.contains("turn-work-hidden")).toBe(true);
  });
});

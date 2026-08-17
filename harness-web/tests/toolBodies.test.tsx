import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import type { ToolBlock } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { ToolCard } from "../src/ui/tools/ToolCard";

afterEach(cleanup);

const ENOENT =
  "Error: ENOENT: no such file or directory, open '/Users/dev/projects/supermux/Sources/Panels/NoSuchFile.swift'";

/**
 * The shape a FAILED tool actually arrives in: the CLI reports the failure as a
 * plain `content` string with `is_error: true` and sends NO `tool_use_result`.
 * Every existing card test feeds a structured payload, which is exactly why five
 * renderers silently dropped the error text for three rounds.
 */
function failedBlock(name: string, input: Record<string, unknown> = {}): ToolBlock {
  return {
    kind: "tool",
    key: `tool:${name}`,
    toolUseId: `toolu_${name}`,
    messageId: "msg_1",
    name,
    input: input as ToolBlock["input"],
    children: [],
    status: "error",
    streaming: false,
    inputComplete: true,
    resultText: ENOENT,
    resultIsError: true,
    structured: undefined,
    startedAtMs: 1000,
    endedAtMs: 1400
  };
}

function mount(block: ToolBlock) {
  return render(
    <CopyProvider dict={undefined}>
      <ToolCard block={block} />
    </CopyProvider>
  );
}

describe("a failed tool card never renders an empty body", () => {
  const cases: Array<[string, Record<string, unknown>]> = [
    ["Read", { file_path: "/Users/dev/projects/supermux/Sources/Panels/NoSuchFile.swift" }],
    ["Edit", { file_path: "/tmp/a.swift" }],
    ["Write", { file_path: "/tmp/a.swift" }],
    ["TodoWrite", {}],
    ["ExitPlanMode", {}],
    ["Grep", { pattern: "foo" }],
    ["WebFetch", { url: "https://example.com" }],
    ["Bash", { command: "ls" }]
  ];

  for (const [name, input] of cases) {
    test(`${name} shows the failure text the card auto-opened to reveal`, () => {
      const { container } = mount(failedBlock(name, input));
      // `defaultOpen` returns true for every error, so the body is mounted: the
      // card promises detail with a caret, an error tint AND an auto-open.
      expect(container.querySelector(".tool-body")).not.toBeNull();
      expect(container.textContent).toContain("ENOENT");
    });
  }

  test("the failure is toned as an error, not as ordinary output", () => {
    const { container } = mount(failedBlock("Read", { file_path: "/tmp/x.swift" }));
    expect(container.querySelector(".terminal.is-error")).not.toBeNull();
  });

  test("the failure wraps so a long path stays on screen", () => {
    // `white-space: pre` put the second half of a 100-char ENOENT behind a
    // horizontal scrollbar — the path is the one thing the card is open for.
    const { container } = mount(failedBlock("Read", { file_path: "/tmp/x.swift" }));
    expect(container.querySelector(".terminal-body.is-wrapped")).not.toBeNull();
  });

  test("a failure that arrives WITH a payload keeps both", () => {
    const block = {
      ...failedBlock("Edit", { file_path: "/tmp/a.swift" }),
      structured: {
        filePath: "/tmp/a.swift",
        structuredPatch: [
          { oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-old", "+new"] }
        ]
      }
    } as unknown as ToolBlock;
    const { container } = mount(block);
    expect(container.querySelector(".diff")).not.toBeNull();
    expect(container.textContent).toContain("ENOENT");
  });

  test("a settled tool with no result at all says so once expanded", () => {
    const block = {
      ...failedBlock("Read"),
      status: "success",
      resultText: "",
      resultIsError: false
    } as unknown as ToolBlock;
    const { container } = mount(block);
    // A success card starts collapsed; opening it must not reveal an empty box.
    fireEvent.click(container.querySelector(".tool-head")!);
    expect(container.querySelector(".tool-body")).not.toBeNull();
    expect(container.querySelector(".tool-body")!.textContent).toBe("No output");
  });

  test("a still-running tool with no result yet stays quiet", () => {
    const block = {
      ...failedBlock("Read", { file_path: "/tmp/x.swift" }),
      status: "running",
      resultText: undefined,
      endedAtMs: undefined
    } as unknown as ToolBlock;
    const { container } = mount(block);
    expect(container.querySelector(".terminal")).toBeNull();
  });
});

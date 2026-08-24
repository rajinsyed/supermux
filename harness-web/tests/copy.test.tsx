import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { copyDefaults, format, type CopyKey } from "../src/copyKeys";
import { richSession } from "../src/dev/fixtures";
import { replayLines } from "../src/model/transcript";
import type { ToolBlock, Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { formatRelativeTime } from "../src/ui/format";
import { Markdown } from "../src/ui/primitives/Markdown";
import { toolMetrics } from "../src/ui/tools/ToolBodies";
import { ToolCard } from "../src/ui/tools/ToolCard";
import { TurnView } from "../src/ui/transcript/TurnView";

afterEach(cleanup);

const copy = ((key: CopyKey, values?: Record<string, string | number>) =>
  values ? format(copyDefaults[key], values) : copyDefaults[key]) as (
  key: CopyKey,
  values?: Record<string, string | number>
) => string;

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

function toolBlocks(): ToolBlock[] {
  const model = replayLines(richSession);
  const out: ToolBlock[] = [];
  const walk = (blocks: readonly { kind: string }[]) => {
    for (const block of blocks) {
      if (block.kind !== "tool") continue;
      const tool = block as ToolBlock;
      out.push(tool);
      walk(tool.children);
    }
  };
  for (const turn of model.turns) walk(turn.blocks);
  return out;
}

describe("ToolSearch metrics name what they count", () => {
  // rich-session.jsonl line 22: {matches: [], query: "TodoWrite",
  // total_deferred_tools: 19} — zero results out of a 19-tool catalogue.
  const search = toolBlocks().find(
    (block) => block.name === "ToolSearch" && block.structured?.total_deferred_tools !== undefined
  );

  test("the real trace still carries the zero-match ToolSearch", () => {
    expect(search).toBeDefined();
    expect(search!.structured!.total_deferred_tools).toBe(19);
    expect(search!.structured!.matches).toEqual([]);
  });

  test("a zero-match search never advertises 19 matches", () => {
    const metrics = toolMetrics(search!, copy);
    expect(metrics.some((metric) => metric.includes("19 matches"))).toBe(false);
    expect(metrics).toContain("0 matches");
    expect(metrics).toContain("19 tools searched");
  });

  test("the rendered header agrees with the body", () => {
    const { container } = mount(<ToolCard block={search!} />);
    const header = container.querySelector(".tool-badges")!.textContent ?? "";
    expect(header).not.toContain("19 matches");
    expect(header).toContain("19 tools searched");
  });
});

/**
 * The counted string moved in round 6.
 *
 * "N earlier tool calls" used to be printed TWICE: on the streaming overflow,
 * where the rows really are hidden and the count is the control's whole
 * meaning, and again on the settled fold header beside "Worked for 2m 30s",
 * where it was a permanent tally of rows the reader is one click from simply
 * seeing. The settled header dropped it; the key still ships because the
 * streaming expander is still counting, so its inflection is still asserted —
 * against the surface that actually renders it now.
 */
describe("counted strings inflect at one", () => {
  /** A streaming turn whose work is exactly `count` tool blocks. */
  function streamingToolTurn(count: number): Turn {
    const model = replayLines(richSession);
    const source = model.turns.find((candidate) =>
      candidate.blocks.some((b) => b.kind === "tool")
    );
    expect(source).toBeDefined();
    const tools = model.turns
      .flatMap((turn) => turn.blocks)
      .filter((block) => block.kind === "tool")
      .slice(0, count);
    expect(tools.length).toBe(count);
    return {
      ...(source as Turn),
      blocks: tools,
      state: "streaming",
      endedAtMs: undefined,
      result: undefined
    } as Turn;
  }

  test("a single earlier tool call is singular", () => {
    // Two tools while the turn streams: the live tail keeps ONE on screen, so
    // exactly one is behind the expander.
    const { container } = mount(<TurnView turn={streamingToolTurn(2)} isLast={false} />);
    const overflow = container.querySelector(".work-overflow")!.textContent;
    expect(overflow).toBe("1 earlier tool call");
    expect(overflow).not.toBe("1 earlier tool calls");
  });

  test("two or more stays plural", () => {
    const { container } = mount(<TurnView turn={streamingToolTurn(4)} isLast={false} />);
    expect(container.querySelector(".work-overflow")!.textContent).toMatch(
      /^\d+ earlier tool calls$/
    );
  });

  test("tool metrics inflect too", () => {
    const one = toolMetrics(
      { structured: { numFiles: 1, numMatches: 1, numLines: 1 } } as unknown as ToolBlock,
      copy
    );
    expect(one).toEqual(["1 line", "1 file", "1 match"]);
    const many = toolMetrics(
      { structured: { numFiles: 4, numMatches: 9, numLines: 12 } } as unknown as ToolBlock,
      copy
    );
    expect(many).toEqual(["12 lines", "4 files", "9 matches"]);
  });
});

describe("relative time comes from the catalog", () => {
  const now = 1_700_000_000_000;

  test("every branch resolves through a copy key", () => {
    expect(formatRelativeTime(now - 10_000, copy, now)).toBe("just now");
    expect(formatRelativeTime(now - 22 * 60_000, copy, now)).toBe("22m ago");
    expect(formatRelativeTime(now - 5 * 3_600_000, copy, now)).toBe("5h ago");
    expect(formatRelativeTime(now - 3 * 86_400_000, copy, now)).toBe("3d ago");
  });

  test("a translated dict actually changes what renders", () => {
    const ja = ((key: CopyKey, values?: Record<string, string | number>) => {
      const dict: Partial<Record<CopyKey, string>> = {
        "supermux.harness.time.justNow": "たった今",
        "supermux.harness.time.minutesAgo": "{value}分前"
      };
      const template = dict[key] ?? copyDefaults[key];
      return values ? format(template, values) : template;
    }) as typeof copy;
    expect(formatRelativeTime(now - 10_000, ja, now)).toBe("たった今");
    expect(formatRelativeTime(now - 7 * 60_000, ja, now)).toBe("7分前");
  });
});

describe("assistant Markdown links", () => {
  test("renders a tagged macOS dogfood launch URL as a clickable link", () => {
    const { container } = mount(
      <Markdown text="[Open harness-fixes](cmux-dev-harness-fixes://launch)" />
    );
    const link = container.querySelector<HTMLAnchorElement>("a");
    expect(link).not.toBeNull();
    expect(link?.getAttribute("href")).toBe("cmux-dev-harness-fixes://launch");
  });
});

describe("every shipped copy key is reachable", () => {
  test("no key in the catalog renders nowhere", async () => {
    const root = new URL("../src/", import.meta.url).pathname;
    const files = Array.from(
      new Bun.Glob("**/*.{ts,tsx}").scanSync({ cwd: root, absolute: true })
    ).filter((path) => !path.endsWith("copyKeys.ts"));
    const source = (await Promise.all(files.map((path) => Bun.file(path).text()))).join("\n");
    const dead = (Object.keys(copyDefaults) as CopyKey[]).filter(
      (key) => !source.includes(`"${key}"`)
    );
    // Dead keys reach translators through the extract → merge pipeline and get
    // paid for in two languages while rendering in neither.
    expect(dead).toEqual([]);
  });
});

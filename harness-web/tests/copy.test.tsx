import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { copyDefaults, format, type CopyKey } from "../src/copyKeys";
import { richSession } from "../src/dev/fixtures";
import { replayLines } from "../src/model/transcript";
import type { ToolBlock, Turn } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { formatRelativeTime } from "../src/ui/format";
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

describe("counted strings inflect at one", () => {
  test("a single earlier tool call is singular", () => {
    // The CLI's summary legs now merge back into the turn they follow, so the
    // replayed fixture has no naturally one-tool turn left; trim a real one
    // down to a single tool block instead.
    const model = replayLines(richSession);
    const source = model.turns.find(
      (candidate) => candidate.blocks.some((b) => b.kind === "tool")
    );
    expect(source).toBeDefined();
    const firstTool = source!.blocks.find((b) => b.kind === "tool")!;
    const turn = { ...(source as Turn), blocks: [firstTool], folded: true } as Turn;
    const { container } = mount(<TurnView turn={turn} isLast={false} />);
    const fold = container.querySelector(".fold-count")!.textContent;
    expect(fold).toBe("1 earlier tool call");
    expect(fold).not.toBe("1 earlier tool calls");
  });

  test("two or more stays plural", () => {
    const model = replayLines(richSession);
    const turn = model.turns.find(
      (candidate) => candidate.blocks.filter((b) => b.kind === "tool").length > 1
    );
    expect(turn).toBeDefined();
    const { container } = mount(
      <TurnView turn={{ ...(turn as Turn), folded: true } as Turn} isLast={false} />
    );
    expect(container.querySelector(".fold-count")!.textContent).toMatch(/^\d+ earlier tool calls$/);
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

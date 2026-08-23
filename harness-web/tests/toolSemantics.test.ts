import { describe, expect, test } from "bun:test";
import type { JsonObject } from "../src/protocol/types";
import type { CopyFn } from "../src/ui/CopyContext";
import { toolHeadline } from "../src/ui/tools/toolMeta";
import { toolStatsSummary } from "../src/ui/tools/toolStats";

const copy: CopyFn = (key, values) => {
  const templates: Record<string, string> = {
    "supermux.harness.subagent.otherToolsOne": "{count} other tool",
    "supermux.harness.subagent.otherTools": "{count} other tools",
    "supermux.harness.tool.headline.todo": "計画を更新しました",
    "supermux.harness.tool.headline.askUser": "質問しました",
    "supermux.harness.tool.headline.enterPlan": "計画モードに入りました",
    "supermux.harness.tool.headline.presentPlan": "計画を提示しました"
  };
  const template = templates[key] ?? key;
  return Object.entries(values ?? {}).reduce(
    (text, [name, value]) => text.replaceAll(`{${name}}`, String(value)),
    template
  );
};

describe("tool summaries", () => {
  test("accounts for tools outside the recognized stat categories", () => {
    expect(toolStatsSummary({ otherToolCount: 2 }, copy)).toEqual(["2 other tools"]);
  });

  test("interactive and todo headlines resolve through localized copy", () => {
    const localizedHeadline = toolHeadline as unknown as (
      name: string,
      input: JsonObject,
      copy: CopyFn
    ) => string;

    expect(localizedHeadline("TodoWrite", {}, copy)).toBe("計画を更新しました");
    expect(localizedHeadline("AskUserQuestion", {}, copy)).toBe("質問しました");
    expect(localizedHeadline("EnterPlanMode", {}, copy)).toBe("計画モードに入りました");
    expect(localizedHeadline("ExitPlanMode", {}, copy)).toBe("計画を提示しました");
  });
});

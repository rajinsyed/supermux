import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render } from "@testing-library/react";
import { effectiveEffort, createIndex, resolveModel } from "../src/model/helpers";
import { applyLine, applyLocalAction, createModel, replayLines } from "../src/model/transcript";
import type { ToolBlock, TranscriptModel } from "../src/model/types";
import type { ModelDescriptor, ProtocolLine } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import {
  createWheelDial,
  wheelDialStep,
  WHEEL_DIAL_IDLE_MS,
  WHEEL_DIAL_THRESHOLD,
  ModelMenu
} from "../src/ui/composer/ModelMenu";
import { InteractiveBody } from "../src/ui/tools/ToolBodies";

afterEach(cleanup);

/* =========================================================================
   Item 2 — the wheel dial accumulator, as a pure function.
   ========================================================================= */

describe("round-6 item 2: the wheel dial accumulator", () => {
  test("small trackpad deltas pool without stepping", () => {
    let state = createWheelDial();
    let now = 1000;
    for (const delta of [3, 4, 2, 5]) {
      const out = wheelDialStep(state, delta, (now += 16));
      expect(out.step).toBe(0);
      state = out.state;
    }
    expect(state.accumulated).toBe(14);
  });

  test("crossing the threshold fires exactly one step and re-arms at zero", () => {
    let state = createWheelDial();
    let now = 1000;
    let steps = 0;
    // A deliberate roll: 8px per event.
    for (let i = 0; i < 20; i += 1) {
      const out = wheelDialStep(state, 8, (now += 16));
      if (out.step !== 0) {
        steps += out.step;
        expect(out.state.accumulated).toBe(0);
      }
      state = out.state;
    }
    // 160px of roll at a 60px threshold: two steps, not twenty.
    expect(steps).toBe(Math.floor(160 / WHEEL_DIAL_THRESHOLD));
  });

  test("a discrete mouse-wheel notch still steps once", () => {
    const up = wheelDialStep(createWheelDial(), 120, 1000);
    expect(up.step).toBe(1);
    const down = wheelDialStep(createWheelDial(), -120, 1000);
    expect(down.step).toBe(-1);
  });

  test("deltaY>0 steps UP — the natural-scrolling direction the user asked for", () => {
    expect(wheelDialStep(createWheelDial(), WHEEL_DIAL_THRESHOLD, 0).step).toBe(1);
    expect(wheelDialStep(createWheelDial(), -WHEEL_DIAL_THRESHOLD, 0).step).toBe(-1);
  });

  test("a direction change resets the pool instead of cancelling against it", () => {
    let state = createWheelDial();
    let out = wheelDialStep(state, 40, 1000);
    expect(out.step).toBe(0);
    // Reversing: the 40 up-pixels must not subsidise the down gesture — a
    // fresh 40 down is still below the threshold.
    out = wheelDialStep(out.state, -40, 1016);
    expect(out.step).toBe(0);
    expect(out.state.accumulated).toBe(-40);
    // …and 20 more completes the DOWN gesture on its own accumulation.
    out = wheelDialStep(out.state, -20, 1032);
    expect(out.step).toBe(-1);
  });

  test("a pause re-arms the pool so drift cannot carry across gestures", () => {
    let out = wheelDialStep(createWheelDial(), 50, 1000);
    expect(out.step).toBe(0);
    // Idle longer than the window: the 50 pooled pixels are history.
    out = wheelDialStep(out.state, 30, 1000 + WHEEL_DIAL_IDLE_MS + 50);
    expect(out.step).toBe(0);
    expect(out.state.accumulated).toBe(30);
  });
});

/* =========================================================================
   Item 5 — the EFFECTIVE effort is always shown when the model supports it.
   ========================================================================= */

const EFFORT_MODEL: ModelDescriptor = {
  value: "sonnet",
  resolvedModel: "claude-sonnet-5",
  displayName: "Sonnet",
  supportsEffort: true,
  supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"],
  defaultEffortLevel: "high"
};

// The LIVE catalog's shape: supportsEffort with NO defaultEffortLevel — the
// settings default is the only thing that can answer.
const LIVE_SHAPE: ModelDescriptor = {
  value: "gpt-5.6-sol",
  resolvedModel: "gpt-5.6-sol",
  displayName: "GPT 5.6 Sol",
  supportsEffort: true,
  supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]
};

describe("round-6 item 5: effectiveEffort", () => {
  test("an explicit pick wins", () => {
    expect(effectiveEffort(EFFORT_MODEL, "low", "xhigh")).toBe("low");
  });

  test("no pick falls to the settings default, then the catalog default", () => {
    expect(effectiveEffort(EFFORT_MODEL, undefined, "xhigh")).toBe("xhigh");
    expect(effectiveEffort(EFFORT_MODEL, undefined, undefined)).toBe("high");
    expect(effectiveEffort(LIVE_SHAPE, undefined, "xhigh")).toBe("xhigh");
  });

  test("a model without effort support answers nothing", () => {
    expect(effectiveEffort({ value: "haiku", displayName: "Haiku" }, "high", "high")).toBeUndefined();
    expect(effectiveEffort(undefined, "high", "high")).toBeUndefined();
  });

  test("an unsupported explicit level falls through instead of leaking", () => {
    const threeLevels: ModelDescriptor = {
      ...EFFORT_MODEL,
      supportedEffortLevels: ["low", "medium", "high"]
    };
    expect(effectiveEffort(threeLevels, "max", undefined)).toBe("high");
  });
});

function mountMenu(
  session: Parameters<typeof ModelMenu>[0]["session"],
  cachedModels?: ModelDescriptor[]
) {
  return render(
    <CopyProvider dict={undefined}>
      <ModelMenu session={session} cachedModels={cachedModels} onSetModel={() => {}} />
    </CopyProvider>
  );
}

describe("round-6 item 5: the trigger and strip always show a level", () => {
  test("a fresh session with NO explicit effort still shows the effective level", () => {
    // The exact report: "by default no reasoning effort is selected. which is
    // not possible" — the CLI is running at its settings default.
    const { container } = mountMenu(
      { model: undefined, models: [], effort: undefined, defaultEffort: "xhigh" },
      [LIVE_SHAPE, { value: "default", resolvedModel: "gpt-5.6-sol", displayName: "Default (recommended)", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"] }]
    );
    expect(container.querySelector(".composer-model-effort")!.textContent).toBe("Extra high");
  });

  test("the strip's pressed step is the effective level, not nothing", () => {
    const { container } = mountMenu(
      { model: "sonnet", models: [EFFORT_MODEL], effort: undefined, defaultEffort: undefined }
    );
    fireEvent.click(container.querySelector(".composer-model-trigger")!);
    const active = container.querySelector(".effort-step.is-active");
    expect(active).not.toBeNull();
    expect(active!.getAttribute("aria-pressed")).toBe("true");
    expect(active!.textContent).toContain("High");
  });

  test("after a model switch the strip still marks a level on the new model", () => {
    const { container } = mountMenu({
      model: "gpt-5.6-sol",
      models: [LIVE_SHAPE],
      effort: undefined,
      defaultEffort: "medium"
    });
    fireEvent.click(container.querySelector(".composer-model-trigger")!);
    expect(container.querySelector(".effort-step.is-active")!.textContent).toContain("Medium");
  });
});

/* =========================================================================
   Item 5 resume path — the disk records' own "effort" stamp is adopted.
   ========================================================================= */

let seq = 0;
const uid = (p: string) => `${p}-${(seq += 1).toString(16)}`;

function diskAssistant(
  model: string,
  effort: string | undefined,
  content: unknown[]
): ProtocolLine {
  return {
    type: "assistant",
    message: { id: uid("m"), model, role: "assistant", content },
    parent_tool_use_id: null,
    session_id: "resumed",
    uuid: uid("a"),
    timestamp: "2026-08-19T04:16:08.156Z",
    effort
  } as ProtocolLine;
}

function diskUserText(text: string): ProtocolLine {
  return {
    type: "user",
    message: { role: "user", content: text },
    parent_tool_use_id: null,
    session_id: "resumed",
    uuid: uid("u"),
    timestamp: "2026-08-19T04:15:00.000Z"
  } as ProtocolLine;
}

describe("round-6 item 5: a resumed session shows the effort it actually ran at", () => {
  test("historyReplayed adopts the records' effort stamp with the model", () => {
    const index = createIndex();
    let model = createModel();
    for (const line of [
      diskUserText("earlier prompt"),
      diskAssistant("gpt-5.6-sol", "xhigh", [{ type: "text", text: "earlier answer" }])
    ]) {
      model = applyLine(model, index, line, 1000);
    }
    model = applyLocalAction(model, index, { kind: "historyReplayed" }, 2000);
    expect(model.session.model).toBe("gpt-5.6-sol");
    expect(model.session.effort).toBe("xhigh");
  });

  test("subagent frames' models and efforts are not the session's", () => {
    const index = createIndex();
    let model = createModel();
    const line = {
      ...diskAssistant("claude-haiku-4-5", "low", [{ type: "text", text: "agent text" }]),
      parent_tool_use_id: "toolu_agent"
    } as ProtocolLine;
    model = applyLine(model, index, line, 1000);
    expect(model.lastAssistantEffort).toBeUndefined();
    expect(model.lastAssistantModel).toBeUndefined();
  });
});

/* =========================================================================
   Item 12 — the settings default names the REAL model before the first send.
   ========================================================================= */

describe("round-6 item 12: the CLI's settings default model", () => {
  const catalog: ModelDescriptor[] = [
    { value: "default", resolvedModel: "claude-opus-5[1m]", displayName: "Default (recommended)" },
    { value: "gpt-5.6-sol", resolvedModel: "gpt-5.6-sol", displayName: "GPT 5.6 Sol" },
    { value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet" }
  ];

  function withDefaults(model?: string, effort?: "low" | "medium" | "high" | "xhigh" | "max") {
    const index = createIndex();
    let m = createModel();
    m = applyLocalAction(m, index, { kind: "cachedModels", models: catalog }, 0);
    m = applyLocalAction(m, index, { kind: "sessionDefaults", model, effort }, 0);
    return { index, model: m };
  }

  test("a fresh pane resolves the settings model, not 'Default (recommended)'", () => {
    // The user's ~/.claude/settings.json carries "model": "gpt-5.6-sol"; the
    // flagless process WILL run it, so the trigger names it immediately.
    const { model } = withDefaults("gpt-5.6-sol", "xhigh");
    expect(resolveModel(model.session, model.cachedModels)?.displayName).toBe("GPT 5.6 Sol");
  });

  test("every stronger source outranks it", () => {
    const { index, model } = withDefaults("gpt-5.6-sol");
    // A user pick:
    const picked = applyLocalAction(model, index, { kind: "setModel", model: "sonnet" }, 0);
    expect(resolveModel(picked.session, picked.cachedModels)?.displayName).toBe("Sonnet");
    // An init frame:
    const init = applyLine(
      model,
      index,
      { type: "system", subtype: "init", model: "claude-sonnet-5", uuid: uid("i") } as ProtocolLine,
      0
    );
    expect(resolveModel(init.session, init.cachedModels)?.displayName).toBe("Sonnet");
  });

  test("a settings model the catalog cannot resolve falls back to the default row", () => {
    const { model } = withDefaults("claude-opus-4-6-retired");
    expect(resolveModel(model.session, model.cachedModels)?.displayName).toBe(
      "Default (recommended)"
    );
  });

  test("sessionDefaults survives a reset — it describes the binary, not the conversation", () => {
    const { index, model } = withDefaults("gpt-5.6-sol", "xhigh");
    const reset = applyLocalAction(model, index, { kind: "reset" }, 0);
    expect(reset.session.defaultModel).toBe("gpt-5.6-sol");
    expect(reset.session.defaultEffort).toBe("xhigh");
  });
});

/* =========================================================================
   Item 14 — a settled AskUserQuestion shows the picked answers, both paths.
   ========================================================================= */

const QUESTIONS = [
  {
    question: "What would you most like help with today?",
    header: "Goal",
    multiSelect: false,
    options: [{ label: "Build a feature" }, { label: "Fix a bug" }]
  },
  {
    question: "How would you like me to approach the work?",
    header: "Approach",
    multiSelect: false,
    options: [{ label: "Implement directly" }, { label: "Plan first" }]
  },
  {
    question: "Which qualities matter most for the result?",
    header: "Priorities",
    multiSelect: true,
    options: [{ label: "Correctness" }, { label: "Visual polish" }]
  }
];

const ANSWERS = {
  "What would you most like help with today?": "Build a feature",
  "How would you like me to approach the work?": "Plan first",
  "Which qualities matter most for the result?": "Visual polish"
};

const QUESTION_TOOL_ID = "call_54Qb2CW0iaKkwi4RCMNqJ01l";

/** The real 22a3 session's shapes: assistant tool_use, then the settling
 *  user tool_result whose disk record carries `toolUseResult.answers`. */
function realQuestionRecords(): ProtocolLine[] {
  return [
    diskUserText("hi"),
    diskAssistant("gpt-5.6-sol", "xhigh", [
      { type: "tool_use", id: QUESTION_TOOL_ID, name: "AskUserQuestion", input: { questions: QUESTIONS } }
    ]),
    {
      type: "user",
      message: {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: QUESTION_TOOL_ID,
            content:
              'Your questions have been answered: "What would you most like help with today?"="Build a feature"…'
          }
        ]
      },
      parent_tool_use_id: null,
      session_id: "resumed",
      uuid: uid("tr"),
      timestamp: "2026-08-19T04:18:19.377Z",
      tool_use_result: { questions: QUESTIONS, answers: ANSWERS }
    } as ProtocolLine
  ];
}

function findQuestionBlock(model: TranscriptModel): ToolBlock {
  for (const turn of model.turns) {
    for (const block of turn.blocks) {
      if (block.kind === "tool" && block.name === "AskUserQuestion") return block;
    }
  }
  throw new Error("no AskUserQuestion block");
}

function renderedAnswers(block: ToolBlock): string[] {
  const { container } = render(
    <CopyProvider dict={undefined}>
      <InteractiveBody block={block} />
    </CopyProvider>
  );
  return Array.from(container.querySelectorAll(".qa-answer")).map((n) => n.textContent ?? "");
}

describe("round-6 item 14: settled question cards show the picked answers", () => {
  test("REPLAY: the real disk record shapes render every answer, no em-dashes", () => {
    const model = replayLines(realQuestionRecords());
    const block = findQuestionBlock(model);
    const answers = renderedAnswers(block);
    expect(answers).toEqual(["Build a feature", "Plan first", "Visual polish"]);
    expect(answers).not.toContain("—");
  });

  test("LIVE: submitting merges the answers into the STREAMED block immediately", () => {
    // The current CLI streams an assistant tool_use for AskUserQuestion before
    // raising can_use_tool; the old reducer skipped recording entirely when a
    // block was already on screen, so the card showed "—" until (and unless)
    // the CLI echoed the answers back.
    const index = createIndex();
    let model = createModel();
    model = applyLine(
      model,
      index,
      diskAssistant("gpt-5.6-sol", "xhigh", [
        { type: "tool_use", id: QUESTION_TOOL_ID, name: "AskUserQuestion", input: { questions: QUESTIONS } }
      ]),
      1000
    );
    model = applyLine(
      model,
      index,
      {
        type: "control_request",
        request_id: "req-q1",
        request: {
          subtype: "can_use_tool",
          tool_name: "AskUserQuestion",
          input: { questions: QUESTIONS },
          tool_use_id: QUESTION_TOOL_ID
        }
      } as ProtocolLine,
      1001
    );
    expect(model.pending).toHaveLength(1);

    model = applyLocalAction(
      model,
      index,
      {
        kind: "permissionResolved",
        requestId: "req-q1",
        behavior: "allow",
        updatedInput: { questions: QUESTIONS, answers: ANSWERS } as never
      },
      1002
    );

    const block = findQuestionBlock(model);
    expect(block.input.answers).toEqual(ANSWERS as never);
    expect(renderedAnswers(block)).toEqual(["Build a feature", "Plan first", "Visual polish"]);
  });

  test("LIVE: the CLI's later tool_result does not erase the merged answers", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLine(
      model,
      index,
      diskAssistant("gpt-5.6-sol", "xhigh", [
        { type: "tool_use", id: QUESTION_TOOL_ID, name: "AskUserQuestion", input: { questions: QUESTIONS } }
      ]),
      1000
    );
    model = applyLine(
      model,
      index,
      {
        type: "control_request",
        request_id: "req-q1",
        request: {
          subtype: "can_use_tool",
          tool_name: "AskUserQuestion",
          input: { questions: QUESTIONS },
          tool_use_id: QUESTION_TOOL_ID
        }
      } as ProtocolLine,
      1001
    );
    model = applyLocalAction(
      model,
      index,
      {
        kind: "permissionResolved",
        requestId: "req-q1",
        behavior: "allow",
        updatedInput: { questions: QUESTIONS, answers: ANSWERS } as never
      },
      1002
    );
    // The wire's own settling frame arrives a beat later.
    model = applyLine(model, index, realQuestionRecords()[2], 1003);
    const block = findQuestionBlock(model);
    expect(renderedAnswers(block)).toEqual(["Build a feature", "Plan first", "Visual polish"]);
    expect(block.status).toBe("success");
  });

  test("a DENIED question with a streamed block records no fabricated answers", () => {
    const index = createIndex();
    let model = createModel();
    model = applyLine(
      model,
      index,
      diskAssistant("gpt-5.6-sol", "xhigh", [
        { type: "tool_use", id: QUESTION_TOOL_ID, name: "AskUserQuestion", input: { questions: QUESTIONS } }
      ]),
      1000
    );
    model = applyLine(
      model,
      index,
      {
        type: "control_request",
        request_id: "req-q1",
        request: {
          subtype: "can_use_tool",
          tool_name: "AskUserQuestion",
          input: { questions: QUESTIONS },
          tool_use_id: QUESTION_TOOL_ID
        }
      } as ProtocolLine,
      1001
    );
    model = applyLocalAction(
      model,
      index,
      { kind: "permissionResolved", requestId: "req-q1", behavior: "deny" },
      1002
    );
    const block = findQuestionBlock(model);
    expect(block.input.answers).toBeUndefined();
  });

  test("plan approvals still render their plan from the streamed input", () => {
    // The neighbouring interactive tool, checked while in here: ExitPlanMode's
    // body reads input.plan, which the streamed block carries throughout.
    const index = createIndex();
    let model = createModel();
    model = applyLine(
      model,
      index,
      diskAssistant("gpt-5.6-sol", "xhigh", [
        { type: "tool_use", id: "toolu_plan1", name: "ExitPlanMode", input: { plan: "## The plan\n1. Do it" } }
      ]),
      1000
    );
    model = applyLine(
      model,
      index,
      {
        type: "user",
        message: {
          role: "user",
          content: [{ type: "tool_result", tool_use_id: "toolu_plan1", content: "approved" }]
        },
        parent_tool_use_id: null,
        uuid: uid("tr"),
        timestamp: "2026-08-19T04:20:00.000Z"
      } as ProtocolLine,
      1001
    );
    let plan: ToolBlock | undefined;
    for (const turn of model.turns) {
      for (const block of turn.blocks) {
        if (block.kind === "tool" && block.name === "ExitPlanMode") plan = block;
      }
    }
    const { container } = render(
      <CopyProvider dict={undefined}>
        <InteractiveBody block={plan!} />
      </CopyProvider>
    );
    expect(container.textContent).toContain("The plan");
  });
});

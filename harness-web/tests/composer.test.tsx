import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, createEvent, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { fixtures, richSession } from "../src/dev/fixtures";
import { activeModelFor, emptySession } from "../src/model/helpers";
import { replayLines } from "../src/model/transcript";
import type { PickedImageAttachments } from "../src/model/attachments";
import type { ImageAttachment, SessionMeta } from "../src/model/types";
import type { EffortLevel, SlashCommandDescriptor } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Composer } from "../src/ui/composer/Composer";
import { modelMenuSource } from "../src/ui/composer/ModelMenu";

afterEach(cleanup);

const COMMANDS: SlashCommandDescriptor[] = [
  { name: "compact", description: "Summarize the conversation" },
  { name: "context", description: "Show context usage" },
  { name: "clear", description: "Clear the conversation" }
];

interface Harness {
  draft(): string;
  sent: string[];
  rerender(next: string): void;
}

function mount(options: { disabled?: boolean; restarting?: boolean } = {}): Harness {
  const sent: string[] = [];
  let draft = "";
  const view = (text: string) => (
    <CopyProvider dict={undefined}>
      <Composer
        disabled={options.disabled ?? false}
        restarting={options.restarting}
        running={false}
        awaitingPermission={false}
        planPending={false}
        onPlanImplement={() => {}}
        onPlanRefine={() => {}}
        onPlanKeepPlanning={() => {}}
        queued={[]}
        commands={COMMANDS}
        permissionMode="default"
        draft={text}
        onDraftChange={(next) => {
          draft = next;
          rendered.rerender(view(next));
        }}
        onSend={(text) => sent.push(text)}
        onInterrupt={() => {}}
        onCancelQueued={() => {}}
        onCyclePermissionMode={() => {}}
        fetchFileSuggestions={async () => ["src/ui/App.tsx"]}
        onPickFiles={async () => ({ images: [] })}
      />
    </CopyProvider>
  );
  const rendered = render(view(""));
  return {
    draft: () => draft,
    sent,
    rerender: (next: string) => {
      draft = next;
      rendered.rerender(view(next));
    }
  };
}

/** Typing goes through the real change handler so the caret tracks like a browser's. */
function type(text: string): void {
  const input = screen.getByRole("textbox") as HTMLTextAreaElement;
  act(() => {
    fireEvent.change(input, { target: { value: text, selectionStart: text.length } });
  });
}

/**
 * The textarea's own value matches the popover row's text, so every lookup is
 * scoped to the listbox — otherwise the query resolves to the draft.
 */
async function popoverRow(label: string): Promise<HTMLElement> {
  const list = await screen.findByRole("listbox");
  const row = Array.from(list.querySelectorAll<HTMLElement>(".ui-cmd-label")).find(
    (node) => node.textContent === label
  );
  if (!row) throw new Error(`no popover row for ${label}`);
  return row;
}

async function settlePopoverCompletion(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 20));
  });
}

describe("slash-command popover completes a real command", () => {
  test("accepting with Enter keeps the leading slash", async () => {
    const harness = mount();
    type("/co");
    await popoverRow("/compact");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await settlePopoverCompletion();

    // Without the sigil the CLI reads "compact " as prose and the model answers
    // it, instead of running the slash command.
    expect(harness.draft()).toBe("/compact ");
    expect(harness.draft().startsWith("/")).toBe(true);
  });

  test("accepting by clicking a row keeps it too", async () => {
    const harness = mount();
    type("/compact");
    const row = await popoverRow("/compact");

    fireEvent.mouseDown(row);
    await settlePopoverCompletion();

    expect(harness.draft()).toBe("/compact ");
  });

  test("the completed command is what gets sent", async () => {
    const harness = mount();
    type("/context");
    await popoverRow("/context");
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    // The completion repositions the caret in a rAF; let it land so the popover
    // is genuinely closed and the next Enter submits rather than re-completing.
    await settlePopoverCompletion();
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(harness.sent).toEqual(["/context"]);
  });

  test("a mention still carries its own sigil", async () => {
    const harness = mount();
    type("look at @App");
    await popoverRow("src/ui/App.tsx");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    await settlePopoverCompletion();

    expect(harness.draft()).toBe("look at @src/ui/App.tsx ");
  });

  test("a trigger with no matches says so instead of vanishing", async () => {
    mount();
    type("/zzzz");
    expect(await screen.findByText("No matching commands")).toBeDefined();
  });
});

describe("composer with no CLI", () => {
  test("the placeholder points at the fix rather than inviting a message", () => {
    mount({ disabled: true });
    const input = screen.getByRole("textbox") as HTMLTextAreaElement;
    expect(input.placeholder).toBe("Install the Claude Code CLI to start");
    expect(input.disabled).toBe(true);
  });
});

/**
 * A restart and a missing CLI both disable the composer, and the placeholder is
 * the only thing that says which. Reading it off `disabled` alone told a user
 * mid-restart — every New Session, every session resume, every rewind — to
 * "Install the Claude Code CLI", advice about software they were plainly already
 * running, on a pane that was about to work again by itself in a second.
 */
describe("composer during a restart", () => {
  test("it names the restart rather than telling the user to install a CLI they have", () => {
    mount({ disabled: true, restarting: true });
    const input = screen.getByRole("textbox") as HTMLTextAreaElement;
    expect(input.placeholder).toBe("Restarting Claude…");
    expect(input.placeholder).not.toBe("Install the Claude Code CLI to start");
    // Still refused: a send during the teardown reaches a dying process.
    expect(input.disabled).toBe(true);
  });

  test("a genuinely missing CLI still gets the install copy", () => {
    // The restart is the SPECIAL case; the general one must not be swallowed by
    // it, or the fix trades one wrong string for another.
    mount({ disabled: true, restarting: false });
    expect((screen.getByRole("textbox") as HTMLTextAreaElement).placeholder).toBe(
      "Install the Claude Code CLI to start"
    );
  });
});

/* ---------------------------------------------------------------------------
   The model picker.

   It lives in the composer pill now — Cursor's grammar, and the honest one: the
   model is a property of the message about to be sent. These cases came WITH it
   from tests/header.test.tsx, because the bugs they pin are properties of the
   picker (resolving a selector against the right catalog, never opening onto an
   empty popup) and not of whichever chrome hosts it.
--------------------------------------------------------------------------- */

function mountPicker(
  session: Pick<SessionMeta, "model" | "models" | "effort">,
  extra: {
    cachedModels?: SessionMeta["models"];
    onSetModel?(model: string, effort?: EffortLevel): void;
  } = {}
) {
  return render(
    <CopyProvider dict={undefined}>
      <Composer
        disabled={false}
        running={false}
        awaitingPermission={false}
        planPending={false}
        onPlanImplement={() => {}}
        onPlanRefine={() => {}}
        onPlanKeepPlanning={() => {}}
        queued={[]}
        commands={[]}
        permissionMode="default"
        draft=""
        onDraftChange={() => {}}
        onSend={() => {}}
        onInterrupt={() => {}}
        onCancelQueued={() => {}}
        onCyclePermissionMode={() => {}}
        fetchFileSuggestions={async () => []}
        onPickFiles={async () => ({ images: [] })}
        session={session}
        cachedModels={extra.cachedModels}
        onSetModel={extra.onSetModel ?? (() => {})}
      />
    </CopyProvider>
  );
}

/**
 * The real CLI reports the RESOLVED id in `system/init` ("claude-sonnet-5") while
 * the `initialize` catalog is keyed by short SELECTOR ("sonnet"). The two
 * namespaces never overlap, so a lookup on `value` alone leaves the trigger
 * printing a raw id, no menu row checked, and the reasoning flyout unreachable.
 */
function realSession(): SessionMeta {
  return replayLines(richSession).session;
}

function openPicker(): void {
  fireEvent.click(screen.getByLabelText("Model"));
}

function triggerLabel(container: HTMLElement): string {
  return container.querySelector(".composer-model-label")!.textContent!;
}

describe("the model trigger sits in the pill and names the live model", () => {
  test("it prints the display name, not the raw id", () => {
    const { container } = mountPicker(realSession());
    expect(triggerLabel(container)).toBe("Sonnet");
    expect(triggerLabel(container)).not.toContain("claude-");
  });

  test("effort is part of the label, not a chip beside it", () => {
    // "Claude Opus 5 Extra High" is ONE setting with one name; the old pill
    // drew the level in its own bed and read as a second control.
    const { container } = mountPicker({ ...realSession(), effort: "xhigh" });
    expect(container.querySelector(".composer-model-effort")!.textContent).toBe("Extra high");
    expect(container.querySelector(".effort-tag")).toBeNull();
  });

  test("an unknown model still prints something rather than blanking the trigger", () => {
    const { container } = mountPicker({ ...emptySession(), model: "some-future-model" });
    expect(triggerLabel(container)).toBe("some-future-model");
  });

  test("no scenario ever prints a raw model id in the trigger", () => {
    // Every scenario, not only the two real traces: a fixture that ships a model
    // the catalog cannot resolve puts a raw id in the composer of that scenario.
    const raw: string[] = [];
    for (const [name, lines] of Object.entries(fixtures)) {
      const session = replayLines(lines as never).session;
      if (!session.model || session.models.length === 0) continue;
      const shown = activeModelFor(session)?.displayName ?? session.model;
      if (/^(claude|gpt)-/.test(shown)) raw.push(`${name}=${shown}`);
    }
    expect(raw).toEqual([]);
  });

  test("a composer with no session shows no picker at all", () => {
    // The agent-view harness and the tests above mount a Composer with nothing
    // to pick a model for; a trigger there would be a control over nothing.
    mount();
    expect(screen.queryByLabelText("Model")).toBeNull();
  });
});

/**
 * The panel is ONE surface: rows, and nothing else.
 *
 * It used to open with a search field over a scrolling list, plus a floating
 * side flyout hinged on whichever row the pointer was over — measured per row,
 * flipped when the popover was against the pane edge, lifted when its foot ran
 * off the bottom. Three positioned layers to change one enum, over a list of
 * four models that fits on screen. The filter is gone and reasoning is an
 * inline strip under its own row.
 */
describe("the picker's panel is a list, not a search UI", () => {
  test("no search field, so the first keystroke is not ambiguous", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    expect(screen.queryByLabelText("Search models")).toBeNull();
    expect(container.querySelector(".ui-menu-input")).toBeNull();
  });

  test("the CHECKED row takes focus, so ↑↓ start from the live model", () => {
    // Without a focused row the keystroke falls through to the composer behind
    // the panel; focusing the FIRST row instead would ring a model the user is
    // not on.
    const { container } = mountPicker(realSession());
    openPicker();
    expect(document.activeElement).toBe(
      container.querySelector('[role="menuitemradio"][aria-checked="true"]')
    );
    expect(document.activeElement!.textContent).toContain("Sonnet");
  });

  test("every catalog row is rendered — there is nothing to filter down to", () => {
    const session = realSession();
    const { container } = mountPicker(session);
    openPicker();
    expect(container.querySelectorAll('[role="menuitemradio"]').length).toBe(
      session.models.length
    );
  });

  test("exactly one row is checked", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    const checked = container.querySelectorAll('[role="menuitemradio"][aria-checked="true"]');
    expect(checked.length).toBe(1);
    expect(checked[0].textContent).toContain("Sonnet");
  });

  test("a row shows the display name only — no description line", () => {
    // Cursor's list is one name per row. The descriptions the catalog ships
    // ("Opus 5 with a 1M context window") doubled every row's height.
    const { container } = mountPicker(realSession());
    openPicker();
    expect(container.querySelector(".model-row .ui-menu-detail")).toBeNull();
  });

  test("picking a row sends the catalog selector, never the resolved id", () => {
    const sent: Array<[string, string | undefined]> = [];
    mountPicker(realSession(), { onSetModel: (model, effort) => sent.push([model, effort]) });
    openPicker();
    fireEvent.click(screen.getByRole("menuitemradio", { name: /^Haiku/ }));
    expect(sent).toEqual([["haiku", undefined]]);
  });
});

/**
 * Reasoning: ONE strip, pinned at the panel's foot, for the ACTIVE model.
 *
 * Round 4 opened a strip under whichever row the pointer last touched, so the
 * panel's height jumped as the reader moved down the list, and it asked "which
 * model" and "how hard" in two places on one surface. It also left the wheel and
 * Option+,/. with no stable target to move. Effort belongs to the selection, so
 * it sits once, under a hairline, always in the same place.
 */
function steps(container: HTMLElement): string[] {
  return Array.from(container.querySelectorAll(".effort-step")).map(
    (node) => node.textContent ?? ""
  );
}

describe("reasoning is one strip, for the model that is live", () => {
  test("it is there the moment the panel opens, without hunting for a row", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    expect(container.querySelectorAll(".effort-scale").length).toBe(1);
  });

  test("the strip lists every level the LIVE model supports, as labels", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    // sonnet advertises all five levels in the live initialize response.
    const levels = steps(container);
    expect(levels.length).toBe(5);
    // `xhigh` is a wire token no user would write.
    expect(levels.some((level) => level.startsWith("Extra high"))).toBe(true);
    expect(levels.some((level) => level.includes("xhigh"))).toBe(false);
    for (const level of levels) expect(level).toMatch(/^[A-Z]/);
  });

  test("a model with no effort levels grows no strip at all", () => {
    // haiku advertises none; a Reasoning affordance there promises a setting
    // the CLI rejects.
    const session = realSession();
    const { container } = mountPicker({ ...session, model: "haiku" });
    openPicker();
    expect(container.querySelector(".effort-scale")).toBeNull();
  });

  test("the steps are not part of the model radio group", () => {
    // The panel's arrow keys walk `menuitemradio`. Five effort steps folded into
    // that list would make ↓ from the last model land on "Low" rather than
    // wrapping to the first model — the levels are a property of the selection,
    // not five more things to select between.
    const session = realSession();
    const { container } = mountPicker(session);
    openPicker();
    expect(container.querySelectorAll('[role="menuitemradio"]').length).toBe(
      session.models.length
    );
  });

  test("the live level is the pressed step", () => {
    const { container } = mountPicker({ ...realSession(), effort: "xhigh" });
    openPicker();
    const active = container.querySelector(".effort-step.is-active")!;
    expect(active.textContent).toContain("Extra high");
    expect(active.getAttribute("aria-pressed")).toBe("true");
  });

  test("an effort pick sends the catalog selector with the level", () => {
    const sent: Array<[string, string | undefined]> = [];
    mountPicker(realSession(), { onSetModel: (model, effort) => sent.push([model, effort]) });
    openPicker();
    fireEvent.click(screen.getByText("High"));
    expect(sent).toEqual([["sonnet", "high"]]);
  });

  test("Restore defaults sends the model's own default level", () => {
    const sent: Array<[string, string | undefined]> = [];
    const session = realSession();
    const sonnet = session.models.find((m) => m.value === "sonnet")!;
    // Only offered when the live level is NOT already the default; the fixture's
    // session carries no effort, so set one that differs.
    mountPicker(
      { ...session, effort: sonnet.defaultEffortLevel === "high" ? "low" : "high" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    openPicker();
    fireEvent.click(screen.getByText("Restore defaults"));
    expect(sent).toEqual([["sonnet", sonnet.defaultEffortLevel]]);
  });
});

/**
 * The catalog reaches a pane only through the `initialize` handshake of a
 * RUNNING process, so before the first send `session.models` is empty — and the
 * model menu opened onto nothing at all.
 */
describe("the model menu is never an empty popup", () => {
  const cached = replayLines(richSession).session.models;

  test("the live catalog wins when a process is running", () => {
    const live = realSession();
    const source = modelMenuSource(live, [{ value: "stale", displayName: "Stale" }]);
    expect(source.models).toBe(live.models);
    expect(source.loading).toBe(false);
  });

  test("a cached catalog fills the menu before any process has started", () => {
    const source = modelMenuSource({ models: [] }, cached);
    expect(source.models).toBe(cached);
    expect(source.loading).toBe(false);
  });

  test("with neither source it reports loading rather than empty", () => {
    expect(modelMenuSource({ models: [] }, undefined)).toEqual({ models: [], loading: true });
    expect(modelMenuSource({ models: [] }, [])).toEqual({ models: [], loading: true });
  });

  test("with nothing yet it shows a spinner row instead of a void", () => {
    // A menu that opens on nothing reads as broken; before the first start the
    // catalog is genuinely still on its way, and saying so is the difference.
    const { container } = mountPicker(emptySession());
    openPicker();
    const loading = container.querySelector(".ui-menu-empty.is-loading");
    expect(loading).not.toBeNull();
    expect(loading!.textContent).toContain("Loading models…");
    // `.orbit` since round 6 — a catalog fetch is one request in flight, which
    // is the orbit's whole meaning in the round-6 loading family.
    expect(container.querySelector(".orbit")).not.toBeNull();
  });

  test("a first-open pane renders rows from the cache, not a blank menu", () => {
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    const { container } = mountPicker(cold, { cachedModels: cached });
    openPicker();
    expect(container.querySelectorAll('[role="menuitemradio"]').length).toBe(cached.length);
    expect(container.querySelector(".ui-menu-empty.is-loading")).toBeNull();
  });

  test("the cached rows resolve the active model the same way the live ones do", () => {
    // The catalog is keyed by selector and init reports the resolved id, so a
    // cache that failed to resolve would leave every row unchecked.
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    const { container } = mountPicker(cold, { cachedModels: cached });
    openPicker();
    const checked = container.querySelectorAll('[role="menuitemradio"][aria-checked="true"]');
    expect(checked.length).toBe(1);
    expect(checked[0].textContent).toContain("Sonnet");
  });

  test("a pre-start pick reports the catalog selector, ready for the first start", () => {
    const sent: Array<[string, string | undefined]> = [];
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    mountPicker(cold, {
      cachedModels: cached,
      onSetModel: (model, effort) => sent.push([model, effort])
    });
    openPicker();
    fireEvent.click(screen.getByRole("menuitemradio", { name: /^Haiku/ }));
    // The selector, not the resolved id: it is what `set_model` and the first
    // start's `model` parameter both take.
    expect(sent).toEqual([["haiku", undefined]]);
  });
});

/**
 * A model picked before the first start is held in the reducer as the SELECTOR
 * the menu sends on the wire ("opus"), and `session.models` is still empty
 * because no process has run its `initialize` handshake. The trigger resolved
 * only against that empty catalog, so it printed the bare selector — beside a
 * menu whose "Opus 5" row was correctly checked from the cache. Two controls,
 * one selection, two different names for it.
 */
describe("a pre-start selection reads as a name, not a wire token", () => {
  const cached = replayLines(richSession).session.models;
  // The selector as the MENU sends it, straight from the real trace: this is
  // literally the string the trigger was printing.
  const cold = () => ({ ...emptySession(), model: "opus[1m]" });

  test("the trigger prints the display name from the cached catalog", () => {
    const { container } = mountPicker(cold(), { cachedModels: cached });
    expect(triggerLabel(container)).toBe("Opus (1M context)");
    expect(triggerLabel(container)).not.toBe("opus[1m]");
  });

  test("the effort word comes with it, clamped to what that model supports", () => {
    // It is gated on the resolved model's capabilities, so a trigger that failed
    // to resolve could not show one at all — the selection looked like it had
    // lost its effort level as well as its name.
    const { container } = mountPicker({ ...cold(), effort: "xhigh" }, { cachedModels: cached });
    expect(container.querySelector(".composer-model-effort")!.textContent).toBe("Extra high");
  });

  test("an effort level the picked model does not support shows no word", () => {
    const { container } = mountPicker(
      { ...emptySession(), model: "haiku", effort: "high" },
      { cachedModels: cached }
    );
    expect(container.querySelector(".composer-model-effort")).toBeNull();
  });

  test("the trigger and the checked row name the same model", () => {
    // The disagreement is the bug: one resolution now feeds both.
    const { container } = mountPicker(cold(), { cachedModels: cached });
    openPicker();
    const checked = container.querySelectorAll('[role="menuitemradio"][aria-checked="true"]');
    expect(checked.length).toBe(1);
    expect(checked[0].textContent).toContain(triggerLabel(container));
  });

  test("the reasoning strip is reachable on a pre-start selection", () => {
    // It is gated on the RESOLVED row, so a trigger that failed to resolve
    // against the cached catalog left the setting unreachable entirely.
    const { container } = mountPicker(cold(), { cachedModels: cached });
    openPicker();
    // The strip resolves against the RESOLVED row: a trigger that failed to
    // resolve against the cached catalog left the setting unreachable entirely.
    const open = container.querySelector(".effort-scale");
    expect(open).not.toBeNull();
    expect(container.querySelector(".composer-model-label")!.textContent).toContain(
      "Opus (1M context)"
    );
  });

  test("with no catalog at all the selector is still shown rather than nothing", () => {
    // Falling back to the raw value is correct when there is genuinely nothing
    // to resolve against; the bug was doing it while a catalog was right there.
    const { container } = mountPicker(cold());
    expect(triggerLabel(container)).toBe("opus[1m]");
  });
});

/**
 * The two gestures that change reasoning WITHOUT opening the panel.
 *
 * Both go through the same `onSetModel` the menu rows use — one mutation path,
 * so the trigger label, the checked step and the CLI can never disagree about
 * what was sent — and both step along the ACTIVE model's own scale, clamped at
 * its ends.
 */
describe("reasoning has two gestures beside the menu", () => {
  const stepped = (): { sent: Array<[string, string | undefined]>; session: SessionMeta } => {
    const session = realSession();
    return { sent: [], session };
  };

  test("the wheel over the trigger steps one level per notch — deltaY>0 increases", () => {
    // Round-6 item 2: on the macOS natural-scrolling trackpad this pane ships
    // on, fingers moving UP produce POSITIVE deltaY; the round-5 `deltaY<0 →
    // up` mapping was experienced as reversed by the person using it.
    const { sent, session } = stepped();
    const sonnet = session.models.find((m) => m.value === "sonnet")!;
    const { container } = mountPicker(
      { ...session, effort: "medium" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    const trigger = container.querySelector<HTMLElement>(".composer-model-trigger")!;

    fireEvent.wheel(trigger, { deltaY: 120 });
    expect(sent).toEqual([["sonnet", "high"]]);
    fireEvent.wheel(trigger, { deltaY: -120 });
    expect(sent[1]).toEqual(["sonnet", "low"]);
    // Always the model's own selector, never the resolved id the CLI rejects.
    for (const [model] of sent) expect(model).toBe(sonnet.value);
  });

  test("trackpad drift below the threshold never steps (round-6 item 2)", () => {
    // The round-5 build stepped on ANY |deltaY| ≥ 1, so resting two fingers on
    // the chip yanked the level ("even a tiny scroll makes it go boogsh").
    // Small deltas must pool, not fire.
    const { sent, session } = stepped();
    const { container } = mountPicker(
      { ...session, effort: "medium" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    const trigger = container.querySelector<HTMLElement>(".composer-model-trigger")!;
    for (let i = 0; i < 5; i += 1) fireEvent.wheel(trigger, { deltaY: 6 });
    expect(sent).toEqual([]);
    // …but a sustained deliberate roll does cross it and steps ONCE.
    for (let i = 0; i < 10; i += 1) fireEvent.wheel(trigger, { deltaY: 6 });
    expect(sent).toEqual([["sonnet", "high"]]);
  });

  test("horizontal trackpad noise is not a reasoning change", () => {
    // A trackpad emits a stream of small deltas in both axes; a sideways swipe
    // over the chip must not silently downgrade the turn.
    const { sent, session } = stepped();
    const { container } = mountPicker(
      { ...session, effort: "medium" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    const trigger = container.querySelector<HTMLElement>(".composer-model-trigger")!;
    fireEvent.wheel(trigger, { deltaY: 0.4, deltaX: 0 });
    fireEvent.wheel(trigger, { deltaY: 2, deltaX: 40 });
    expect(sent).toEqual([]);
  });

  test("it clamps at both ends rather than wrapping round", () => {
    // A wheel that rolls `max` over the top must not wrap back to `low`.
    const { sent, session } = stepped();
    const { container } = mountPicker(
      { ...session, effort: "max" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    fireEvent.wheel(container.querySelector<HTMLElement>(".composer-model-trigger")!, {
      deltaY: 120
    });
    expect(sent).toEqual([]);
  });

  test("a model with no effort scale ignores the wheel entirely", () => {
    const { sent, session } = stepped();
    const { container } = mountPicker(
      { ...session, model: "haiku" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    fireEvent.wheel(container.querySelector<HTMLElement>(".composer-model-trigger")!, {
      deltaY: 120
    });
    expect(sent).toEqual([]);
  });

  test("Option+. and Option+, step it from the composer", () => {
    const sent: Array<[string, string | undefined]> = [];
    const session = realSession();
    mountPicker(
      { ...session, effort: "medium" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    const input = screen.getByRole("textbox");

    fireEvent.keyDown(input, { code: "Period", key: "≥", altKey: true });
    expect(sent).toEqual([["sonnet", "high"]]);
    fireEvent.keyDown(input, { code: "Comma", key: "≤", altKey: true });
    expect(sent[1]).toEqual(["sonnet", "low"]);
  });

  test("it matches the physical key, not the character macOS produces", () => {
    // On macOS Option+comma is "≤" and Option+period is "≥", so a handler that
    // tests `event.key === ","` matches NOTHING on the platform this pane ships
    // on. Asserted by sending the real macOS pair with a key that is not a
    // comma: if the implementation ever regresses to `event.key`, this is the
    // test that catches it.
    const sent: Array<[string, string | undefined]> = [];
    mountPicker(
      { ...realSession(), effort: "medium" },
      { onSetModel: (model, effort) => sent.push([model, effort]) }
    );
    fireEvent.keyDown(screen.getByRole("textbox"), { code: "Period", key: "≥", altKey: true });
    expect(sent.length).toBe(1);
  });

  test("the two glyphs never reach the draft", () => {
    // Without preventDefault the binding types "≥" into the message it was
    // meant to configure.
    let draft = "";
    const session = realSession();
    render(
      <CopyProvider dict={undefined}>
        <Composer
          disabled={false}
          running={false}
          awaitingPermission={false}
          planPending={false}
          onPlanImplement={() => {}}
          onPlanRefine={() => {}}
          onPlanKeepPlanning={() => {}}
          queued={[]}
          commands={[]}
          permissionMode="default"
          draft=""
          onDraftChange={(next) => {
            draft = next;
          }}
          onSend={() => {}}
          onInterrupt={() => {}}
          onCancelQueued={() => {}}
          onCyclePermissionMode={() => {}}
          fetchFileSuggestions={async () => []}
          onPickFiles={async () => ({ images: [] })}
          session={{ ...session, effort: "medium" }}
          onSetModel={() => {}}
        />
      </CopyProvider>
    );
    const event = createEvent.keyDown(screen.getByRole("textbox"), {
      code: "Period",
      key: "≥",
      altKey: true
    });
    fireEvent(screen.getByRole("textbox"), event);
    expect(event.defaultPrevented).toBe(true);
    expect(draft).toBe("");
  });

  test("Option+, without a model to change is inert, not a swallowed key", () => {
    // The agent-view harness mounts a Composer with no session; claiming the
    // key there would eat a character the user meant to type.
    mount();
    const event = createEvent.keyDown(screen.getByRole("textbox"), {
      code: "Comma",
      key: "≤",
      altKey: true
    });
    fireEvent(screen.getByRole("textbox"), event);
    expect(event.defaultPrevented).toBe(false);
  });
});

function mountAttachmentComposer(options: {
  picked?: ImageAttachment[];
  pickFiles?(): Promise<PickedImageAttachments>;
  onSend?(text: string, images: ImageAttachment[]): void;
  identity?: string;
} = {}) {
  if (typeof URL.createObjectURL !== "function") {
    Object.defineProperty(URL, "createObjectURL", {
      configurable: true,
      value: () => "blob:test-attachment"
    });
  }
  if (typeof URL.revokeObjectURL !== "function") {
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: () => {} });
  }
  let identity = options.identity;
  let draft = "";
  let rendered: ReturnType<typeof render>;
  const view = () => (
    <CopyProvider dict={undefined}>
      <Composer
        disabled={false}
        running={false}
        awaitingPermission={false}
        planPending={false}
        onPlanImplement={() => {}}
        onPlanRefine={() => {}}
        onPlanKeepPlanning={() => {}}
        queued={[]}
        commands={[]}
        permissionMode="default"
        draft={draft}
        onDraftChange={(next) => {
          draft = next;
          rendered.rerender(view());
        }}
        onSend={options.onSend ?? (() => {})}
        onInterrupt={() => {}}
        onCancelQueued={() => {}}
        onCyclePermissionMode={() => {}}
        fetchFileSuggestions={async () => []}
        onPickFiles={
          options.pickFiles ?? (async () => ({ images: options.picked ?? [] }))
        }
        attachmentIdentity={identity}
      />
    </CopyProvider>
  );
  rendered = render(view());
  return {
    ...rendered,
    setDraft(next: string) {
      act(() => {
        draft = next;
        rendered.rerender(view());
      });
    },
    setIdentity(next: string) {
      act(() => {
        identity = next;
        rendered.rerender(view());
      });
    }
  };
}

function pasteFiles(files: File[]): void {
  fireEvent.paste(screen.getByRole("textbox"), { clipboardData: { files } });
}

async function settleAttachments(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 20));
  });
}

function fileReportingSize(name: string, size: number): File {
  const file = new File(["x"], name, { type: "image/png" });
  Object.defineProperty(file, "size", { configurable: true, value: size });
  return file;
}

function installObjectURLRecorder(): { created: string[]; revoked: string[] } {
  const created: string[] = [];
  const revoked: string[] = [];
  Object.defineProperty(URL, "createObjectURL", {
    configurable: true,
    value: () => {
      const value = `blob:attachment-${created.length}`;
      created.push(value);
      return value;
    }
  });
  Object.defineProperty(URL, "revokeObjectURL", {
    configurable: true,
    value: (value: string) => revoked.push(value)
  });
  return { created, revoked };
}

describe("composer attachment contract", () => {
  test("paste rejects image MIME types the protocol cannot send", async () => {
    mountAttachmentComposer();
    pasteFiles([new File(["heic"], "photo.heic", { type: "image/heic" })]);

    await settleAttachments();
    expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    expect(screen.queryByRole("alert")?.textContent).toContain(
      "Unsupported image format. Use PNG, JPEG, GIF, or WebP."
    );
  });

  test("drop rejects one image over 512 KiB", async () => {
    const { container } = mountAttachmentComposer();
    const oversized = fileReportingSize("large.png", 512 * 1024 + 1);
    fireEvent.drop(container.querySelector(".composer-shell")!, {
      dataTransfer: { files: [oversized] }
    });

    await settleAttachments();
    expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    expect(screen.queryByRole("alert")?.textContent).toContain(
      "Each image must be 512 KiB or smaller."
    );
  });

  test("paste enforces the 2 MiB aggregate decoded-byte limit", async () => {
    mountAttachmentComposer();
    const files = Array.from({ length: 5 }, (_, index) =>
      fileReportingSize(`image-${index}.png`, 512 * 1024)
    );
    pasteFiles(files);

    await settleAttachments();
    expect(document.querySelectorAll(".attach-chip").length).toBe(4);
    expect(screen.queryByRole("alert")?.textContent).toContain(
      "Attachments must total 2 MiB or less."
    );
  });

  test("paste accepts at most eight images in the attachment strip", async () => {
    mountAttachmentComposer();
    const files = Array.from({ length: 9 }, (_, index) =>
      new File([String(index)], `image-${index}.png`, { type: "image/png" })
    );
    pasteFiles(files);

    await settleAttachments();
    expect(document.querySelectorAll(".attach-chip").length).toBe(8);
    expect(screen.queryByRole("alert")?.textContent).toContain(
      "You can attach up to 8 images."
    );
  });

  test("native picker payloads are revalidated rather than trusted", async () => {
    mountAttachmentComposer({
      picked: [{ mediaType: "image/png", dataBase64: "not base64", name: "forged.png" }]
    });
    fireEvent.click(screen.getByLabelText("Attach files"));

    await settleAttachments();
    expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    expect(screen.queryByRole("alert")?.textContent).toContain("Could not read this image.");
  });

  test("native picker reports rejected selections while preserving valid images", async () => {
    mountAttachmentComposer({
      pickFiles: async () => ({
        images: [{ mediaType: "image/png", dataBase64: "cG5n", name: "valid.png" }],
        error: "imageTooLarge"
      })
    });
    fireEvent.click(screen.getByLabelText("Attach files"));
    await settleAttachments();

    expect(document.querySelectorAll(".attach-chip").length).toBe(1);
    expect(screen.getByText("valid.png")).toBeDefined();
    expect(screen.queryByRole("alert")?.textContent).toContain(
      "Each image must be 512 KiB or smaller."
    );
  });

  test("removing an attachment releases its object URL", async () => {
    const urls = installObjectURLRecorder();
    mountAttachmentComposer();
    pasteFiles([new File(["png"], "remove.png", { type: "image/png" })]);
    await screen.findByText("remove.png");

    fireEvent.click(screen.getByLabelText("Remove attachment"));

    expect(urls.created).toEqual(["blob:attachment-0"]);
    expect(urls.revoked).toEqual(["blob:attachment-0"]);
  });

  test("send preserves exact bytes and releases attachment ownership", async () => {
    const urls = installObjectURLRecorder();
    const sent: ImageAttachment[][] = [];
    mountAttachmentComposer({ onSend: (_text, images) => sent.push(images) });
    pasteFiles([
      new File([new Uint8Array([0, 1, 2, 255])], "exact.png", { type: "image/png" })
    ]);
    await screen.findByText("exact.png");

    fireEvent.click(document.querySelector(".btn-send")!);

    await waitFor(() => {
      expect(sent).toEqual([
        [{ mediaType: "image/png", dataBase64: "AAEC/w==", name: "exact.png" }]
      ]);
      expect(urls.revoked).toEqual(["blob:attachment-0"]);
      expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    });
  });

  test("an image encoding failure restores the submitted text for retry", async () => {
    const image = new File([new Uint8Array([1])], "broken.png", { type: "image/png" });
    Object.defineProperty(image, "arrayBuffer", {
      configurable: true,
      value: () => Promise.reject(new Error("decode failed"))
    });
    const rendered = mountAttachmentComposer();
    pasteFiles([image]);
    await screen.findByText("broken.png");
    rendered.setDraft("keep this message");

    fireEvent.click(document.querySelector(".btn-send")!);

    await waitFor(() => {
      expect((screen.getByRole("textbox") as HTMLTextAreaElement).value).toBe("keep this message");
      expect(screen.queryByRole("alert")?.textContent).toContain("Could not read this image.");
    });
  });

  test("a failed older image send never overwrites newer draft text", async () => {
    let rejectBytes: (reason?: unknown) => void = () => undefined;
    const bytes = new Promise<ArrayBuffer>((_resolve, reject) => {
      rejectBytes = reject;
    });
    const image = new File([new Uint8Array([1])], "slow-broken.png", { type: "image/png" });
    Object.defineProperty(image, "arrayBuffer", {
      configurable: true,
      value: () => bytes
    });
    const rendered = mountAttachmentComposer();
    pasteFiles([image]);
    await screen.findByText("slow-broken.png");
    rendered.setDraft("submitted text");
    fireEvent.click(document.querySelector(".btn-send")!);
    rendered.setDraft("newer draft");

    await act(async () => {
      rejectBytes(new Error("decode failed"));
      await bytes.catch(() => undefined);
    });

    expect((screen.getByRole("textbox") as HTMLTextAreaElement).value).toBe("newer draft");
  });

  test("an image send keeps its submit order while bytes are loading", async () => {
    let releaseBytes: (value: ArrayBuffer) => void = () => undefined;
    const bytes = new Promise<ArrayBuffer>((resolve) => {
      releaseBytes = resolve;
    });
    const image = new File([new Uint8Array([1])], "slow.png", { type: "image/png" });
    Object.defineProperty(image, "arrayBuffer", {
      configurable: true,
      value: () => bytes
    });
    const sent: string[] = [];
    const rendered = mountAttachmentComposer({ onSend: (text) => sent.push(text) });
    pasteFiles([image]);
    await screen.findByText("slow.png");
    rendered.setDraft("first");
    fireEvent.click(document.querySelector(".btn-send")!);

    rendered.setDraft("second");
    fireEvent.click(document.querySelector(".btn-send")!);
    expect(sent).toEqual([]);

    await act(async () => {
      releaseBytes(new Uint8Array([1]).buffer);
      await bytes;
    });
    await waitFor(() => expect(sent).toEqual(["first", "second"]));
  });

  test("conversation identity reset releases staged attachments", async () => {
    const urls = installObjectURLRecorder();
    const rendered = mountAttachmentComposer({ identity: "session-one" });
    pasteFiles([new File(["one"], "identity.png", { type: "image/png" })]);
    await screen.findByText("identity.png");

    rendered.setIdentity("session-two");

    expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    expect(urls.revoked).toEqual(["blob:attachment-0"]);
  });

  test("a picker result from the previous identity is discarded", async () => {
    const urls = installObjectURLRecorder();
    let resolvePick: (result: PickedImageAttachments) => void = () => {};
    const pendingPick = new Promise<PickedImageAttachments>((resolve) => {
      resolvePick = resolve;
    });
    const rendered = mountAttachmentComposer({
      identity: "session-one",
      pickFiles: () => pendingPick
    });
    fireEvent.click(screen.getByLabelText("Attach files"));
    rendered.setIdentity("session-two");

    await act(async () => {
      resolvePick({
        images: [{ mediaType: "image/png", dataBase64: "cG5n", name: "stale.png" }]
      });
      await pendingPick;
    });

    expect(document.querySelectorAll(".attach-chip").length).toBe(0);
    expect(urls.created).toEqual([]);
  });

  test("unmount releases every remaining attachment", async () => {
    const urls = installObjectURLRecorder();
    const rendered = mountAttachmentComposer();
    pasteFiles([
      new File(["one"], "one.png", { type: "image/png" }),
      new File(["two"], "two.png", { type: "image/png" })
    ]);
    await screen.findByText("two.png");

    rendered.unmount();

    expect(urls.created).toEqual(["blob:attachment-0", "blob:attachment-1"]);
    expect(urls.revoked).toEqual(["blob:attachment-0", "blob:attachment-1"]);
  });
});

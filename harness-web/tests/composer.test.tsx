import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { fixtures, richSession } from "../src/dev/fixtures";
import { activeModelFor, emptySession } from "../src/model/helpers";
import { replayLines } from "../src/model/transcript";
import type { SessionMeta } from "../src/model/types";
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
        onPickFiles={async () => []}
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
  const row = Array.from(list.querySelectorAll<HTMLElement>(".popover-label")).find(
    (node) => node.textContent === label
  );
  if (!row) throw new Error(`no popover row for ${label}`);
  return row;
}

describe("slash-command popover completes a real command", () => {
  test("accepting with Enter keeps the leading slash", async () => {
    const harness = mount();
    type("/co");
    await popoverRow("/compact");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

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

    expect(harness.draft()).toBe("/compact ");
  });

  test("the completed command is what gets sent", async () => {
    const harness = mount();
    type("/context");
    await popoverRow("/context");
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });
    // The completion repositions the caret in a rAF; let it land so the popover
    // is genuinely closed and the next Enter submits rather than re-completing.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

    expect(harness.sent).toEqual(["/context"]);
  });

  test("a mention still carries its own sigil", async () => {
    const harness = mount();
    type("look at @App");
    await popoverRow("src/ui/App.tsx");

    fireEvent.keyDown(screen.getByRole("textbox"), { key: "Enter" });

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
        onPickFiles={async () => []}
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
    expect(container.querySelector(".model-search")).toBeNull();
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
    expect(container.querySelector(".menu-item-detail")).toBeNull();
  });

  test("picking a row sends the catalog selector, never the resolved id", () => {
    const sent: Array<[string, string | undefined]> = [];
    mountPicker(realSession(), { onSetModel: (model, effort) => sent.push([model, effort]) });
    openPicker();
    fireEvent.click(screen.getByRole("menuitemradio", { name: /^Haiku/ }));
    expect(sent).toEqual([["haiku", undefined]]);
  });
});

/** The row's effort strip: inline, in the same panel, under the row it belongs to. */
function tuneRow(container: HTMLElement, name: RegExp): HTMLElement {
  const row = screen.getByRole("menuitemradio", { name });
  const tune = row.parentElement!.querySelector<HTMLElement>(".model-tune");
  if (!tune) throw new Error("row has no reasoning control");
  return tune;
}

describe("reasoning opens inline, under the row it belongs to", () => {
  test("the active model's own strip is already open when the panel appears", () => {
    // The setting the trigger is advertising is the one thing on screen first;
    // reaching it used to take a hover onto a floating side panel.
    const { container } = mountPicker(realSession());
    openPicker();
    const open = container.querySelectorAll(".model-efforts");
    expect(open.length).toBe(1);
    expect(open[0].closest(".model-row-wrap")!.textContent).toContain("Sonnet");
  });

  test("a model with no effort levels grows no control at all", () => {
    // haiku advertises none; a Reasoning affordance there promises a setting
    // the CLI rejects.
    const { container } = mountPicker(realSession());
    openPicker();
    const haiku = screen.getByRole("menuitemradio", { name: /^Haiku/ });
    expect(haiku.parentElement!.querySelector(".model-tune")).toBeNull();
  });

  test("the strip lists every level the model supports, as labels", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    const wrap = screen
      .getByRole("menuitemradio", { name: /Sonnet/ })
      .closest(".model-row-wrap")!;
    const levels = Array.from(wrap.querySelectorAll(".model-effort")).map(
      (node) => node.textContent ?? ""
    );
    // sonnet advertises all five levels in the live initialize response.
    expect(levels.length).toBe(5);
    // `xhigh` is a wire token no user would write.
    expect(levels.some((level) => level.startsWith("Extra high"))).toBe(true);
    expect(levels.some((level) => level.includes("xhigh"))).toBe(false);
    for (const level of levels) expect(level).toMatch(/^[A-Z]/);
  });

  test("the control toggles its own row's strip and no other", () => {
    const { container } = mountPicker(realSession());
    openPicker();
    // Opus's strip is closed on open (Sonnet is the live model); opening it
    // closes Sonnet's, so the panel never carries two.
    fireEvent.click(tuneRow(container, /Opus \(1M context\)/));
    const open = container.querySelectorAll(".model-efforts");
    expect(open.length).toBe(1);
    expect(open[0].closest(".model-row-wrap")!.textContent).toContain("Opus (1M context)");
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
    mountPicker(session, { onSetModel: (model, effort) => sent.push([model, effort]) });
    openPicker();
    fireEvent.click(screen.getByText("Restore defaults"));
    expect(sent).toEqual([["sonnet", sonnet.defaultEffortLevel]]);
  });

  test("a tunable row states its live level on the row itself", () => {
    // The old flyout hid it, so the list could not answer "what reasoning is
    // this model on" without hovering each row in turn.
    const { container } = mountPicker({ ...realSession(), effort: "xhigh" });
    openPicker();
    const row = screen.getByRole("menuitemradio", { name: /Sonnet/ });
    expect(row.querySelector(".model-row-effort")!.textContent).toBe("Extra high");
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
    const loading = container.querySelector(".menu-loading");
    expect(loading).not.toBeNull();
    expect(loading!.textContent).toContain("Loading models…");
    expect(container.querySelector(".spinner")).not.toBeNull();
  });

  test("a first-open pane renders rows from the cache, not a blank menu", () => {
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    const { container } = mountPicker(cold, { cachedModels: cached });
    openPicker();
    expect(container.querySelectorAll('[role="menuitemradio"]').length).toBe(cached.length);
    expect(container.querySelector(".menu-loading")).toBeNull();
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
    const open = container.querySelector(".model-efforts");
    expect(open).not.toBeNull();
    expect(open!.closest(".model-row-wrap")!.textContent).toContain("Opus (1M context)");
  });

  test("with no catalog at all the selector is still shown rather than nothing", () => {
    // Falling back to the raw value is correct when there is genuinely nothing
    // to resolve against; the bug was doing it while a catalog was right there.
    const { container } = mountPicker(cold());
    expect(triggerLabel(container)).toBe("opus[1m]");
  });
});

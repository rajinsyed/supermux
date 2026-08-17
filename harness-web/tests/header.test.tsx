import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { fixtures, richSession } from "../src/dev/fixtures";
import { activeModelFor, emptySession, emptyUsage } from "../src/model/helpers";
import { replayLines } from "../src/model/transcript";
import type { SessionMeta } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Header, modelMenuSource, type HeaderProps } from "../src/ui/header/Header";

afterEach(cleanup);

const NOOP = {
  onRename: () => {},
  onSetModel: () => {},
  onSetPermissionMode: () => {},
  onResumeSession: () => {},
  onOpenSessionInNewPane: () => {},
  onLoadSessions: () => {},
  onCompact: () => {},
  onClear: () => {},
  onExport: () => {},
  onOpenTerminal: () => {},
  onNewSession: () => {},
  onOpenBinarySettings: () => {}
};

function mount(session: SessionMeta, extra: Partial<HeaderProps> = {}) {
  return render(
    <CopyProvider dict={undefined}>
      <Header session={session} usage={emptyUsage()} sessions={[]} {...NOOP} {...extra} />
    </CopyProvider>
  );
}

/**
 * The real CLI reports the RESOLVED id in `system/init` ("claude-sonnet-5") while
 * the `initialize` catalog is keyed by short SELECTOR ("sonnet"). The two
 * namespaces never overlap, so a lookup on `value` alone leaves the pill printing
 * a raw id, no menu row checked, and the effort section unreachable.
 */
function realSession(): SessionMeta {
  const model = replayLines(richSession);
  return model.session;
}

describe("the active model resolves across both identifier namespaces", () => {
  test("the real trace still carries the mismatch that broke this", () => {
    const session = realSession();
    expect(session.model).toBe("claude-sonnet-5");
    expect(session.models.some((m) => m.value === session.model)).toBe(false);
    expect(session.models.some((m) => m.resolvedModel === session.model)).toBe(true);
  });

  test("the pill prints the display name, not the raw id", () => {
    const { container } = mount(realSession());
    const pill = container.querySelector(".model-pill .pill-label")!;
    expect(pill.textContent).toBe("Sonnet");
    expect(pill.textContent).not.toContain("claude-");
  });

  test("exactly one model row is checked in the menu", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Model"));
    const checked = container.querySelectorAll('[role="menuitemradio"][aria-checked="true"]');
    expect(checked.length).toBe(1);
    expect(checked[0].textContent).toContain("Sonnet");
  });

  test("the effort section is reachable on a real session", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Model"));
    const titles = Array.from(container.querySelectorAll(".menu-section-title")).map(
      (node) => node.textContent
    );
    expect(titles).toContain("Effort");
    // sonnet advertises all five levels in the live initialize response.
    expect(container.querySelectorAll(".menu-section")[1].querySelectorAll(".menu-item").length)
      .toBe(5);
  });

  test("an effort pick sends the catalog selector, never the resolved id", () => {
    const sent: Array<[string, string | undefined]> = [];
    render(
      <CopyProvider dict={undefined}>
        <Header
          session={realSession()}
          usage={emptyUsage()}
          sessions={[]}
          {...NOOP}
          onSetModel={(model, effort) => sent.push([model, effort])}
        />
      </CopyProvider>
    );
    fireEvent.click(screen.getByLabelText("Model"));
    fireEvent.click(screen.getByRole("menuitemradio", { name: "High" }));
    expect(sent).toEqual([["sonnet", "high"]]);
  });

  test("effort rows read as labels, never as the raw wire tokens", () => {
    // `xhigh` is a protocol token no user would write, and it sat lowercase
    // beside "Auto-edit" and "Opus (1M context)". The pill printed the same
    // value uppercased, so the menu and the pill disagreed about one setting.
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Model"));
    const rows = Array.from(
      container.querySelectorAll(".menu-section")[1].querySelectorAll(".menu-item")
    ).map((node) => node.textContent ?? "");
    expect(rows.some((row) => row.startsWith("Extra high"))).toBe(true);
    expect(rows.some((row) => row.includes("xhigh"))).toBe(false);
    for (const row of rows) expect(row).toMatch(/^[A-Z]/);
  });

  test("the pill and the menu print one effort value the same way", () => {
    const session = replayLines(richSession).session;
    const { container } = mount({ ...session, effort: "xhigh" });
    expect(container.querySelector(".effort-tag")!.textContent).toBe("Extra high");
  });

  test("no scenario ever prints a raw model id in the pill", () => {
    // Every scenario, not only the two real traces: a fixture that ships a model
    // the catalog cannot resolve puts a raw id in the header of that scenario.
    const raw: string[] = [];
    for (const [name, lines] of Object.entries(fixtures)) {
      const session = replayLines(lines as never).session;
      if (!session.model || session.models.length === 0) continue;
      const shown = activeModelFor(session)?.displayName ?? session.model;
      if (/^(claude|gpt)-/.test(shown)) raw.push(`${name}=${shown}`);
    }
    expect(raw).toEqual([]);
  });

  test("the synthetic catalog keeps the real CLI's selector/resolved split", () => {
    // The bug survived three rounds because build.ts listed a catalog whose
    // `value` happened to equal the init model — a coincidence the CLI never
    // produces (ctl_log.txt: default | opus[1m] | sonnet | haiku). Restore the
    // coincidence and every synthetic scenario stops exercising the mismatch.
    const session = replayLines(fixtures.todos).session;
    expect(session.model).toBe("claude-sonnet-5");
    for (const model of session.models) {
      expect(model.value).not.toBe(model.resolvedModel);
      expect(model.value.startsWith("claude-")).toBe(false);
    }
    expect(session.models.some((m) => m.value === session.model)).toBe(false);
    expect(activeModelFor(session)?.displayName).toBe("Sonnet 5");
  });

  test("an unknown model still prints something rather than blanking the pill", () => {
    const session = { ...emptySession(), model: "some-future-model" };
    const { container } = mount(session);
    expect(container.querySelector(".model-pill .pill-label")!.textContent).toBe(
      "some-future-model"
    );
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

  test("a first-open pane renders rows from the cache, not a blank menu", () => {
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    const { container } = mount(cold, { cachedModels: cached });
    fireEvent.click(screen.getByLabelText("Model"));
    // The model section only — the effort section below it is populated from
    // whichever row resolved as active.
    const rows = container
      .querySelectorAll(".menu-section")[0]
      .querySelectorAll('[role="menuitemradio"]');
    expect(rows.length).toBe(cached.length);
    expect(container.querySelector(".menu-loading")).toBeNull();
  });

  test("the cached rows resolve the active model the same way the live ones do", () => {
    // The catalog is keyed by selector and init reports the resolved id, so a
    // cache that failed to resolve would leave every row unchecked.
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    const { container } = mount(cold, { cachedModels: cached });
    fireEvent.click(screen.getByLabelText("Model"));
    const checked = container.querySelectorAll('[role="menuitemradio"][aria-checked="true"]');
    expect(checked.length).toBe(1);
    expect(checked[0].textContent).toContain("Sonnet");
  });

  test("a pre-start pick reports the catalog selector, ready for the first start", () => {
    const sent: Array<[string, string | undefined]> = [];
    const cold = { ...emptySession(), model: "claude-sonnet-5" };
    mount(cold, {
      cachedModels: cached,
      onSetModel: (model, effort) => sent.push([model, effort])
    });
    fireEvent.click(screen.getByLabelText("Model"));
    fireEvent.click(screen.getByRole("menuitemradio", { name: /^Haiku/ }));
    // The selector, not the resolved id: it is what `set_model` and the first
    // start's `model` parameter both take.
    expect(sent).toEqual([["haiku", undefined]]);
  });

  test("with nothing yet it shows a spinner row instead of a void", () => {
    const { container } = mount(emptySession());
    fireEvent.click(screen.getByLabelText("Model"));
    const loading = container.querySelector(".menu-loading");
    expect(loading).not.toBeNull();
    expect(loading!.textContent).toContain("Loading models…");
    expect(container.querySelector(".spinner")).not.toBeNull();
  });
});

describe("the session browser exposes both ways to open a session", () => {
  const sessions = [
    { sessionId: "s-1", title: "Fix sidebar scroll", updatedAtMs: Date.now() - 60000 }
  ];

  test("resume replaces this pane's session", () => {
    const calls: Array<[string, boolean]> = [];
    mount(realSession(), {
      sessions,
      onResumeSession: (id, fork) => calls.push([id, fork])
    });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(screen.getByText("Resume"));
    expect(calls).toEqual([["s-1", false]]);
  });

  test("fork is still its own affordance", () => {
    const calls: Array<[string, boolean]> = [];
    mount(realSession(), {
      sessions,
      onResumeSession: (id, fork) => calls.push([id, fork])
    });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(screen.getByText("Fork"));
    expect(calls).toEqual([["s-1", true]]);
  });

  test("a session can be opened beside this one instead of replacing it", () => {
    // One live process per pane is by design; running two sessions at once has
    // to be discoverable rather than something a user infers from an error.
    const opened: string[] = [];
    mount(realSession(), {
      sessions,
      onOpenSessionInNewPane: (id) => opened.push(id)
    });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(screen.getByText("New pane"));
    expect(opened).toEqual(["s-1"]);
  });

  test("each row action says what it does to the current pane", () => {
    const { container } = mount(realSession(), { sessions });
    fireEvent.click(screen.getByLabelText("Sessions"));
    const titles = Array.from(
      container.querySelectorAll(".session-actions button")
    ).map((node) => node.getAttribute("title"));
    expect(titles).toEqual([
      "Replaces this pane's session",
      "Branch into a copy, leaving this one untouched",
      "Open beside this one, both live at once"
    ]);
  });
});

describe("the overflow menu reaches the binary setting", () => {
  test("Claude binary… is one click from the header", () => {
    let opened = 0;
    mount(realSession(), {
      onOpenBinarySettings: () => {
        opened += 1;
      }
    });
    fireEvent.click(screen.getByLabelText("More"));
    fireEvent.click(screen.getByText("Claude binary…"));
    expect(opened).toBe(1);
  });
});

describe("single-select menus announce which row is live", () => {
  test("permission modes are radios with a checked state", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Permissions"));
    const rows = container.querySelectorAll('[role="menuitemradio"]');
    expect(rows.length).toBe(4);
    expect(
      Array.from(rows).filter((row) => row.getAttribute("aria-checked") === "true").length
    ).toBe(1);
  });

  test("action-only rows stay plain menu items with no checked state", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("More"));
    const rows = container.querySelectorAll('.menu-pop [role="menuitem"]');
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) expect(row.getAttribute("aria-checked")).toBeNull();
  });

  test("arrow keys move between rows instead of leaving focus behind", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Permissions"));
    const pop = container.querySelector(".menu-pop")!;
    const rows = Array.from(pop.querySelectorAll<HTMLElement>('[role="menuitemradio"]'));

    fireEvent.keyDown(pop, { key: "ArrowDown" });
    expect(document.activeElement).toBe(rows[0]);
    fireEvent.keyDown(pop, { key: "ArrowDown" });
    expect(document.activeElement).toBe(rows[1]);
    fireEvent.keyDown(pop, { key: "ArrowUp" });
    expect(document.activeElement).toBe(rows[0]);
  });

  test("Tab cycles inside the popup rather than walking into the next trigger", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Permissions"));
    const pop = container.querySelector(".menu-pop")!;
    const rows = Array.from(pop.querySelectorAll<HTMLElement>('[role="menuitemradio"]'));
    rows[rows.length - 1].focus();

    fireEvent.keyDown(pop, { key: "Tab" });

    expect(pop.contains(document.activeElement)).toBe(true);
    expect(document.activeElement).toBe(rows[0]);
  });
});

import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { fixtures, richSession } from "../src/dev/fixtures";
import { activeModelFor, emptySession, emptyUsage } from "../src/model/helpers";
import { replayLines } from "../src/model/transcript";
import type { SessionMeta } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Header } from "../src/ui/header/Header";

afterEach(cleanup);

const NOOP = {
  onRename: () => {},
  onSetModel: () => {},
  onSetPermissionMode: () => {},
  onResumeSession: () => {},
  onLoadSessions: () => {},
  onCompact: () => {},
  onClear: () => {},
  onExport: () => {},
  onOpenTerminal: () => {},
  onNewSession: () => {}
};

function mount(session: SessionMeta) {
  return render(
    <CopyProvider dict={undefined}>
      <Header session={session} usage={emptyUsage()} sessions={[]} {...NOOP} />
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
    fireEvent.click(screen.getByRole("menuitemradio", { name: "high" }));
    expect(sent).toEqual([["sonnet", "high"]]);
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

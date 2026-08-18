import { afterEach, describe, expect, test } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { richSession } from "../src/dev/fixtures";
import { emptyUsage } from "../src/model/helpers";
import { replayLines } from "../src/model/transcript";
import type { SessionMeta } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Header, type HeaderProps } from "../src/ui/header/Header";

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
 * the `initialize` catalog is keyed by short SELECTOR ("sonnet"). Resolving across
 * both namespaces is the MODEL PICKER's job, and the picker moved into the
 * composer pill — tests/composer.test.tsx owns it, markup and all. What the
 * header still owns is everything the strip kept: the session browser, the
 * overflow menu, and the permission-mode pill.
 */
function realSession(): SessionMeta {
  const model = replayLines(richSession);
  return model.session;
}

/**
 * The strip lost the model pill to the composer. Nothing in the bottom bar may
 * quietly grow one back: two model controls on one screen is exactly the
 * disagreement (pill says "opus[1m]", menu says "Opus 5") this pane already
 * shipped once.
 */
describe("the bottom strip no longer carries the model", () => {
  test("there is no model pill in the header", () => {
    const { container } = mount(realSession());
    expect(container.querySelector(".model-pill")).toBeNull();
    expect(container.querySelector(".effort-tag")).toBeNull();
  });

  test("the permission mode reads as text, with no icon beside it", () => {
    // Cursor's "Auto-edit ⌄": the mode's own hue names it. A shield glyph here
    // was a third icon weight on a line that already had a folder and a ring.
    const { container } = mount(realSession());
    const pill = container.querySelector(".mode-pill")!;
    expect(pill.querySelector(".pill-label")).not.toBeNull();
    // The chevron is the only glyph a text trigger earns.
    expect(pill.querySelectorAll("svg").length).toBe(1);
  });
});

/**
 * The bottom bar carries the pane's ADDRESS and its CONTROLS. The session title
 * used to sit on the left as an editable button; it named something the CLI
 * invented rather than something the user chose, it was the widest thing on the
 * strip, and clicking it opened an inline text field in a bar whose every other
 * control opens a menu.
 */
describe("the bottom bar carries no session title", () => {
  test("neither the title button nor its rename field is rendered", () => {
    const { container } = mount(realSession());
    expect(container.querySelector(".title-btn")).toBeNull();
    expect(container.querySelector(".title-input")).toBeNull();
  });

  test("the path chip is what identifies the pane", () => {
    const { container } = mount(realSession(), { workingDirectory: "/Users/dev/projects/app" });
    expect(container.querySelector(".dir-chip-text")).not.toBeNull();
  });

  test("onRename stays on the contract, so App.tsx needs no change to bring it back", () => {
    // Deliberately unused rather than removed: a rename belongs on a surface
    // that suits it (the sessions panel, a context menu), and dropping the prop
    // would mean a second round through a file this component does not own.
    let renamed = 0;
    mount(realSession(), { onRename: () => (renamed += 1) });
    expect(renamed).toBe(0);
  });
});

describe("the session browser exposes every way to open a session", () => {
  const sessions = [
    { sessionId: "s-1", title: "Fix sidebar scroll", updatedAtMs: Date.now() - 60000 }
  ];

  test("the ROW itself resumes — the primary action is not one of three buttons", () => {
    // Twenty sessions used to be sixty 11px buttons, with the titles they
    // belonged to the smallest thing in the panel.
    const calls: Array<[string, boolean]> = [];
    const { container } = mount(realSession(), {
      sessions,
      onResumeSession: (id, fork) => calls.push([id, fork])
    });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(container.querySelector(".session-open")!);
    expect(calls).toEqual([["s-1", false]]);
  });

  test("fork is still its own affordance", () => {
    const calls: Array<[string, boolean]> = [];
    mount(realSession(), {
      sessions,
      onResumeSession: (id, fork) => calls.push([id, fork])
    });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(screen.getByLabelText("Fork"));
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
    fireEvent.click(screen.getByLabelText("New pane"));
    expect(opened).toEqual(["s-1"]);
  });

  test("each affordance still says what it does to the current pane", () => {
    const { container } = mount(realSession(), { sessions });
    fireEvent.click(screen.getByLabelText("Sessions"));
    expect(container.querySelector(".session-open")!.getAttribute("title")).toBe(
      "Replaces this pane's session"
    );
    const titles = Array.from(
      container.querySelectorAll(".session-actions button")
    ).map((node) => node.getAttribute("title"));
    expect(titles).toEqual([
      "Branch into a copy, leaving this one untouched",
      "Open beside this one, both live at once"
    ]);
  });

  test("starting a new session is reachable from the session list itself", () => {
    // The one place a user goes to think about which session to be in must be
    // able to answer "none of these" without a second trip to the ••• menu.
    let started = 0;
    mount(realSession(), { sessions, onNewSession: () => (started += 1) });
    fireEvent.click(screen.getByLabelText("Sessions"));
    fireEvent.click(screen.getByText("New session"));
    expect(started).toBe(1);
  });

  test("the New session button is pinned outside the scrolling list", () => {
    // Twenty-four rows would otherwise scroll it out of reach.
    const { container } = mount(realSession(), { sessions });
    fireEvent.click(screen.getByLabelText("Sessions"));
    const button = container.querySelector(".sessions-new")!;
    expect(button.closest(".sessions-foot")).not.toBeNull();
    expect(button.closest(".sessions-list")).toBeNull();
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

  test("each mode says what it lets through, not only what it is called", () => {
    // "Ask each time" / "Plan only" name a policy without stating its
    // consequence, which is the only thing the choice is actually about.
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Permissions"));
    const details = Array.from(container.querySelectorAll(".mode-item .menu-item-detail")).map(
      (node) => node.textContent
    );
    expect(details.length).toBe(4);
    expect(details).toContain("No prompts at all — use with care");
    expect(details).toContain("Research and propose, change nothing");
  });

  test("every mode row carries its own hue, so the four are not one grey list", () => {
    const { container } = mount(realSession());
    fireEvent.click(screen.getByLabelText("Permissions"));
    const classes = Array.from(container.querySelectorAll(".mode-item")).map(
      (node) => node.className
    );
    for (const mode of ["default", "acceptEdits", "plan", "bypassPermissions"]) {
      expect(classes.some((name) => name.includes(`is-${mode}`))).toBe(true);
    }
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

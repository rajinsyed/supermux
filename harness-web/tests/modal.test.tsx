import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { emptySession, emptyUsage } from "../src/model/helpers";
import type { BinarySetting, RewindPreview } from "../src/protocol/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { Header } from "../src/ui/header/Header";
import { Modal } from "../src/ui/primitives/Modal";
import { BinaryDialog } from "../src/ui/settings/BinaryDialog";
import { RewindDialog } from "../src/ui/transcript/RewindDialog";

afterEach(cleanup);

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

async function settle() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

const SETTING: BinarySetting = { resolvedPath: "/opt/homebrew/bin/claude", version: "2.1.233" };
const PREVIEW: RewindPreview = {
  canRewind: true,
  filesChanged: ["/a/one.swift"],
  insertions: 3,
  deletions: 1
};

/**
 * Every behaviour a dialog promises — Escape, the Tab trap, focus coming back —
 * is handled ON THE PANEL, which means none of them exist until focus is inside
 * it. A pointer user who clicked the trigger and then reached for Escape got
 * nothing, because focus was still out on the trigger they had just clicked.
 * That is why this lives in Modal rather than in each consumer: a rule every
 * consumer has to remember is a rule one of them will forget, and the rewind
 * dialog is the one that did.
 */
describe("a dialog is operable from the keyboard the moment it opens", () => {
  test("focus lands inside without anyone clicking into it", () => {
    const { container } = mount(
      <Modal title="Test" onClose={() => {}}>
        <button type="button">Inside</button>
      </Modal>
    );
    const panel = container.querySelector('[role="dialog"]')!;
    expect(panel.contains(document.activeElement)).toBe(true);
  });

  test("Escape closes it with no prior interaction at all", () => {
    let closed = 0;
    mount(
      <Modal
        title="Test"
        onClose={() => {
          closed += 1;
        }}
      >
        <button type="button">Inside</button>
      </Modal>
    );
    // On whatever holds focus after mount — which is the point: the user has not
    // touched anything, and Escape still works.
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(closed).toBe(1);
  });

  test("Tab cycles inside the panel instead of walking out behind it", () => {
    const { container } = mount(
      <>
        <button type="button">Behind the scrim</button>
        <Modal title="Test" onClose={() => {}}>
          <button type="button">One</button>
          <button type="button">Two</button>
        </Modal>
      </>
    );
    const panel = container.querySelector('[role="dialog"]') as HTMLElement;
    const stops = Array.from(panel.querySelectorAll("button"));

    // From the panel itself, forward, then round the loop and back past the top.
    fireEvent.keyDown(panel, { key: "Tab" });
    expect(document.activeElement).toBe(stops[0]);
    for (let i = 1; i < stops.length; i += 1) {
      fireEvent.keyDown(panel, { key: "Tab" });
      expect(document.activeElement).toBe(stops[i]);
    }
    fireEvent.keyDown(panel, { key: "Tab" });
    expect(document.activeElement).toBe(stops[0]);
    fireEvent.keyDown(panel, { key: "Tab", shiftKey: true });
    expect(document.activeElement).toBe(stops[stops.length - 1]);
    expect(panel.contains(document.activeElement)).toBe(true);
  });

  test("the panel is reachable programmatically but is not a Tab stop of its own", () => {
    // Landing back on the panel partway round the cycle reads as focus
    // disappearing, so it takes -1 rather than 0.
    const { container } = mount(
      <Modal title="Test" onClose={() => {}}>
        <button type="button">Inside</button>
      </Modal>
    );
    expect(container.querySelector('[role="dialog"]')!.getAttribute("tabindex")).toBe("-1");
  });
});

/**
 * The docstring on Modal has always claimed focus returns to whatever opened it.
 * It did not: the capture read `document.activeElement`, and both dialogs are
 * opened from a header menu ROW that unmounts with its popover. Focus was
 * captured on a detached node, restoring it did nothing, and a keyboard user
 * closing the dialog was left on `<body>` — outside the app, with the next Tab
 * starting from the top of the document.
 */
describe("closing a dialog puts focus back where it came from", () => {
  test("the element that had focus when it opened gets it back", () => {
    const trigger = document.createElement("button");
    trigger.textContent = "More";
    document.body.appendChild(trigger);
    trigger.focus();
    expect(document.activeElement).toBe(trigger);

    const view = mount(
      <Modal title="Test" onClose={() => {}}>
        <button type="button">Inside</button>
      </Modal>
    );
    expect(document.activeElement).not.toBe(trigger);

    view.unmount();
    expect(document.activeElement).toBe(trigger);
    trigger.remove();
  });

  test("a trigger that was itself removed is not chased", () => {
    // Focusing a detached node silently focuses nothing; the caller (a rewind
    // refills the composer and focuses that) has the better answer anyway.
    const trigger = document.createElement("button");
    document.body.appendChild(trigger);
    trigger.focus();
    const view = mount(
      <Modal title="Test" onClose={() => {}}>
        <button type="button">Inside</button>
      </Modal>
    );
    trigger.remove();
    expect(() => view.unmount()).not.toThrow();
  });
});

/**
 * The real path, not a synthetic trigger: "Claude binary…" is a row inside the
 * More popover, and that row is GONE by the time the dialog mounts. Capturing
 * `document.activeElement` therefore captured a detached node, restoring it did
 * nothing, and focus ended on `<body>` — so a keyboard user who opened the
 * dialog from the header, then closed it, was outside the app with the next Tab
 * starting from the top of the document. The row hands focus back to the trigger
 * it belongs to first, which is what leaves the dialog something durable to
 * capture.
 */
describe("a dialog opened from the header menu returns focus to the header", () => {
  function HeaderWithBinaryDialog() {
    const [open, setOpen] = useState(false);
    return (
      <>
        <Header
          session={emptySession()}
          usage={emptyUsage()}
          sessions={[]}
          onRename={() => {}}
          onSetModel={() => {}}
          onSetPermissionMode={() => {}}
          onResumeSession={() => {}}
          onOpenSessionInNewPane={() => {}}
          onLoadSessions={() => {}}
          onCompact={() => {}}
          onClear={() => {}}
          onExport={() => {}}
          onOpenTerminal={() => {}}
          onNewSession={() => {}}
          onOpenBinarySettings={() => setOpen(true)}
        />
        {open ? (
          <BinaryDialog
            onClose={() => setOpen(false)}
            load={async () => SETTING}
            save={async () => SETTING}
          />
        ) : null}
      </>
    );
  }

  /**
   * A name for whatever holds focus. Comparing the ELEMENTS directly is the
   * obvious spelling and makes a failure unreadable: the matcher serializes both
   * DOM trees, and a failing focus assertion then prints the entire header and
   * dialog rather than the one fact under test.
   */
  const focused = () => {
    const active = document.activeElement;
    if (!active || active === document.body) return "<body>";
    return active.getAttribute("aria-label") ?? active.tagName.toLowerCase();
  };

  async function openBinaryDialog() {
    fireEvent.click(screen.getByLabelText("More"));
    await act(async () => {
      fireEvent.click(screen.getByText("Claude binary…"));
    });
    await settle();
  }

  test("Escape in the dialog lands focus on the More trigger, not on the body", async () => {
    mount(<HeaderWithBinaryDialog />);
    await openBinaryDialog();
    // The dialog owns focus while it is up.
    expect(screen.getByRole("dialog").contains(document.activeElement)).toBe(true);

    await act(async () => {
      fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    });
    await settle();

    expect(screen.queryByRole("dialog")).toBeNull();
    expect(focused()).toBe("More");
  });

  test("the same holds when the dialog's own Cancel closes it", async () => {
    mount(<HeaderWithBinaryDialog />);
    await openBinaryDialog();
    await act(async () => {
      fireEvent.click(screen.getByText("Cancel"));
    });
    await settle();
    expect(focused()).toBe("More");
  });
});

describe("both shipped dialogs inherit all of it", () => {
  test("the rewind dialog answers Escape without being clicked into first", async () => {
    // The one that did not: RewindDialog focused nothing, so Escape was dead
    // until the user manually tabbed in.
    let cancelled = 0;
    mount(
      <RewindDialog
        target={{ uuid: "u3", text: "Rename the resume helper", resumeAtUuid: "u2" }}
        onCancel={() => {
          cancelled += 1;
        }}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(cancelled).toBe(1);
  });

  test("the rewind dialog traps Tab", async () => {
    const { container } = mount(
      <RewindDialog
        target={{ uuid: "u3", text: "Rename the resume helper", resumeAtUuid: "u2" }}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    const panel = container.querySelector('[role="dialog"]') as HTMLElement;
    for (let i = 0; i < 8; i += 1) fireEvent.keyDown(panel, { key: "Tab" });
    expect(panel.contains(document.activeElement)).toBe(true);
  });

  test("the binary dialog still opens with the caret in its path field", async () => {
    // Modal focuses the panel, and BinaryDialog wants the field. The consumer
    // must win, or the change that fixed the rewind dialog would regress the one
    // that already worked: Modal is the CHILD, so its effect runs first.
    mount(<BinaryDialog onClose={() => {}} load={async () => SETTING} save={async () => SETTING} />);
    await settle();
    expect(document.activeElement).toBe(screen.getByRole("textbox"));
  });

  test("the binary dialog still answers Escape", async () => {
    let closed = 0;
    mount(
      <BinaryDialog
        onClose={() => {
          closed += 1;
        }}
        load={async () => SETTING}
        save={async () => SETTING}
      />
    );
    await settle();
    fireEvent.keyDown(document.activeElement!, { key: "Escape" });
    expect(closed).toBe(1);
  });
});

/**
 * Dropping conversation is reversible — the session is still on disk. Restoring
 * files is not, and a rewind with the checkbox armed does both. Drawing that
 * button exactly like every other confirm in the pane understates the half that
 * cannot be undone.
 */
describe("the rewind confirm carries the weight of what is armed", () => {
  test("an armed file restore makes the primary action destructive", async () => {
    mount(
      <RewindDialog
        target={{ uuid: "u3", text: "third", resumeAtUuid: "u2" }}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    expect(screen.getByRole("checkbox")).toHaveProperty("checked", true);
    expect(screen.getByText("Rewind & edit").className).toContain("btn-danger");
  });

  test("unchecking it steps back down to the ordinary primary", async () => {
    mount(
      <RewindDialog
        target={{ uuid: "u3", text: "third", resumeAtUuid: "u2" }}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => PREVIEW}
      />
    );
    await settle();
    fireEvent.click(screen.getByRole("checkbox"));
    const button = screen.getByText("Rewind & edit");
    expect(button.className).toContain("btn-primary");
    expect(button.className).not.toContain("btn-danger");
  });

  test("a conversation-only rewind is never dressed as destructive", async () => {
    mount(
      <RewindDialog
        target={{ uuid: "u3", text: "third", resumeAtUuid: "u2" }}
        onCancel={() => {}}
        onConfirm={() => {}}
        loadPreview={async () => ({
          canRewind: false,
          filesChanged: [],
          insertions: 0,
          deletions: 0
        })}
      />
    );
    await settle();
    expect(screen.getByText("Rewind & edit").className).not.toContain("btn-danger");
  });
});

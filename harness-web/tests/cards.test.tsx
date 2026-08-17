import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { fixtures } from "../src/dev/fixtures";
import { replayLines } from "../src/model/transcript";
import type { PendingPermission } from "../src/model/types";
import { CopyProvider } from "../src/ui/CopyContext";
import { PlanCard } from "../src/ui/permission/PlanCard";
import { QuestionCard } from "../src/ui/permission/QuestionCard";
import { PermissionCard, type PermissionDecision } from "../src/ui/permission/PermissionCard";

afterEach(cleanup);

function pendingFrom(lines: typeof fixtures.question): PendingPermission {
  const model = replayLines(lines);
  const pending = model.pending[0];
  if (!pending) throw new Error("fixture produced no pending request");
  return pending;
}

function mount(node: React.ReactElement) {
  return render(<CopyProvider dict={undefined}>{node}</CopyProvider>);
}

/**
 * Presses a key the way a browser does: the event originates on whatever is
 * focused and bubbles to the window handler, so `event.target` is real. A test
 * that dispatches on `window` directly would never exercise the focused-control
 * exemption in useCardKeys, which is where the round-1 fix broke.
 */
function press(key: string) {
  const target: EventTarget =
    document.activeElement && document.activeElement !== document.body
      ? document.activeElement
      : window;
  act(() => {
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  });
}

describe("QuestionCard keyboard", () => {
  const pending = pendingFrom(fixtures.question);
  const questions = pending.request.input.questions as Array<{
    question: string;
    multiSelect?: boolean;
    options: Array<{ label: string }>;
  }>;

  function setup() {
    const decisions: PermissionDecision[] = [];
    mount(<QuestionCard pending={pending} onDecide={(d) => decisions.push(d)} />);
    return decisions;
  }

  test("a number key answers the active question", () => {
    setup();
    press("2");
    expect(screen.getByRole("button", { name: /Clerk/ }).getAttribute("aria-pressed")).toBe("true");
  });

  test("Enter submits even though auto-advance left focus on an option", () => {
    const decisions = setup();
    // Answer Q1; the 200ms auto-advance focuses the first option of Q2, which is
    // exactly the state that used to swallow Enter into a toggle.
    press("2");
    const option = screen.getByRole("button", { name: /Clerk/ });
    act(() => option.focus());
    expect(document.activeElement).toBe(option);

    press("Enter");

    expect(decisions.length).toBe(1);
    expect(decisions[0].behavior).toBe("allow");
    const answers = (decisions[0].updatedInput as { answers: Record<string, string> }).answers;
    expect(answers[questions[0].question]).toBe("Clerk");
  });

  test("Enter on a focused option submits instead of toggling it back off", () => {
    const decisions = setup();
    const option = screen.getByRole("button", { name: /Clerk/ });
    fireEvent.click(option);
    expect(option.getAttribute("aria-pressed")).toBe("true");

    fireEvent.keyDown(option, { key: "Enter" });

    expect(option.getAttribute("aria-pressed")).toBe("true");
    expect(decisions.length).toBe(1);
  });

  test("Space still toggles a focused option without submitting", () => {
    const decisions = setup();
    const option = screen.getByRole("button", { name: /Clerk/ });
    act(() => option.focus());
    press(" ");
    expect(decisions.length).toBe(0);
  });

  test("typed free text is merged with the picked options, not substituted for them", () => {
    const decisions = setup();
    const multi = questions.find((q) => q.multiSelect);
    expect(multi).toBeDefined();
    // Move to the multi-select question and pick one option.
    fireEvent.click(screen.getByRole("button", { name: new RegExp(multi!.question.slice(0, 24)) }));
    const first = screen.getByRole("button", { name: new RegExp(multi!.options[0].label) });
    fireEvent.click(first);

    const input = screen.getByPlaceholderText("Type your answer…");
    fireEvent.change(input, { target: { value: "Team seats too" } });
    fireEvent.keyDown(input, { key: "Enter" });

    const answers = (decisions[0].updatedInput as { answers: Record<string, string> }).answers;
    expect(answers[multi!.question]).toBe(`${multi!.options[0].label}, Team seats too`);
  });
});

describe("PlanCard keyboard", () => {
  const pending = pendingFrom(fixtures.plan);

  function setup() {
    const decisions: PermissionDecision[] = [];
    mount(<PlanCard pending={pending} onDecide={(d) => decisions.push(d)} />);
    return decisions;
  }

  test("Escape keeps planning with nothing focused", () => {
    const decisions = setup();
    act(() => (document.activeElement as HTMLElement | null)?.blur());
    expect(document.activeElement === null || document.activeElement === document.body).toBe(true);

    press("Escape");

    expect(decisions.length).toBe(1);
    expect(decisions[0].behavior).toBe("deny");
  });

  test("Enter approves with auto-accept even when focus has left the primary", () => {
    const decisions = setup();
    act(() => (document.activeElement as HTMLElement | null)?.blur());

    press("Enter");

    expect(decisions.length).toBe(1);
    expect(decisions[0].behavior).toBe("allow");
    const suggestion = decisions[0].updatedPermissions?.[0] as { mode?: string } | undefined;
    expect(suggestion?.mode).toBe("acceptEdits");
  });

  test("the printed shortcuts and the download action are both present", () => {
    setup();
    expect(screen.getByRole("button", { name: /Download plan/ })).toBeDefined();
    expect(screen.getByRole("button", { name: /Copy plan/ })).toBeDefined();
  });
});

describe("approval cards are named for a screen reader", () => {
  // An `alertdialog` inherits `dialog`'s name-required rule. Unnamed, the
  // assertive interruption announces as "dialog" and the user is asked to
  // authorise a shell command with no idea which one.
  const cases: Array<[string, React.ReactElement]> = [
    ["permission", <PermissionCard pending={pendingFrom(fixtures.permission)} queueCount={0} onDecide={() => {}} />],
    ["question", <QuestionCard pending={pendingFrom(fixtures.question)} onDecide={() => {}} />],
    ["plan", <PlanCard pending={pendingFrom(fixtures.plan)} onDecide={() => {}} />]
  ];

  for (const [name, node] of cases) {
    test(`the ${name} card's alertdialog points at its own heading`, () => {
      const { container } = mount(node);
      const dialog = container.querySelector('[role="alertdialog"]')!;
      const labelledby = dialog.getAttribute("aria-labelledby");
      expect(labelledby).toBeTruthy();
      const heading = container.querySelector(`#${CSS.escape(labelledby!)}`);
      expect(heading).not.toBeNull();
      expect(heading!.tagName).toBe("H3");
      expect((heading!.textContent ?? "").trim().length).toBeGreaterThan(0);
    });
  }

  test("the permission card also describes what is being asked", () => {
    const { container } = mount(cases[0][1]);
    const dialog = container.querySelector('[role="alertdialog"]')!;
    const describedby = dialog.getAttribute("aria-describedby")!;
    expect(container.querySelector(`#${CSS.escape(describedby)}`)!.textContent).toBe(
      "Claude needs permission to continue"
    );
  });
});

describe("PermissionCard keyboard still works", () => {
  const pending = pendingFrom(fixtures.permission);

  test("Enter allows once and Escape opens the deny reason", () => {
    const decisions: PermissionDecision[] = [];
    mount(<PermissionCard pending={pending} queueCount={0} onDecide={(d) => decisions.push(d)} />);

    press("Escape");
    expect(screen.getByPlaceholderText("Reason (optional)")).toBeDefined();
    expect(decisions.length).toBe(0);

    // Escape again backs out of the sub-state rather than denying blind.
    fireEvent.keyDown(screen.getByPlaceholderText("Reason (optional)"), { key: "Escape" });
    expect(screen.queryByPlaceholderText("Reason (optional)")).toBeNull();

    // Allow is a plain action button, not a toggle, so it keeps the browser's
    // native Enter activation and the window handler must NOT double-fire.
    act(() => (document.activeElement as HTMLElement | null)?.blur());
    press("Enter");
    expect(decisions.length).toBe(1);
    expect(decisions[0].behavior).toBe("allow");
  });

  test("Enter on the focused Allow button is left to the browser, never doubled", () => {
    const decisions: PermissionDecision[] = [];
    mount(<PermissionCard pending={pending} queueCount={0} onDecide={(d) => decisions.push(d)} />);
    const allow = screen.getByRole("button", { name: /Allow once/ });
    act(() => allow.focus());

    press("Enter");

    // No synthetic click in this environment, so exactly zero decisions proves
    // the window handler stayed out of the way; a real browser contributes the
    // one click. Two decisions here would mean Deny-then-Enter allows the call.
    expect(decisions.length).toBe(0);
  });
});

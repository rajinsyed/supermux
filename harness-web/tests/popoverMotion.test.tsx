import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { CopyProvider } from "../src/ui/CopyContext";
import { MenuItem } from "../src/ui/primitives/MenuList";
import { Popover } from "../src/ui/primitives/Popover";
import { POP_OUT_MS } from "../src/ui/motion";

afterEach(() => {
  cleanup();
  setReducedMotion(false);
});

/**
 * `prefersReducedMotion()` reads `matchMedia` at CALL time, deliberately, so
 * the setting can change mid-session. That is exactly what makes it testable
 * here: the query can be swapped between renders without remounting anything.
 */
function setReducedMotion(reduce: boolean): void {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: (query: string) => ({
      matches: reduce && query.includes("prefers-reduced-motion"),
      media: query,
      addEventListener() {},
      removeEventListener() {},
      addListener() {},
      removeListener() {},
      dispatchEvent: () => false,
      onchange: null
    })
  });
}

function mount() {
  return render(
    <CopyProvider dict={undefined}>
      <Popover label="Menu" trigger={() => <span>open</span>}>
        {(close) => (
          <MenuItem onClick={() => close()} selectable={false}>
            Row
          </MenuItem>
        )}
      </Popover>
    </CopyProvider>
  );
}

/** Runs past the exit hold, so a panel that should be gone genuinely is. */
async function settleExit() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, POP_OUT_MS + 40));
  });
}

describe("a popover leaves as deliberately as it arrives", () => {
  test("closing keeps the panel mounted for its exit, then removes it", async () => {
    // Round 5 unmounted on the same tick as the state change, so a surface that
    // spent 110ms arriving vanished between two frames. Nothing in the DOM said
    // so — which is why this is a test rather than a comment.
    setReducedMotion(false);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);
    expect(container.querySelector(".ui-pop")).not.toBeNull();

    fireEvent.click(trigger);
    const closing = container.querySelector(".ui-pop");
    expect(closing).not.toBeNull();
    expect(closing!.className).toContain("is-closing");

    await settleExit();
    expect(container.querySelector(".ui-pop")).toBeNull();
  });

  test("the closing panel is out of the tree and out of the tab order", async () => {
    // For the ~100ms it survives it is visible, answered, and about to go: a
    // screen reader must not read it and Tab must not land in it.
    setReducedMotion(false);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);
    fireEvent.click(trigger);

    const closing = container.querySelector(".ui-pop")!;
    expect(closing.getAttribute("aria-hidden")).toBe("true");
    expect(closing.hasAttribute("inert")).toBe(true);
    await settleExit();
  });

  test("escape returns focus to the trigger immediately, not after the exit", async () => {
    // A control that is still visible but no longer focusable is where a
    // keyboard user gets stranded. The handover happens before the timer.
    setReducedMotion(false);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);

    act(() => {
      window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });

    expect(document.activeElement).toBe(trigger);
    await settleExit();
  });

  test("with motion off the panel is simply gone — no dead visible surface", async () => {
    // The reduced-motion branch collapses every animation to 0.001ms, so a
    // panel held for another 100ms would sit there visible and inert, which is
    // worse than no animation at all.
    setReducedMotion(true);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);
    expect(container.querySelector(".ui-pop")).not.toBeNull();

    fireEvent.click(trigger);

    // Same tick: no hold, no `is-closing` frame to look at.
    expect(container.querySelector(".ui-pop")).toBeNull();
  });

  test("reopening mid-exit cancels the pending unmount", async () => {
    // The timer from the first close would otherwise fire ~100ms into the
    // SECOND open and tear the panel down under the pointer.
    setReducedMotion(false);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);
    fireEvent.click(trigger);
    fireEvent.click(trigger);

    const pop = container.querySelector(".ui-pop");
    expect(pop).not.toBeNull();
    expect(pop!.className).not.toContain("is-closing");

    await settleExit();
    expect(container.querySelector(".ui-pop")).not.toBeNull();
  });

  test("the surface names its own origin corner in its classes", () => {
    // The CSS derives transform-origin from these; a surface that stopped
    // emitting them would silently fall back to growing from its centre.
    setReducedMotion(false);
    const { container } = mount();
    const trigger = container.querySelector<HTMLButtonElement>(".menu-trigger")!;
    fireEvent.click(trigger);
    const pop = container.querySelector(".ui-pop")!;
    expect(pop.className).toContain("is-top");
    expect(pop.className).toContain("is-end");
  });
});

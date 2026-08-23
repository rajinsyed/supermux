import { afterEach, describe, expect, test } from "bun:test";
import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { useState } from "react";
import { useScrollFollow } from "../src/ui/transcript/useScrollFollow";

afterEach(cleanup);

/**
 * happy-dom does no layout, so the scroller's geometry is scripted: `scrollTop`
 * is a real settable property, and `scrollHeight`/`clientHeight` are defined per
 * node so the hook's "am I at the bottom" arithmetic has something to read.
 * `scrollBy` is defined too, because that is the ONLY way the embedded pane
 * ever scrolls — the native wheel bridge injects it (see
 * SupermuxHarnessWebHostView.flushPendingScroll) rather than dispatching wheel
 * events, which is why the hook cannot rely on gesture events alone.
 */
function scriptGeometry(node: HTMLElement, initialClientHeight: number) {
  let clientHeight = initialClientHeight;
  let height = clientHeight;
  let top = 0;
  const clamp = (value: number) => Math.max(0, Math.min(height - clientHeight, value));
  Object.defineProperty(node, "clientHeight", { get: () => clientHeight, configurable: true });
  Object.defineProperty(node, "scrollHeight", { get: () => height, configurable: true });
  // A real scroller CLAMPS: assigning `scrollTop = scrollHeight` lands at
  // `scrollHeight - clientHeight`, not past the end. The hook pins by exactly
  // that assignment, so a mock that stored the raw value would put the test a
  // whole viewport away from where a browser puts the user.
  Object.defineProperty(node, "scrollTop", {
    get: () => top,
    set: (value: number) => {
      top = clamp(value);
      fireEvent.scroll(node);
    },
    configurable: true
  });
  (node as unknown as { scrollBy(x: number, y: number): void }).scrollBy = (_x, y) => {
    node.scrollTop = top + y;
  };
  (node as unknown as { scrollTo(options: { top: number }): void }).scrollTo = (options) => {
    node.scrollTop = options.top;
  };
  return {
    /** Content arrived: the scroller got taller, exactly as a streaming turn does. */
    grow(by: number) {
      height += by;
    },
    /**
     * The viewport itself changed size — the pill row clearing, the composer
     * shrinking. The browser clamps `scrollTop` to the new maximum, exactly as
     * it does for content shrink, and emits a scroll event for the move.
     */
    resizeViewport(to: number) {
      clientHeight = to;
      const clampedTop = clamp(top);
      if (clampedTop !== top) {
        top = clampedTop;
        fireEvent.scroll(node);
      }
    },
    /** Move without a scroll event, the way geometry lands between frames. */
    silently(value: number) {
      top = clamp(value);
    },
    get height() {
      return height;
    }
  };
}

/**
 * Let the hook's pin run. It is scheduled on `requestAnimationFrame` on
 * purpose — pinning before the browser has laid the new content out reads a
 * stale `scrollHeight` — so a synchronous assertion would test the frame
 * BEFORE the one the user sees.
 */
async function frame() {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 24));
  });
}

function Harness({ onPill }: { onPill?(value: boolean): void }) {
  const [tick, setTick] = useState(0);
  const { ref, contentRef, showPill, scrollToBottom } = useScrollFollow([tick]);
  onPill?.(showPill);
  return (
    <div>
      <div data-testid="scroller" ref={ref}>
        <div ref={contentRef}>content</div>
      </div>
      <button type="button" data-testid="tick" onClick={() => setTick((t) => t + 1)}>
        frame
      </button>
      <button type="button" data-testid="jump" onClick={() => scrollToBottom()}>
        jump
      </button>
      <span data-testid="pill">{showPill ? "pill" : "no-pill"}</span>
    </div>
  );
}

describe("scroll follow survives a streaming turn", () => {
  /**
   * The reported bug, reproduced.
   *
   * Follow used to break only once the reader got more than 44px from the
   * bottom. While content grows every frame, each attempt was re-pinned before
   * it could travel that far, so the scroller snapped back and the pane looked
   * frozen. The gesture here is deliberately SMALLER than that old threshold:
   * intent is intent at 30px.
   */
  test("a small upward scroll during streaming is not undone", () => {
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);

    act(() => {
      getByTestId("jump").click();
    });
    expect(node.scrollTop).toBe(400);

    // The reader nudges up, and the turn keeps streaming under them.
    act(() => {
      (node as unknown as { scrollBy(x: number, y: number): void }).scrollBy(0, -30);
    });
    const parked = node.scrollTop;
    expect(parked).toBe(370);

    for (let i = 0; i < 5; i += 1) {
      act(() => {
        geometry.grow(60);
        getByTestId("tick").click();
      });
    }
    // Still exactly where they left it, through five frames of growth.
    expect(node.scrollTop).toBe(parked);
    expect(getByTestId("pill").textContent).toBe("pill");
  });

  test("a reader who has NOT scrolled is still carried along", async () => {
    // The other half of the contract: breaking follow on intent must not break
    // follow when there was none.
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);

    for (let i = 0; i < 5; i += 1) {
      act(() => {
        geometry.grow(80);
        getByTestId("tick").click();
      });
      await frame();
    }
    expect(node.scrollTop).toBe(geometry.height - 100);
    expect(getByTestId("pill").textContent).toBe("no-pill");
  });

  test("returning to the bottom re-arms follow", async () => {
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);
    act(() => {
      getByTestId("jump").click();
    });

    act(() => {
      (node as unknown as { scrollBy(x: number, y: number): void }).scrollBy(0, -200);
    });
    expect(getByTestId("pill").textContent).toBe("pill");

    act(() => {
      getByTestId("jump").click();
    });
    expect(getByTestId("pill").textContent).toBe("no-pill");

    act(() => {
      geometry.grow(100);
      getByTestId("tick").click();
    });
    await frame();
    expect(node.scrollTop).toBe(geometry.height - 100);
  });

  test("growth alone never raises the pill", () => {
    // A frame that lands before the pin runs leaves the scroller momentarily
    // away from the bottom. Treating that as intent flashed the pill on a
    // transcript nobody had touched.
    const seen: boolean[] = [];
    const { getByTestId } = render(<Harness onPill={(value) => seen.push(value)} />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);

    for (let i = 0; i < 6; i += 1) {
      act(() => {
        geometry.grow(300);
        // The scroll event the browser emits as the content resizes, BEFORE the
        // hook's own pin has run.
        fireEvent.scroll(node);
        getByTestId("tick").click();
      });
    }
    expect(seen.some(Boolean)).toBe(false);
  });

  test("a wheel gesture breaks follow before the scroll even lands", () => {
    // The plain-browser path: wheel fires ahead of the position change, so
    // follow is already off when the next frame's growth would have re-pinned.
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);
    act(() => {
      getByTestId("jump").click();
    });

    act(() => {
      fireEvent.wheel(node, { deltaY: -20 });
    });
    expect(getByTestId("pill").textContent).toBe("pill");

    const parked = node.scrollTop;
    act(() => {
      geometry.grow(200);
      getByTestId("tick").click();
    });
    expect(node.scrollTop).toBe(parked);
  });

  test("a gesture the pin reaches before onScroll does still breaks follow", async () => {
    // Scroll events are ASYNC: during fast streaming the rAF pin routinely runs
    // before the gesture's scroll event is delivered, read `scrollTop` where
    // the gesture left it — and overwrote it. The pin must read the position as
    // the reader's before touching it.
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);
    act(() => {
      getByTestId("jump").click();
    });
    expect(node.scrollTop).toBe(400);

    // The gesture lands silently — no scroll event yet — and a frame of growth
    // schedules the pin before the event would have been delivered.
    geometry.silently(320);
    act(() => {
      geometry.grow(80);
      getByTestId("tick").click();
    });
    await frame();
    expect(node.scrollTop).toBe(320);
    expect(getByTestId("pill").textContent).toBe("pill");
  });

  test("a clamp onto the bottom neither breaks follow nor strands the pill", async () => {
    // Clearing the pill row grows the viewport; the browser clamps `scrollTop`
    // down onto the exact bottom and fires a scroll event. That downward-then-
    // clamped move used to read as "moved up with content kept", breaking
    // follow the instant the reader returned to the bottom and re-mounting the
    // pill they had just dismissed.
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);
    act(() => {
      getByTestId("jump").click();
    });
    expect(getByTestId("pill").textContent).toBe("no-pill");

    // The pill row unmounting returns its height to the scroller.
    act(() => {
      geometry.resizeViewport(120);
    });
    expect(getByTestId("pill").textContent).toBe("no-pill");
    // Still following: the next growth carries the reader along.
    act(() => {
      geometry.grow(100);
      getByTestId("tick").click();
    });
    await frame();
    expect(node.scrollTop).toBe(geometry.height - 120);
  });

  test("content shrinking under a parked reader does not re-arm follow", () => {
    // A turn completing collapses its cards. If the shrink clamps the parked
    // reader onto the new bottom, that is the LAYOUT arriving at them — not
    // them arriving at the bottom — and follow must stay off.
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(900);
    act(() => {
      getByTestId("jump").click();
    });
    act(() => {
      (node as unknown as { scrollBy(x: number, y: number): void }).scrollBy(0, -300);
    });
    expect(getByTestId("pill").textContent).toBe("pill");
    const parked = node.scrollTop;

    // Cards collapse: the content loses enough height that the parked position
    // becomes the new bottom, and the browser clamps + fires scroll.
    act(() => {
      geometry.grow(-(geometry.height - 100 - parked));
      fireEvent.scroll(node);
    });
    // Not re-armed by the clamp: the next growth must NOT drag the reader down.
    act(() => {
      geometry.grow(200);
      getByTestId("tick").click();
    });
    expect(node.scrollTop).toBe(parked);
  });

  test("PageUp breaks follow", () => {
    const { getByTestId } = render(<Harness />);
    const node = getByTestId("scroller");
    const geometry = scriptGeometry(node, 100);
    geometry.grow(400);
    act(() => {
      getByTestId("jump").click();
    });
    act(() => {
      fireEvent.keyDown(node, { key: "PageUp" });
    });
    expect(getByTestId("pill").textContent).toBe("pill");
  });
});

describe("the hook binds to the scroller that is actually on screen", () => {
  /**
   * The view router swaps the whole transcript area, and each branch mounts its
   * OWN scroller. A hook that bound its listeners once left every one of them on
   * a node that had since been detached — which is why the agents view had no
   * working follow, no pill, and no way to notice the reader had scrolled.
   */
  function Swapping() {
    const [which, setWhich] = useState<"a" | "b">("a");
    const { ref, contentRef, showPill } = useScrollFollow([which]);
    return (
      <div>
        {which === "a" ? (
          <div data-testid="a" ref={ref}>
            <div ref={contentRef}>A</div>
          </div>
        ) : (
          <div data-testid="b" ref={ref}>
            <div ref={contentRef}>B</div>
          </div>
        )}
        <button type="button" data-testid="swap" onClick={() => setWhich("b")}>
          swap
        </button>
        <span data-testid="pill">{showPill ? "pill" : "no-pill"}</span>
      </div>
    );
  }

  test("scrolling the view opened SECOND is noticed", () => {
    const { getByTestId } = render(<Swapping />);
    scriptGeometry(getByTestId("a"), 100);
    act(() => {
      getByTestId("swap").click();
    });

    const b = getByTestId("b");
    const geometry = scriptGeometry(b, 100);
    geometry.grow(400);
    act(() => {
      b.scrollTop = 400;
      fireEvent.scroll(b);
    });
    act(() => {
      (b as unknown as { scrollBy(x: number, y: number): void }).scrollBy(0, -120);
    });
    expect(getByTestId("pill").textContent).toBe("pill");
  });
});

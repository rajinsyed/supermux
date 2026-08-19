import { useCallback, useEffect, useRef, useState } from "react";

/** How close to the bottom still counts as "at the bottom". */
const REARM_THRESHOLD = 44;
/**
 * Sub-pixel jitter is not a gesture. Rubber-banding, a scrollbar thumb
 * settling, and a fractional device-pixel ratio all move `scrollTop` by less
 * than this without anybody having asked for it.
 */
const DIRECTION_EPSILON = 2;

export function useScrollFollow(deps: unknown[]) {
  const ref = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const following = useRef(true);
  const [showPill, setShowPill] = useState(false);

  /**
   * The scroller and its content, as STATE rather than only as refs.
   *
   * The view router swaps the whole transcript area — main chat, agent chat,
   * shell, workflow — and each branch mounts its own scroller. A ref alone
   * silently repoints at the new node while the effects that matter (the
   * scroll listener, the ResizeObserver) stay bound to the old, now detached
   * one. That is why an agent view had no working follow, no pill, and no way
   * to tell that the user had taken the scrollbar: every listener was on a node
   * that had left the document. Mirroring the refs into state re-runs those
   * effects on the node actually on screen.
   */
  const [node, setNode] = useState<HTMLDivElement | null>(null);
  const [content, setContent] = useState<HTMLDivElement | null>(null);
  useEffect(() => {
    setNode(ref.current);
    setContent(contentRef.current);
  });

  /** The previous reading, which is what makes a scroll DIRECTIONAL. */
  const lastTop = useRef(0);
  const lastHeight = useRef(0);

  const atBottom = useCallback(() => {
    const target = ref.current;
    if (!target) return true;
    return target.scrollHeight - target.scrollTop - target.clientHeight <= REARM_THRESHOLD;
  }, []);

  /** Pin to the bottom, recording the reading so the pin is not read as intent. */
  const pin = useCallback(() => {
    const target = ref.current;
    if (!target) return;
    // A gesture can land BETWEEN the last pin and this one: scroll events are
    // delivered asynchronously, so during fast streaming the rAF/ResizeObserver
    // pin often runs before `onScroll` ever reads the gesture's position — and
    // overwrites it, which is the swallowed-scroll bug. Read the position here,
    // before touching it: scrollTop below where the last pin left it, while the
    // content did not shrink, is the reader. Growth alone never moves scrollTop.
    const top = target.scrollTop;
    const height = target.scrollHeight;
    // Same clamp guard as `onScroll`: a layout change that grows the viewport
    // clamps `scrollTop` onto the exact bottom, which is not a reader's escape.
    const clamped = height - top - target.clientHeight <= DIRECTION_EPSILON;
    if (top < lastTop.current - DIRECTION_EPSILON && height >= lastHeight.current && !clamped) {
      lastTop.current = top;
      lastHeight.current = height;
      if (following.current) {
        following.current = false;
        setShowPill(true);
      }
      return;
    }
    // Checked at FIRE time, not only where the pin was scheduled: the deps
    // effect reads `following` when it queues its rAF, and a gesture can break
    // follow in the gap before that rAF runs. By then `onScroll` has already
    // recorded the gesture's position, so the direction check above sees
    // nothing — this guard is what stops the queued pin from undoing the break.
    if (!following.current) return;
    target.scrollTop = target.scrollHeight;
    lastTop.current = target.scrollTop;
    lastHeight.current = target.scrollHeight;
  }, []);

  /**
   * The user has taken the scroller. Follow stops IMMEDIATELY — not once they
   * have travelled 44px, which during fast streaming they never can, because
   * every frame of new content re-pins the scroller before the next gesture
   * lands. That is the scroll lock: the reader drags, the content grows, the
   * position is restored, and the pane looks broken.
   */
  const breakFollow = useCallback(() => {
    if (!following.current) return;
    following.current = false;
    setShowPill(true);
  }, []);

  const scrollToBottom = useCallback((smooth = false) => {
    const target = ref.current;
    if (!target) return;
    following.current = true;
    setShowPill(false);
    target.scrollTo({ top: target.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }, []);

  /**
   * Virtual-window anchor transaction. Row replacement changes scrollHeight and
   * then restores the measured row under the reader; updating all three readings
   * together prevents that programmatic correction from masquerading as a wheel
   * gesture in the next scroll event.
   */
  const correctAnchor = useCallback((delta: number) => {
    const target = ref.current;
    if (!target || !Number.isFinite(delta) || Math.abs(delta) < 0.5) return;
    target.scrollTop += delta;
    lastTop.current = target.scrollTop;
    lastHeight.current = target.scrollHeight;
  }, []);

  /**
   * A freshly mounted scroller starts at the bottom, following.
   *
   * Opening an agent view is a new place, not a continuation of wherever the
   * reader had scrolled the main chat to; carrying the old `following` across
   * would open a live agent's conversation parked at its top with no pill.
   */
  useEffect(() => {
    if (!node) return;
    following.current = true;
    setShowPill(false);
    lastTop.current = node.scrollTop;
    lastHeight.current = node.scrollHeight;
    const frame = requestAnimationFrame(pin);
    return () => cancelAnimationFrame(frame);
  }, [node, pin]);

  useEffect(() => {
    if (!node) return;
    const onScroll = () => {
      const top = node.scrollTop;
      const height = node.scrollHeight;
      const movedUp = top < lastTop.current - DIRECTION_EPSILON;
      const movedDown = top > lastTop.current + DIRECTION_EPSILON;
      // Content that SHRANK (a card folding, a window that lost some) can drag
      // scrollTop down on its own; that is the layout moving, not the reader.
      const lastHeightBefore = lastHeight.current;
      const kept = height >= lastHeightBefore;
      lastTop.current = top;
      lastHeight.current = height;
      const distFromBottom = height - top - node.clientHeight;
      if (movedUp && kept && distFromBottom > DIRECTION_EPSILON) {
        // The pane is a WKWebView whose wheel gestures arrive as an injected
        // `scrollBy()` rather than as real wheel events, so direction read off
        // the scroll position is the ONLY intent signal that exists there. It
        // is deliberately not gated on the 44px threshold: a reader who nudges
        // upward while a turn streams has already said what they want.
        //
        // The distance guard is not decoration. Clearing the pill grows the
        // scroller's `clientHeight`, the browser clamps `scrollTop` down to
        // the new maximum, and that clamp reads as "moved up with content
        // kept" — which re-broke follow the instant the reader returned to
        // the bottom, re-mounted the pill, and left it stuck. A clamp lands
        // EXACTLY on the bottom; a reader escaping upward never does.
        breakFollow();
        return;
      }
      if (atBottom()) {
        // Landing at the bottom re-arms follow only when the READER travelled
        // there. A turn completing collapses its cards, the content shrinks
        // below where the reader had parked, and the browser clamps scrollTop
        // to the new maximum — which reads as "at the bottom" without anybody
        // having scrolled down. Re-arming on that clamp is how a reader who
        // had taken the scroller got yanked back into follow every turn.
        if (following.current || movedDown) {
          following.current = true;
          setShowPill(false);
        }
        return;
      }
      // Not at the bottom, but the reader did not move UP to get here: the
      // content grew and the pin that follows it has not run yet. Breaking on
      // that flashed the pill for one frame every time a large block mounted,
      // on a transcript nobody had touched. Growth is not intent; only the
      // reader is.
      if (height > lastHeightBefore) return;
      breakFollow();
    };
    node.addEventListener("scroll", onScroll, { passive: true });
    return () => node.removeEventListener("scroll", onScroll);
  }, [atBottom, breakFollow, node]);

  /**
   * Intent, ahead of the scroll it causes.
   *
   * In a plain browser these fire BEFORE the position moves, so follow is
   * already off by the time the content's next growth would have re-pinned it.
   * They are additive to the direction rule above, not a replacement for it —
   * the embedded pane produces none of them.
   */
  useEffect(() => {
    if (!node) return;
    const onWheel = (event: WheelEvent) => {
      if (event.deltaY < 0) breakFollow();
    };
    const onTouch = () => breakFollow();
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "PageUp" || event.key === "ArrowUp" || event.key === "Home") {
        breakFollow();
      }
    };
    node.addEventListener("wheel", onWheel, { passive: true });
    node.addEventListener("touchmove", onTouch, { passive: true });
    node.addEventListener("keydown", onKeyDown);
    return () => {
      node.removeEventListener("wheel", onWheel);
      node.removeEventListener("touchmove", onTouch);
      node.removeEventListener("keydown", onKeyDown);
    };
  }, [breakFollow, node]);

  useEffect(() => {
    if (!following.current) return;
    if (!ref.current) return;
    const frame = requestAnimationFrame(pin);
    return () => cancelAnimationFrame(frame);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, node, pin]);

  // A permission/question card grows AFTER the effect above runs (its preview,
  // diff, or option list mounts a frame later), leaving the primary button
  // clipped behind the dock with no pill to explain it. Following the content's
  // own size keeps the bottom pinned through that growth, and re-evaluates the
  // pill when the user is not following.
  useEffect(() => {
    if (!content || !node || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(() => {
      if (following.current) {
        pin();
        return;
      }
      setShowPill(!atBottom());
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, [atBottom, content, node, pin]);

  return {
    ref,
    contentRef,
    showPill,
    scrollToBottom,
    correctAnchor,
    isFollowing: following
  };
}

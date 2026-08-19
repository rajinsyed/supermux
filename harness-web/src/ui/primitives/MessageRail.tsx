import { useCallback, useEffect, useMemo, useRef, type RefObject } from "react";
import type { Turn } from "../../model/types";
import { useCopy } from "../CopyContext";

/**
 * The message rail — Synara's message trail, at the pane's MIDDLE-LEFT edge.
 *
 * ROUND 5 put the rail here and made it a map rather than a second scrollbar:
 * short, vertically centred, at the LEFT edge (the scrollbar owns the right),
 * one tick per turn, a preview on hover, a jump on click. All of that stands.
 *
 * ROUND 7 replaces how it BEHAVES under the pointer, from Synara's
 * `MessageTrail` (apps/web/src/components/chat/MessageTrail.tsx and its
 * unit-tested `messageTrail.logic.ts`). Two ideas, and they are separable:
 *
 *  1. WIDTH is continuous — a macOS-Dock magnification. The tick nearest the
 *     pointer grows to its full length and its neighbours taper off on a
 *     Gaussian, so the rail deforms smoothly under the cursor instead of one
 *     tick snapping wide while the rest sit still. This is what makes a column
 *     of 2px marks feel like an instrument rather than a legend.
 *
 *  2. OPACITY is discrete — never a gradient. Synara is explicit about this
 *     ("opacity is a fixed per-state colour — it never follows the cursor"),
 *     and it is the reason the effect reads as depth rather than as a glow: the
 *     size says where the pointer is, the tone says where the READER is, and
 *     the two never blur into each other. Three tiers, matching theirs: rest,
 *     visible-in-viewport, and the reading anchor, plus full ink on the one
 *     tick under the pointer.
 *
 * The tiers are in rail.css keyed off `data-` attributes, not written from JS.
 * Only WIDTH — the one genuinely continuous value — is written imperatively.
 * That split is what keeps the hot path honest: a pointer move touches
 * `style.width` on N elements inside a single coalesced rAF and nothing else;
 * no React state, no re-render of the rail or the transcript.
 *
 * Why the visible tier does not reintroduce the round-5 bug. Round 5's
 * complaint was that the OLD rail lit every turn overlapping the viewport, so a
 * pane showing four short turns brightened four ticks and said nothing about
 * where the reader was. That was one tone doing two jobs. Here the anchor is a
 * distinct, brighter tier and there is still exactly one of it; the mid tone
 * says "this turn is on screen", which is a different fact and is legible as a
 * different fact. Synara ships all three for the same reason.
 */

/** Below this the rail is noise: three ticks map nothing. */
const MIN_TURNS = 3;

/**
 * Synara's tick geometry, unchanged.
 *
 * `MessageTrail.tsx` lines 61–69: 2px tall, 6px at rest, 30px magnified, on a
 * 10px centre-to-centre pitch. The base→max gap is deliberately wide — that
 * ratio is what reads as a real Dock magnification rather than a nudge — and
 * the pitch is deliberately tight, because the ticks grow SIDEWAYS and so a
 * close stack never limits how far the focal tick can travel.
 */
const TICK_HEIGHT = 2;
const TICK_BASE_W = 6;
const TICK_MAX_W = 30;
const TICK_PITCH = 10;

/**
 * `computeSigma` (messageTrail.logic.ts): `clamp(spacing*1.5, min(spacing*2, 8), 22)`.
 * Tying the focus radius to the pitch keeps it at roughly 1.5 ticks whether the
 * rail is sparse or dense. At our fixed 10px pitch it resolves to 15.
 */
const SIGMA = Math.min(Math.max(TICK_PITCH * 1.5, Math.min(TICK_PITCH * 2, 8)), 22);

/**
 * Their `TOOLTIP_ESTIMATED_H_PX` — the height assumed for the clamp on the
 * first frame, before the card has been laid out and can report its own.
 */
const PREVIEW_ESTIMATED_H = 56;

type Preview = { user: string; body: string };

export function MessageRail({
  turns,
  scrollRef
}: {
  turns: Turn[];
  scrollRef: RefObject<HTMLDivElement | null>;
}) {
  const copy = useCopy();
  const rail = useRef<HTMLDivElement>(null);
  const viewport = useRef<HTMLDivElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const previewBox = useRef<HTMLDivElement>(null);
  const previewUser = useRef<HTMLDivElement>(null);
  const previewBody = useRef<HTMLDivElement>(null);

  const enabled = turns.length >= MIN_TURNS;

  /**
   * Preview strings are derived ONCE per turn list, not per pointer move: the
   * hover path writes `textContent` from this array, so moving across the rail
   * never re-runs `previewText` (which walks a turn's blocks) and never renders.
   */
  const previews = useMemo<Preview[]>(
    () =>
      turns.map((turn) => ({
        user: normalize(turn.userText) || copy("supermux.harness.turn.turnNumber", { seq: turn.seq }),
        body: normalize(previewText(turn))
      })),
    [turns, copy]
  );

  // --- hot-path refs: read inside rAF, never render ------------------------
  const centersRef = useRef<number[]>([]);
  const pointerYRef = useRef<number | null>(null);
  const focusedRef = useRef(-1);
  const frameRef = useRef<number | null>(null);
  const previewsRef = useRef(previews);
  const reducedMotionRef = useRef(false);
  useEffect(() => {
    previewsRef.current = previews;
  }, [previews]);

  useEffect(() => {
    reducedMotionRef.current =
      typeof window !== "undefined" && typeof window.matchMedia === "function"
        ? window.matchMedia("(prefers-reduced-motion: reduce)").matches
        : false;
  }, []);

  const ticksOf = useCallback(
    () => Array.from(track.current?.querySelectorAll<HTMLElement>("[data-turn-tick]") ?? []),
    []
  );

  /**
   * Tick centres in the rail's own content space, measured once per layout.
   * The pointer path reads this array instead of the layout tree, so a move
   * costs arithmetic rather than N forced reflows.
   */
  const measure = useCallback(() => {
    centersRef.current = ticksOf().map((tick) => tick.offsetTop + tick.offsetHeight / 2);
  }, [ticksOf]);

  const hidePreview = useCallback(() => {
    focusedRef.current = -1;
    const box = previewBox.current;
    if (box) box.style.visibility = "hidden";
  }, []);

  /** Every tick back to its resting length. Tone is CSS's; this writes width only. */
  const rest = useCallback(() => {
    for (const tick of ticksOf()) {
      tick.style.width = `${TICK_BASE_W}px`;
      tick.dataset.focus = "false";
    }
    hidePreview();
  }, [ticksOf, hidePreview]);

  /**
   * The preview rides beside the FOCUSED tick rather than at the rail's fixed
   * centre, so the card always points at the mark that summoned it. The ticks
   * live in a scrolling viewport and the card is a non-scrolling sibling, so
   * the centre is mapped out of content space (minus `scrollTop`, plus where
   * the viewport sits inside the rail) and then clamped so a card summoned at
   * either end stays fully on the rail (their `clampTooltipTop`).
   */
  const showPreview = useCallback((index: number) => {
    const box = previewBox.current;
    const view = viewport.current;
    const entry = previewsRef.current[index];
    if (!box || !view || !entry) return;
    if (focusedRef.current !== index) {
      focusedRef.current = index;
      if (previewUser.current) previewUser.current.textContent = entry.user;
      const body = previewBody.current;
      if (body) {
        body.textContent = entry.body;
        body.style.display = entry.body ? "" : "none";
      }
    }
    const railHeight = rail.current?.clientHeight ?? 0;
    const height = box.offsetHeight || PREVIEW_ESTIMATED_H;
    const center = centersRef.current[index] ?? 0;
    const y = center - view.scrollTop + view.offsetTop;
    const half = height / 2 + 4;
    box.style.top = `${Math.min(Math.max(y, half), Math.max(half, railHeight - half))}px`;
    box.style.visibility = "visible";
  }, []);

  /** Index of the tick nearest a content-space Y (their `computeFocusedIndex`). */
  const nearest = useCallback((y: number): number => {
    const centers = centersRef.current;
    if (centers.length === 0) return -1;
    let best = 0;
    let bestDistance = Infinity;
    for (let i = 0; i < centers.length; i += 1) {
      const distance = Math.abs(centers[i] - y);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }, []);

  /**
   * One coalesced magnification frame: `w = base + (max - base) * e^(-d²/2σ²)`
   * (their `computeGaussianWeights` × `computeTickStyles`). Under reduced
   * motion the focal tick jumps to full length with no falloff on its
   * neighbours — the information survives, the morphing does not.
   */
  const frame = useCallback(() => {
    frameRef.current = null;
    const view = viewport.current;
    const pointerY = pointerYRef.current;
    if (view === null || pointerY === null) {
      rest();
      return;
    }
    const y = pointerY + view.scrollTop;
    const ticks = ticksOf();
    const centers = centersRef.current;
    const focused = nearest(y);
    const twoSigmaSq = 2 * SIGMA * SIGMA;
    for (let i = 0; i < ticks.length; i += 1) {
      const distance = (centers[i] ?? 0) - y;
      const weight = reducedMotionRef.current
        ? i === focused
          ? 1
          : 0
        : Math.exp(-(distance * distance) / twoSigmaSq);
      ticks[i].style.width = `${TICK_BASE_W + (TICK_MAX_W - TICK_BASE_W) * weight}px`;
      ticks[i].dataset.focus = i === focused ? "true" : "false";
    }
    if (focused >= 0) showPreview(focused);
  }, [ticksOf, nearest, rest, showPreview]);

  const schedule = useCallback(() => {
    if (frameRef.current === null) frameRef.current = requestAnimationFrame(frame);
  }, [frame]);

  const cancel = useCallback(() => {
    if (frameRef.current !== null) {
      cancelAnimationFrame(frameRef.current);
      frameRef.current = null;
    }
  }, []);

  /**
   * Reading position, recomputed on scroll and resize only.
   *
   * The ANCHOR is the turn owning the viewport's CENTRE — exactly one, written
   * straight to `dataset` so a scroll never re-renders the transcript. The same
   * pass marks every turn overlapping the viewport as visible, which is a
   * cheaper fact from measurements it already has.
   */
  useEffect(() => {
    const scroller = scrollRef.current;
    if (!scroller || !enabled) return;
    const update = () => {
      const middle = scroller.scrollTop + scroller.clientHeight / 2;
      const viewTop = scroller.scrollTop;
      const viewBottom = viewTop + scroller.clientHeight;
      let best: HTMLElement | undefined;
      let bestDistance = Infinity;
      for (const tick of ticksOf()) {
        tick.dataset.active = "false";
        const target = scroller.querySelector<HTMLElement>(
          `[data-turn-id="${CSS.escape(tick.dataset.turnTick ?? "")}"]`
        );
        if (!target) {
          tick.dataset.visible = "false";
          continue;
        }
        const top = target.offsetTop;
        const bottom = top + target.offsetHeight;
        tick.dataset.visible = top < viewBottom && bottom > viewTop ? "true" : "false";
        // Inside the turn wins outright; otherwise the nearest edge, so a gap
        // between turns still lights the one the reader just left.
        const distance =
          middle >= top && middle <= bottom
            ? 0
            : Math.min(Math.abs(middle - top), Math.abs(middle - bottom));
        if (distance < bestDistance) {
          bestDistance = distance;
          best = tick;
        }
      }
      if (best) best.dataset.active = "true";
    };
    update();
    scroller.addEventListener("scroll", update, { passive: true });
    const observer =
      typeof ResizeObserver === "undefined" ? undefined : new ResizeObserver(update);
    observer?.observe(scroller);
    return () => {
      scroller.removeEventListener("scroll", update);
      observer?.disconnect();
    };
  }, [scrollRef, turns.length, enabled, ticksOf]);

  // Re-measure and reset whenever the tick count changes.
  useEffect(() => {
    if (!enabled) return;
    measure();
    rest();
  }, [turns.length, enabled, measure, rest]);

  // A stray in-flight frame must not outlive the rail.
  useEffect(() => cancel, [cancel]);

  const goTo = useCallback(
    (turnId: string) => {
      const scroller = scrollRef.current;
      const target = scroller?.querySelector<HTMLElement>(`[data-turn-id="${CSS.escape(turnId)}"]`);
      if (!scroller || !target) return;
      scroller.scrollTo({ top: Math.max(0, target.offsetTop - 24), behavior: "smooth" });
    },
    [scrollRef]
  );

  if (!enabled) return null;

  const onPointer = (event: React.PointerEvent<HTMLDivElement>) => {
    if (event.pointerType === "touch") return;
    const view = viewport.current;
    if (!view) return;
    pointerYRef.current = event.clientY - view.getBoundingClientRect().top;
    schedule();
  };

  return (
    <div className="msg-rail" ref={rail} aria-label={copy("supermux.harness.a11y.timeline")}>
      <div
        className="msg-rail-viewport"
        ref={viewport}
        onPointerEnter={onPointer}
        onPointerMove={onPointer}
        onPointerLeave={(event) => {
          if (event.pointerType === "touch") return;
          pointerYRef.current = null;
          cancel();
          rest();
        }}
        onScroll={() => {
          if (pointerYRef.current !== null) schedule();
        }}
        // Synara's big hit area: a 2px mark is not a click target, so the whole
        // rail column is one, resolving to the nearest tick. The ticks below
        // carry their own handler for assistive activation, and `event.target`
        // is how the two never both fire on the same click.
        onClick={(event) => {
          if (event.target !== event.currentTarget && (event.target as HTMLElement).dataset.turnTick)
            return;
          const view = viewport.current;
          if (!view) return;
          const y = event.clientY - view.getBoundingClientRect().top + view.scrollTop;
          const index = nearest(y);
          const turn = turns[index];
          if (turn) goTo(turn.id);
        }}
      >
        <div className="msg-rail-ticks" ref={track}>
          {turns.map((turn) => (
            <button
              key={turn.id}
              type="button"
              // Pointer-only affordance (see the @media (pointer: fine) rule in
              // rail.css): it must not put twenty-four invisible stops ahead of
              // the composer in the tab order. The turns themselves are reachable
              // by scrolling, and the transcript is a labelled `log` region.
              tabIndex={-1}
              className={`msg-rail-tick is-${turn.state}`}
              data-turn-tick={turn.id}
              onClick={() => goTo(turn.id)}
              aria-label={
                turn.userText?.slice(0, 60) ??
                copy("supermux.harness.turn.turnNumber", { seq: turn.seq })
              }
            />
          ))}
        </div>
      </div>
      {/* Always mounted, hidden by `visibility`: the hover path writes its text
          through refs rather than through state, so summoning it must not be a
          mount. `role="presentation"` because every string in it is already the
          label of the tick that raises it. */}
      <div className="msg-rail-preview" ref={previewBox} role="presentation">
        <div className="msg-rail-preview-user" ref={previewUser} />
        <div className="msg-rail-preview-body" ref={previewBody} />
      </div>
    </div>
  );
}

/**
 * Collapse whitespace for the preview card (their `normalizePreview`).
 *
 * The card is a two- and three-line clamp, and a prompt pasted with newlines or
 * a markdown list in the reply spent those lines on blank runs — the clamp then
 * cut the text off having shown almost none of it. Flattening to single spaces
 * is what makes the clamp count WORDS.
 */
function normalize(text: string | undefined): string {
  return text ? text.replace(/\s+/g, " ").trim() : "";
}

function previewText(turn: Turn): string {
  for (let i = turn.blocks.length - 1; i >= 0; i -= 1) {
    const block = turn.blocks[i];
    if (block.kind === "text" && block.text.trim().length > 0) return block.text.slice(0, 200);
  }
  return turn.result?.text?.slice(0, 200) ?? "";
}

export const RAIL_TICK_GEOMETRY = {
  height: TICK_HEIGHT,
  base: TICK_BASE_W,
  max: TICK_MAX_W,
  pitch: TICK_PITCH,
  sigma: SIGMA
};

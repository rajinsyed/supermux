/** Read at call time, not module load: the setting can change mid-session. */
export function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/**
 * The pane's motion vocabulary, in ONE place.
 *
 * Round 5's menus had a single 110ms fade and nothing else — no exit at all, so
 * every popover in the pane vanished between two frames while it had spent a
 * tenth of a second arriving. That asymmetry is most of why the chrome read as
 * "no animations or good taste whatsoever": an interface that appears smoothly
 * and disappears instantly does not feel built, it feels like a `display: none`
 * toggle wearing a transition.
 *
 * Two durations and one curve. `POP_IN` is the entrance every floating surface
 * runs; `POP_OUT` is deliberately shorter, because a panel on its way out is
 * already answered and lingering reads as lag rather than as polish. The curve
 * is the exponential ease-out declared as `--ease-out` in base.css
 * (cubic-bezier(0.16, 1, 0.3, 1)) — most of the travel happens in the first
 * third, which is what makes a surface look like it SNAPS into place rather than
 * drifting there.
 *
 * These are kept in step with `styles/menu.css` by tests/round6.test.ts, which
 * reads both: a duration that disagrees with its keyframe unmounts a panel
 * mid-animation, which looks exactly like the instant disappearance this
 * replaces.
 */
export const POP_IN_MS = 150;
export const POP_OUT_MS = 100;

/**
 * How long to keep a closing surface mounted.
 *
 * Zero with motion off — the reduced-motion rule collapses every animation to
 * 0.001ms, so a surface held for another 100ms would simply sit there, visible
 * and inert, which is worse than no animation at all.
 */
export function popoverExitDelay(): number {
  return prefersReducedMotion() ? 0 : POP_OUT_MS;
}

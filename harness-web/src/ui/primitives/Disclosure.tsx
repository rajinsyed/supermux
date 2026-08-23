import { useEffect, useRef, useState, type ReactNode } from "react";
import { prefersReducedMotion } from "../motion";

const DURATION_MS = 200;
const FALLBACK_MS = 250;

/**
 * A disclosure that animates between 0 and its natural height.
 *
 * Collapsing a 180px tool card in a single frame throws away the reader's scroll
 * anchor under the cursor, and on a transcript this dense that happens on every
 * click. The measure is a double-rAF — one frame to lay the content out, one to
 * commit the start value so the browser has two distinct heights to interpolate
 * — with `overflow: hidden` and the explicit height applied ONLY while animating
 * so an open body can still size itself and overflow (sticky heads, popovers).
 * `transitionend` finishes the animation; a timeout covers the case where the
 * two heights are equal and no transition ever fires.
 *
 * By default the content stays mounted for the duration of the closing
 * animation, then unmounts — collapsed bodies cost nothing at rest.
 * `keepMounted` hides the closed body with `display: none` instead: the React
 * subtree survives, so a drill-in transcript, an expanded log strip, or a
 * scrolled position inside the body is exactly where the reader left it when
 * the disclosure reopens. Use it wherever the body holds state worth keeping.
 */
export function Disclosure({
  open,
  className,
  keepMounted = false,
  children
}: {
  open: boolean;
  className?: string;
  keepMounted?: boolean;
  children: ReactNode;
}) {
  const [mounted, setMounted] = useState(open);
  const node = useRef<HTMLDivElement>(null);
  const previous = useRef(open);

  useEffect(() => {
    if (open) setMounted(true);
  }, [open]);

  useEffect(() => {
    const element = node.current;
    const was = previous.current;
    if (was === open) return;
    // Opening mounts (or un-hides) the content in this same commit, so the very
    // first pass may see no node yet — or, with `keepMounted`, a node that is
    // still `display: none` and measures 0. Leaving `previous` alone lets the
    // next pass — which has a laid-out node — run the animation, instead of
    // silently skipping the open direction.
    if (!element && open) return;
    if (keepMounted && open && !mounted) return;
    previous.current = open;
    if (!element || prefersReducedMotion()) {
      if (!open) setMounted(false);
      return;
    }

    const target = open ? element.scrollHeight : 0;
    element.style.overflow = "hidden";
    element.style.height = `${open ? 0 : element.scrollHeight}px`;

    let timer = 0;
    const settle = () => {
      element.style.height = "";
      element.style.overflow = "";
      element.style.transition = "";
      element.removeEventListener("transitionend", onEnd);
      if (timer) window.clearTimeout(timer);
      if (!open) setMounted(false);
    };
    const onEnd = (event: TransitionEvent) => {
      if (event.propertyName === "height" && event.target === element) settle();
    };
    element.addEventListener("transitionend", onEnd);

    const frame = requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        element.style.transition = `height ${DURATION_MS}ms var(--ease)`;
        element.style.height = `${target}px`;
      });
    });
    timer = window.setTimeout(settle, DURATION_MS + FALLBACK_MS);

    return () => {
      cancelAnimationFrame(frame);
      settle();
    };
    // `mounted` is a dependency because opening mounts the content one commit
    // later than the prop change; without it the open direction never animates.
  }, [open, mounted, keepMounted]);

  if (!mounted && !keepMounted) return null;
  return (
    <div
      className={className}
      ref={node}
      style={!mounted && keepMounted ? { display: "none" } : undefined}
    >
      {children}
    </div>
  );
}

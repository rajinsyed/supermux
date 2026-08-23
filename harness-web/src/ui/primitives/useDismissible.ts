import { useEffect, useRef } from "react";

interface Entry {
  scope: HTMLElement;
  close(): void;
}

/**
 * Every disclosure that Escape can close, so all of them close the same way.
 *
 * The pane grew three of these independently — the Bash card's output tail, the
 * workflow card's per-agent drill-in, the tasks strip's — and only the first
 * ever handled Escape. Opening the other two and pressing Escape did nothing,
 * or worse, fell through to the composer and interrupted the turn the reader was
 * inspecting. Modal and PermissionCard already promise "Escape closes the
 * topmost thing"; this is the same promise for the inline disclosures.
 */
const stack: Entry[] = [];

/** How deep an element sits, so the INNERMOST open thing closes first. */
function depthOf(node: HTMLElement): number {
  let depth = 0;
  for (let at: HTMLElement | null = node; at; at = at.parentElement) depth += 1;
  return depth;
}

function onKeyDown(event: KeyboardEvent): void {
  if (event.key !== "Escape" || event.defaultPrevented) return;
  const active = document.activeElement;
  if (!(active instanceof HTMLElement)) return;
  /**
   * Scoped to where focus actually IS, deliberately. A global "Escape closes the
   * newest disclosure" would steal the key from the composer for as long as any
   * drill-in was open anywhere in the pane, and Escape-to-interrupt is the one
   * binding a user arriving from the CLI relies on most. Focus inside the
   * disclosure means the reader is in it; focus in the composer means they are
   * not, and the key stays theirs.
   *
   * Depth, not registration order, breaks ties: a drill-in opened inside another
   * drill-in must close inner-first however the two happened to mount.
   */
  let best: Entry | undefined;
  let bestDepth = -1;
  for (const entry of stack) {
    if (!entry.scope.isConnected || !entry.scope.contains(active)) continue;
    const depth = depthOf(entry.scope);
    if (depth > bestDepth) {
      best = entry;
      bestDepth = depth;
    }
  }
  if (!best) return;
  event.preventDefault();
  event.stopPropagation();
  best.close();
}

/**
 * Make an open disclosure Escape-closable.
 *
 * Returns the ref for the element that BOUNDS it — the card row or strip that
 * holds both the toggle button and the body, since focus is usually on the
 * toggle rather than inside the body it opened.
 */
export function useDismissible(
  open: boolean,
  close: () => void
): React.RefObject<HTMLElement | null> {
  const scope = useRef<HTMLElement | null>(null);
  // Read through a ref so re-registering is not required every time the
  // consumer re-creates its close callback.
  const latest = useRef(close);
  latest.current = close;

  useEffect(() => {
    const node = scope.current;
    if (!open || !node) return;
    const entry: Entry = { scope: node, close: () => latest.current() };
    if (stack.length === 0) window.addEventListener("keydown", onKeyDown, true);
    stack.push(entry);
    return () => {
      const at = stack.indexOf(entry);
      if (at >= 0) stack.splice(at, 1);
      if (stack.length === 0) window.removeEventListener("keydown", onKeyDown, true);
    };
  }, [open]);

  return scope;
}

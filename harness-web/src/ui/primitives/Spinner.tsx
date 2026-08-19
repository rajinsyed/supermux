/**
 * The pane's working marks.
 *
 * The three pulsing dots are gone. They were a placeholder standing in for a
 * designed state: three elements animating opacity to say "something is
 * happening" at the resolution of a dial-up modem, carrying no information, so
 * the row beside them had to spell out what was happening anyway. Every one is
 * now a SHIMMER — a bright band sweeping left to right — and where the mark sits
 * beside a label, the label shimmers with it (the sibling rules in cards.css,
 * agents.css and workflow.css), so the animation is on the words that already
 * say what is happening rather than beside them.
 *
 * The exported names and prop signatures are unchanged on purpose: TurnView, the
 * agents dock, the agent rows and the workflow rows consume these, and swapping
 * the internals is how the new visuals reach surfaces this change does not
 * touch.
 */

/**
 * The determinate-looking spinner, still a ring: it marks a request in flight
 * (a model catalog load, a workflow header) rather than a stream of work
 * arriving, and a ring is the honest shape for "waiting on one answer".
 */
export function Spinner({ size = 12, className }: { size?: number; className?: string }) {
  return (
    <span
      className={`spinner${className ? ` ${className}` : ""}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    />
  );
}

/**
 * The streaming mark, in the transcript: a slim sweeping sliver on the turn's
 * live row. Its sibling label ("Working for 12s") shimmers in step with it.
 */
export function WorkingDots({ className }: { className?: string }) {
  return (
    <span className={`working-dots${className ? ` ${className}` : ""}`} aria-hidden="true">
      <i className="sheen-bar" />
    </span>
  );
}

/**
 * The running mark on a row — the agents dock, an inline agent, a workflow. Same
 * sliver at row scale, so one glance across the dock and the transcript reads as
 * one system rather than two different animations for the same fact.
 */
export function WorkingGlyph({ className }: { className?: string }) {
  return (
    <span className={`dock-glyph${className ? ` ${className}` : ""}`} aria-hidden="true">
      <i className="sheen-bar" />
    </span>
  );
}

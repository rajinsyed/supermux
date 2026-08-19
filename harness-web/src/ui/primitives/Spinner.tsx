/**
 * The pane's working marks — three of them, and the differences are the point.
 *
 * Round 5 collapsed every loading state onto ONE sliver: the turn's "Working for
 * 54s", a running Workflow row, and a tool call in flight all wore the same
 * dash. That is honest about nothing — a reader glancing at the pane could not
 * tell "the model is thinking" from "this one shell command is running" from
 * "an agent is off doing work somewhere". Round 6 splits them by MOTION, so the
 * kind of work is legible before a single word is read:
 *
 *   • ORBIT (`Spinner`) — a dot travelling a closed ring. ONE request is in
 *     flight and the pane is waiting on its answer: a tool call, a task-output
 *     poll, a model-catalog fetch, a rewind preview. A closed circuit with a
 *     travelling head is the honest shape for "waiting on one thing".
 *
 *   • PULSE (`WorkingDots`) — no glyph at all. The turn-level state is ambient
 *     and its own label already says everything ("Working for 54s"), so the
 *     animation lands on the WORDS (the sheen sweep in cards.css, keyed off
 *     this element's presence) with a soft accent tick keeping time after them.
 *
 *   • BREATH (`WorkingGlyph`) — a pip swelling and fading, slowly. Delegated
 *     work: a subagent, a workflow, a background shell. It is long-lived and
 *     nothing is being waited on right now, so it gets the calmest motion in
 *     the pane and the row's name sheens at a slower tempo than the turn's.
 *
 * Every one is transform/opacity only and honours prefers-reduced-motion.
 *
 * The exported names and prop signatures are unchanged on purpose: TurnView, the
 * agents dock, the agent rows, the workflow rows, the model menu and the tool
 * cards consume these, and swapping the internals is how the new visuals reach
 * surfaces this change does not touch.
 */

/**
 * The orbit: a dot travelling a faint ring, accent-coloured.
 *
 * Everything is derived from `--orbit-size` so one element is crisp from 8px (a
 * status badge) to 14px (a view header) without a second rule per call site —
 * a fixed 1.5px ring reads as a heavy blob at 8px and a hairline at 14px.
 */
export function Spinner({ size = 12, className }: { size?: number; className?: string }) {
  return (
    <span
      className={`orbit${className ? ` ${className}` : ""}`}
      style={{ width: size, height: size, ["--orbit-size" as string]: `${size}px` }}
      aria-hidden="true"
    />
  );
}

/**
 * The turn's streaming mark. It draws NOTHING: the live row's own label carries
 * the animation (the `.turn-live .working-dots + .turn-live-label` sheen), and
 * this element is the anchor that rule selects on. Rendering a glyph here is
 * what made the turn state indistinguishable from a running tool row.
 */
export function WorkingDots({ className }: { className?: string }) {
  return (
    <span className={`working-dots${className ? ` ${className}` : ""}`} aria-hidden="true" />
  );
}

/**
 * The running mark on a delegated-work row — the agents dock, an inline agent,
 * a workflow. A slow breath, so one glance across the dock and the transcript
 * separates "an agent is alive" from "the pane is waiting on a call".
 */
export function WorkingGlyph({ className }: { className?: string }) {
  return (
    <span className={`dock-glyph${className ? ` ${className}` : ""}`} aria-hidden="true">
      <i className="breathe-pip" />
    </span>
  );
}

import type { ReactNode } from "react";

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
 *     and its own label already says everything ("Working for 54s"), so those
 *     words carry a compositor-only opacity/transform pulse.
 *
 *   • GRID (`WorkingGlyph`) — a 3×3 pixel grid. Delegated work: a subagent's
 *     comet laps the grid's perimeter (`orbit`), a workflow's chevron
 *     wavefront drives right (`drive`), so even the two kinds of delegation
 *     stay distinct. The row name breathes at a slower tempo than the turn's.
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
 * The turn's streaming mark has no abstract glyph. It wraps the status words so
 * those words can carry a compositor-only pulse. The empty slot is retained for
 * isolated callers and keeps the primitive's DOM contract observable without
 * bringing back a stack of decorative dots.
 */
export function WorkingDots({
  className,
  children
}: {
  className?: string;
  children?: ReactNode;
}) {
  return (
    <span
      className={`working-dots${className ? ` ${className}` : ""}`}
      aria-hidden={children === undefined ? true : undefined}
    >
      {children ?? <span className="working-status-slot" />}
    </span>
  );
}

/**
 * The delegated-work marks: a 3×3 pixel grid, after the reference loader the
 * round-6 review supplied. The round-6 first cut gave delegated rows a single
 * breathing pip — which, one review later, read as the same dot the pane had
 * just been rid of. The grid is a different SHAPE, not just a different tempo,
 * and it carries two patterns so the two kinds of delegation stay distinct:
 *
 *   • ORBIT — a comet lapping the grid's perimeter, centre cell dark. A
 *     subagent: one worker off on a closed loop of its own.
 *
 *   • DRIVE — a chevron wavefront driving left-to-right; the cycle is shorter
 *     than the sweep so two fronts are always in flight. A workflow: staged
 *     work moving through a pipeline.
 *
 * The delays are per-cell `animationDelay`s on one shared `pixel-on` keyframe,
 * exactly as in the reference; only opacity animates.
 */

/** Chevron wavefront: column + distance-from-centre-row, 90ms per rank. */
const DRIVE_DELAYS: Array<number | null> = Array.from({ length: 9 }, (_, i) => {
  const row = Math.floor(i / 3);
  const column = i % 3;
  return (column + Math.abs(row - 1)) * 90;
});

/** The perimeter, clockwise from the top-left; the centre cell never lights. */
const ORBIT_ORDER = [0, 1, 2, 5, 8, 7, 6, 3];
const ORBIT_DELAYS: Array<number | null> = Array.from({ length: 9 }, (_, i) => {
  const step = ORBIT_ORDER.indexOf(i);
  return step === -1 ? null : step * 110;
});

export type WorkingGlyphVariant = "orbit" | "drive";

const GLYPH_PATTERNS: Record<WorkingGlyphVariant, { delays: Array<number | null>; duration: number }> = {
  orbit: { delays: ORBIT_DELAYS, duration: 950 },
  drive: { delays: DRIVE_DELAYS, duration: 650 }
};

export function WorkingGlyph({
  className,
  variant = "orbit"
}: {
  className?: string;
  variant?: WorkingGlyphVariant;
}) {
  const pattern = GLYPH_PATTERNS[variant];
  return (
    <span
      className={`dock-glyph pxgrid is-${variant}${className ? ` ${className}` : ""}`}
      aria-hidden="true"
    >
      {pattern.delays.map((delay, index) => (
        <i
          key={index}
          className={delay === null ? "is-off" : undefined}
          style={
            delay === null
              ? undefined
              : { animationDuration: `${pattern.duration}ms`, animationDelay: `${delay}ms` }
          }
        />
      ))}
    </span>
  );
}

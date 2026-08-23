import type { JSX } from "react";

interface IconProps {
  size?: number;
  className?: string;
}

function svg(path: JSX.Element, { size = 14, className }: IconProps, viewBox = "0 0 16 16") {
  return (
    <svg
      width={size}
      height={size}
      viewBox={viewBox}
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
      focusable="false"
    >
      {path}
    </svg>
  );
}

export const ChevronRight = (p: IconProps) => svg(<path d="M6 3.5 10.5 8 6 12.5" />, p);
export const ChevronDown = (p: IconProps) => svg(<path d="M3.5 6 8 10.5 12.5 6" />, p);
export const ChevronUp = (p: IconProps) => svg(<path d="M3.5 10 8 5.5 12.5 10" />, p);

export const Terminal = (p: IconProps) =>
  svg(
    <>
      <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2" />
      <path d="M4.75 6.5 6.75 8.25 4.75 10" />
      <path d="M8.5 10.25h3" />
    </>,
    p
  );

export const FileEdit = (p: IconProps) =>
  svg(
    <>
      <path d="M9 1.75H4.25A1.5 1.5 0 0 0 2.75 3.25v9.5a1.5 1.5 0 0 0 1.5 1.5h7.5a1.5 1.5 0 0 0 1.5-1.5V5.5Z" />
      <path d="M9 1.75V5.5h3.75" />
      <path d="M5.75 10.5 8 10l3.4-3.4a.9.9 0 0 0-1.3-1.3L6.75 8.75Z" />
    </>,
    p
  );

export const FileText = (p: IconProps) =>
  svg(
    <>
      <path d="M9 1.75H4.25A1.5 1.5 0 0 0 2.75 3.25v9.5a1.5 1.5 0 0 0 1.5 1.5h7.5a1.5 1.5 0 0 0 1.5-1.5V5.5Z" />
      <path d="M9 1.75V5.5h3.75" />
      <path d="M5.5 8.75h5M5.5 11h3.5" />
    </>,
    p
  );

export const Search = (p: IconProps) =>
  svg(
    <>
      <circle cx="7.25" cy="7.25" r="4.25" />
      <path d="m10.5 10.5 3 3" />
    </>,
    p
  );

export const Globe = (p: IconProps) =>
  svg(
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M1.75 8h12.5" />
      <path d="M8 1.75c1.6 1.7 2.5 3.9 2.5 6.25S9.6 12.55 8 14.25C6.4 12.55 5.5 10.35 5.5 8S6.4 3.45 8 1.75Z" />
    </>,
    p
  );

export const Sparkle = (p: IconProps) =>
  svg(
    <path d="M8 1.75 9.4 6 13.75 7.5 9.4 9 8 13.25 6.6 9 2.25 7.5 6.6 6Z" />,
    p
  );

export const Brain = (p: IconProps) =>
  svg(
    <>
      <path d="M6 2.75a2.25 2.25 0 0 0-2.25 2.25 2 2 0 0 0-.75 3.6v1.9A2.25 2.25 0 0 0 5.25 13H6Z" />
      <path d="M10 2.75A2.25 2.25 0 0 1 12.25 5a2 2 0 0 1 .75 3.6v1.9A2.25 2.25 0 0 1 10.75 13H10Z" />
      <path d="M8 2.5v11" />
    </>,
    p
  );

export const CheckCircle = (p: IconProps) =>
  svg(
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="m5.25 8.25 1.9 1.9 3.6-4" />
    </>,
    p
  );

export const Check = (p: IconProps) => svg(<path d="m3.25 8.5 3 3 6.5-7" />, p);

export const XCircle = (p: IconProps) =>
  svg(
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="m5.75 5.75 4.5 4.5M10.25 5.75l-4.5 4.5" />
    </>,
    p
  );

export const Close = (p: IconProps) => svg(<path d="m4 4 8 8M12 4l-8 8" />, p);

export const AlertTriangle = (p: IconProps) =>
  svg(
    <>
      <path d="M8 2.25 14.25 13H1.75Z" />
      <path d="M8 6.5v3.25M8 11.75v.01" />
    </>,
    p
  );

export const Info = (p: IconProps) =>
  svg(
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M8 7.25v4M8 4.75v.01" />
    </>,
    p
  );

/**
 * Two sheets, one behind the other.
 *
 * The previous draw had a 1.75-radius front sheet over a 1.5-radius back one,
 * offset 3.5px one way and 3.5px the other from an asymmetric origin (2.25 left,
 * 13.75 right) — so the two corners did not rhyme and the whole glyph sat right
 * of centre in its box. Redrawn on one grid: both sheets are 8×8 at r 2.25, the
 * offset is exactly 4px on both axes, and the margins are 2px on every side. The
 * back sheet is an outline that STOPS where the front one covers it, so at 12px
 * there is no doubled stroke tucked behind the front corner.
 */
export const Copy = (p: IconProps) =>
  svg(
    <>
      <rect x="6" y="6" width="8" height="8" rx="2.25" />
      <path d="M6 10H4.25A2.25 2.25 0 0 1 2 7.75v-3.5A2.25 2.25 0 0 1 4.25 2h3.5A2.25 2.25 0 0 1 10 4.25V6" />
    </>,
    p
  );

export const Wrap = (p: IconProps) =>
  svg(
    <>
      <path d="M2.5 4h11M2.5 8h8.25a2.25 2.25 0 0 1 0 4.5H8.5" />
      <path d="M10 10.75 8.5 12.5 10 14.25" />
    </>,
    p
  );

export const Layers = (p: IconProps) =>
  svg(
    <>
      <path d="M8 1.75 14.25 5 8 8.25 1.75 5Z" />
      <path d="m1.75 8 6.25 3.25L14.25 8" />
      <path d="m1.75 11 6.25 3.25L14.25 11" />
    </>,
    p
  );

export const List = (p: IconProps) =>
  svg(<path d="M5.5 4.25h8M5.5 8h8M5.5 11.75h8M2.5 4.25h.01M2.5 8h.01M2.5 11.75h.01" />, p);

export const Clock = (p: IconProps) =>
  svg(
    <>
      <circle cx="8" cy="8" r="6.25" />
      <path d="M8 4.75V8l2.25 1.5" />
    </>,
    p
  );

export const Shield = (p: IconProps) =>
  svg(<path d="M8 1.75 13.25 4v4c0 3.1-2.2 5.5-5.25 6.25C4.95 13.5 2.75 11.1 2.75 8V4Z" />, p);

export const ShieldCheck = (p: IconProps) =>
  svg(
    <>
      <path d="M8 1.75 13.25 4v4c0 3.1-2.2 5.5-5.25 6.25C4.95 13.5 2.75 11.1 2.75 8V4Z" />
      <path d="m5.75 7.75 1.6 1.6 3-3.2" />
    </>,
    p
  );

export const Map = (p: IconProps) =>
  svg(
    <>
      <path d="M2 4.25 6 2.75v9.5L2 13.75Z" />
      <path d="M6 2.75 10 4.25v9.5L6 12.25Z" />
      <path d="M10 4.25 14 2.75v9.5L10 13.75Z" />
    </>,
    p
  );

export const Cpu = (p: IconProps) =>
  svg(
    <>
      <rect x="4.75" y="4.75" width="6.5" height="6.5" rx="1.25" />
      <path d="M6.75 2v2M9.25 2v2M6.75 12v2M9.25 12v2M2 6.75h2M2 9.25h2M12 6.75h2M12 9.25h2" />
    </>,
    p
  );

export const Folder = (p: IconProps) =>
  svg(
    <path d="M1.75 4.25A1.5 1.5 0 0 1 3.25 2.75h2.6l1.4 1.75h5.5a1.5 1.5 0 0 1 1.5 1.5v5.5a1.5 1.5 0 0 1-1.5 1.5H3.25a1.5 1.5 0 0 1-1.5-1.5Z" />,
    p
  );

export const Plus = (p: IconProps) => svg(<path d="M8 3.25v9.5M3.25 8h9.5" />, p);

/** A neutral container — the honest glyph for a task type this build does not recognise. */
export const Box = (p: IconProps) =>
  svg(
    <path d="M8 1.9 13.5 5v6L8 14.1 2.5 11V5L8 1.9Zm-5.5 3L8 8m0 0 5.5-3.1M8 8v6.1" />,
    p
  );

export const Stop = (p: IconProps) =>
  svg(<rect x="4.25" y="4.25" width="7.5" height="7.5" rx="1.5" fill="currentColor" stroke="none" />, p);

export const ArrowUp = (p: IconProps) => svg(<path d="M8 12.75V3.5M4 7.25 8 3.25l4 4" />, p);

export const ArrowDown = (p: IconProps) => svg(<path d="M8 3.25v9.25M4 8.75 8 12.75l4-4" />, p);

export const Paperclip = (p: IconProps) =>
  svg(
    <path d="M11.75 7.5 7.4 11.85a2.6 2.6 0 0 1-3.68-3.68l5-5a1.75 1.75 0 1 1 2.47 2.47l-5 5a.9.9 0 0 1-1.27-1.27l4.5-4.5" />,
    p
  );

export const More = (p: IconProps) =>
  svg(<path d="M3.5 8h.01M8 8h.01M12.5 8h.01" strokeWidth={2} />, p);

export const History = (p: IconProps) =>
  svg(
    <>
      <path d="M2.75 8a5.25 5.25 0 1 0 1.6-3.78" />
      <path d="M2.25 2.75v3h3" />
      <path d="M8 5.25V8l2 1.25" />
    </>,
    p
  );

export const Bolt = (p: IconProps) => svg(<path d="M9 1.75 3.75 9h3.5l-.5 5.25L12.25 7h-3.5Z" />, p);

export const Scissors = (p: IconProps) =>
  svg(
    <>
      <circle cx="4" cy="4" r="1.75" />
      <circle cx="4" cy="12" r="1.75" />
      <path d="M5.4 5.15 13 12M13 4 5.4 10.85" />
    </>,
    p
  );

export const Refresh = (p: IconProps) =>
  svg(
    <>
      <path d="M13.25 8a5.25 5.25 0 1 1-1.6-3.78" />
      <path d="M13.75 2.75v3h-3" />
    </>,
    p
  );

export const Trash = (p: IconProps) =>
  svg(
    <>
      <path d="M2.75 4.25h10.5" />
      <path d="M6.25 4.25V3a.75.75 0 0 1 .75-.75h2a.75.75 0 0 1 .75.75v1.25" />
      <path d="M4.25 4.25 4.9 13a.75.75 0 0 0 .75.7h4.7a.75.75 0 0 0 .75-.7l.65-8.75" />
    </>,
    p
  );

export const ArrowLeft = (p: IconProps) => svg(<path d="M12.75 8H3.5M7.25 12 3.25 8l4-4" />, p);

/** Two sliders: the reasoning-effort affordance on a model row. A dial outline
    was tried first and read as a stray arc at 12px; the knob-on-a-track shape
    is legible at that size and is the universal "tune this" glyph. */
export const Sliders = (p: IconProps) =>
  svg(
    <>
      <path d="M2.5 5.25h3.25M8.75 5.25h4.75" />
      <path d="M2.5 10.75h4.75M10.25 10.75h3.25" />
      <circle cx="7.25" cy="5.25" r="1.6" />
      <circle cx="8.75" cy="10.75" r="1.6" />
    </>,
    p
  );

/** Counter-clockwise arrow into a bar: restore a setting to its default. */
export const Undo = (p: IconProps) =>
  svg(
    <>
      <path d="M2.75 5.25h6.5a3.5 3.5 0 0 1 0 7H6" />
      <path d="M5.25 2.75 2.5 5.25l2.75 2.5" />
    </>,
    p
  );

/** A square with a rounded corner: "open this somewhere else". */
export const ExternalLink = (p: IconProps) =>
  svg(
    <>
      <path d="M9.5 2.75h3.75V6.5" />
      <path d="m13.25 2.75-5 5" />
      <path d="M11.25 9.5v2.75a1.5 1.5 0 0 1-1.5 1.5h-6a1.5 1.5 0 0 1-1.5-1.5v-6a1.5 1.5 0 0 1 1.5-1.5H6.5" />
    </>,
    p
  );

/** Two diverging paths from one point: fork this session into a copy. */
export const Fork = (p: IconProps) =>
  svg(
    <>
      <circle cx="4.5" cy="3.5" r="1.75" />
      <circle cx="11.5" cy="3.5" r="1.75" />
      <circle cx="4.5" cy="12.5" r="1.75" />
      <path d="M4.5 5.25v5.5" />
      <path d="M11.5 5.25v1.5a2.5 2.5 0 0 1-2.5 2.5H4.5" />
    </>,
    p
  );

/** An arrow re-entering a box: resume this session in place. */
export const Resume = (p: IconProps) =>
  svg(
    <>
      <path d="M6.5 2.75h5a1.5 1.5 0 0 1 1.5 1.5v7.5a1.5 1.5 0 0 1-1.5 1.5h-5" />
      <path d="M9 8H2.75" />
      <path d="M5.25 5.5 2.75 8l2.5 2.5" />
    </>,
    p
  );

/**
 * Counter-clockwise arrow: the direction of travel is the whole meaning here.
 *
 * The previous draw put a 5.25 arc and a bare corner bracket in the same box
 * without joining them — the arc ended at (4.35, 4.22) and the bracket's corner
 * sat at (2.25, 5.75), so at 12px the head read as a stray tick floating beside
 * an almost-closed ring, and `History` (same file) was a strictly better drawing
 * of the same idea. Redrawn so the arc's TAIL runs into the corner: the head is
 * the termination of the stroke rather than an ornament near it, which is what
 * makes the direction legible at 12px instead of merely inferable.
 */
export const Rewind = (p: IconProps) =>
  svg(
    <>
      {/* A true 6-radius circle on the box's own centre (8, 8), so the ring
          touches all four margins evenly — the old 5.25 arc left the glyph
          floating small inside its box beside 13px siblings. It runs
          counter-clockwise from 9 o'clock the long way round and STOPS at
          (3.76, 3.76), which is exactly on the diagonal of the corner bracket
          below: the arrowhead is the termination of the stroke rather than a
          tick parked near it, which is what makes the direction readable at
          12px. */}
      <path d="M2 8a6 6 0 1 0 1.76-4.24" />
      <path d="M2 2v3.33h3.33" />
    </>,
    p
  );

export const Download = (p: IconProps) =>
  svg(
    <>
      <path d="M8 2.25v7.5M5 7l3 3 3-3" />
      <path d="M2.75 11.25v1.5a1 1 0 0 0 1 1h8.5a1 1 0 0 0 1-1v-1.5" />
    </>,
    p
  );

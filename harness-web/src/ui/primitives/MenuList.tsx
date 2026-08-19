import type { ReactNode } from "react";
import { Check } from "../Icons";

/**
 * The kit's row vocabulary, shared by every floating surface in the pane.
 *
 * One row shape, one section shape, one footer shape, one empty/loading shape.
 * A model row, a permission mode, a session, a slash command, and a workflow
 * phase are all THE SAME OBJECT as far as the eye is concerned — a 28px line
 * with an optional leading mark, a label that ellipsizes, optional trailing
 * metadata, and an optional check — and round 4's problem was that each of them
 * was drawn by hand instead. See `Popover.tsx` for the surface they sit on, the
 * motion they arrive with, and the shadcn decision.
 *
 * Round 6 adds the TYPOGRAPHIC tier the rows were missing. A section title, a
 * row label, a row's consequence line, and a trailing fact were four things
 * rendered at 11.5–13px in three greys, which is close enough to read as one
 * undifferentiated list: the report's "no typographic hierarchy". They are now
 * four deliberately separated tiers — see the `--menu-*` scale at the head of
 * `styles/menu.css` — and the label alone is allowed to be the row's ink.
 */

export function MenuList({
  children,
  className
}: {
  children: ReactNode;
  className?: string;
}) {
  return <div className={`ui-menu-list${className ? ` ${className}` : ""}`}>{children}</div>;
}

export function MenuSection({
  title,
  children,
  className
}: {
  title?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`ui-menu-section${className ? ` ${className}` : ""}`}>
      {title ? <div className="ui-menu-label">{title}</div> : null}
      {children}
    </div>
  );
}

export interface MenuItemProps {
  children: ReactNode;
  /** Leading glyph. The slot only exists for rows that have one. */
  icon?: ReactNode;
  onClick(): void;
  active?: boolean;
  danger?: boolean;
  /** The second line, when a row's consequence is not its name. */
  detail?: string;
  /** Trailing metadata — a fact about the row, never its state. */
  meta?: ReactNode;
  /** Row-specific modifier (the mode a row selects, the tone it carries). */
  className?: string;
  /**
   * Single-select groups (model, effort, permission mode) are `menuitemradio` so
   * the live choice is announced, not only drawn as a check glyph. Action-only
   * rows stay plain `menuitem`, which has no checked state to report.
   */
  role?: "menuitem" | "menuitemradio";
  title?: string;
  /** Suppresses the reserved check slot for lists with no selected state. */
  selectable?: boolean;
  disabled?: boolean;
}

export function MenuItem({
  children,
  icon,
  onClick,
  active,
  danger,
  detail,
  meta,
  className,
  role = "menuitem",
  title,
  selectable = true,
  disabled
}: MenuItemProps) {
  return (
    <button
      type="button"
      className={`ui-menu-item${active ? " is-active" : ""}${danger ? " is-danger" : ""}${
        className ? ` ${className}` : ""
      }`}
      role={role}
      aria-checked={role === "menuitemradio" ? !!active : undefined}
      onClick={onClick}
      title={title}
      disabled={disabled}
    >
      <span className="ui-menu-row">
        {/* Reserved only for rows that HAVE a glyph: reserving it
            unconditionally indented every label in the mode menu — a menu with
            no icons at all — by 22px of nothing. */}
        {icon ? (
          <span className="ui-menu-icon" aria-hidden="true">
            {icon}
          </span>
        ) : null}
        <span className="ui-menu-label-text">{children}</span>
        {meta ? <span className="ui-menu-meta">{meta}</span> : null}
        {/* Reserved on every row of a selectable list, checked or not: without
            the slot, selecting a mode pulls all four labels left as the check
            appears on a different one. */}
        {selectable ? (
          <span className="ui-menu-check" aria-hidden="true">
            {active ? <Check size={12} /> : null}
          </span>
        ) : null}
      </span>
      {detail ? <span className="ui-menu-detail">{detail}</span> : null}
    </button>
  );
}

/** The panel's base: what the list IS, and the keys that drive it. */
export function MenuFooter({ children }: { children: ReactNode }) {
  return <div className="ui-menu-foot">{children}</div>;
}

export function MenuKeys({ keys }: { keys: string[] }) {
  return (
    <span className="ui-menu-keys">
      {keys.map((key) => (
        <kbd key={key}>{key}</kbd>
      ))}
    </span>
  );
}

export function MenuEmpty({ children }: { children: ReactNode }) {
  return <div className="ui-menu-empty">{children}</div>;
}

export function MenuLoading({ children, glyph }: { children: ReactNode; glyph?: ReactNode }) {
  return (
    <div className="ui-menu-empty is-loading">
      {glyph}
      <span>{children}</span>
    </div>
  );
}

/**
 * A command-palette-style list: rows whose selection is driven by the KEYBOARD
 * rather than by focus, so the active row has to survive the pointer sitting
 * somewhere else. Used by the composer's slash/@ popover, which is typed at
 * while the caret stays in the textarea.
 */
export function CommandList({ children, label }: { children: ReactNode; label?: string }) {
  return (
    <div className="ui-cmd-list" role="listbox" aria-label={label}>
      {children}
    </div>
  );
}

/**
 * One completion row.
 *
 * The round-6 report called the slash menu out twice, and the shape was the
 * reason: name, argument hint and description were three baseline-aligned spans
 * on ONE line, so a command with a long description pushed its own name's
 * meaning off the right edge and every row was a different length of grey.
 *
 * It is a two-line row now — the command (mono, the pane's ink) over its
 * description (the meta tier) — which is the same object as a `MenuItem` with a
 * `detail`, and reads as one list rather than as a wrapped sentence per line.
 * The keyboard mark stays a tinted bed plus a leading accent bar, because ⏎ acts
 * on the MARKED row while the pointer may be hovering a different one.
 */
export function CommandItem({
  label,
  hint,
  detail,
  active,
  onPick
}: {
  label: string;
  hint?: string;
  detail?: string;
  active: boolean;
  onPick(): void;
}) {
  return (
    <button
      type="button"
      className={`ui-cmd-item${active ? " is-active" : ""}`}
      role="option"
      aria-selected={active}
      onMouseDown={(event) => {
        // The caret must not leave the textarea: a mousedown that moves focus
        // closes the popover before the click lands.
        event.preventDefault();
        onPick();
      }}
    >
      <span className="ui-cmd-line">
        <span className="ui-cmd-label mono">{label}</span>
        {hint ? <span className="ui-cmd-hint mono">{hint}</span> : null}
      </span>
      {detail ? <span className="ui-cmd-detail">{detail}</span> : null}
    </button>
  );
}

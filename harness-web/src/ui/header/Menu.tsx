import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Check } from "../Icons";

const ITEM_SELECTOR = '[role="menuitem"], [role="menuitemradio"]';

/** Every focusable stop inside the popup, in DOM order (menu rows plus inputs). */
function stopsIn(root: HTMLElement | null): HTMLElement[] {
  if (!root) return [];
  return Array.from(
    root.querySelectorAll<HTMLElement>(
      `${ITEM_SELECTOR}, button:not([disabled]), input:not([disabled])`
    )
  );
}

export function Menu({
  trigger,
  children,
  align = "end",
  className,
  label
}: {
  trigger: (open: boolean) => ReactNode;
  /**
   * `close(true)` hands focus back to this menu's trigger. Rows that OPEN
   * something say so, because the row itself unmounts with the popover: a dialog
   * launched from a menu has no surviving element to return focus to when it
   * closes, and focus lands on `<body>` — out of the app entirely. Rows that
   * merely act (compact, clear, new session) leave focus alone, so the next
   * printable key still reaches the composer.
   */
  children: (close: (restoreFocus?: boolean) => void) => ReactNode;
  align?: "start" | "end";
  className?: string;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  const close = useCallback((restoreFocus: boolean) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        close(true);
      }
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [close, open]);

  // Arrow keys move between rows and Tab cycles inside the popup: leaving Tab to
  // the browser walks into the NEXT header trigger while the popup stays mounted,
  // which is how a keyboard user ends up operating one menu from another's row.
  const onPopKeyDown = useCallback((event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp" && event.key !== "Tab") return;
    const stops = event.key === "Tab" ? stopsIn(pop.current) : Array.from(
      pop.current?.querySelectorAll<HTMLElement>(ITEM_SELECTOR) ?? []
    );
    if (stops.length === 0) return;
    event.preventDefault();
    const at = stops.indexOf(document.activeElement as HTMLElement);
    const back = event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey);
    const next = at < 0 ? (back ? stops.length - 1 : 0) : (at + (back ? -1 : 1) + stops.length) % stops.length;
    stops[next].focus();
  }, []);

  return (
    <div className={`menu${className ? ` ${className}` : ""}`} ref={root}>
      <button
        ref={triggerRef}
        type="button"
        className={`menu-trigger${open ? " is-open" : ""}`}
        onClick={() => setOpen((v) => !v)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={label}
      >
        {trigger(open)}
      </button>
      {open ? (
        <div
          className={`menu-pop is-${align}`}
          role="menu"
          aria-label={label}
          ref={pop}
          onKeyDown={onPopKeyDown}
        >
          {children((restoreFocus = false) => close(restoreFocus))}
        </div>
      ) : null}
    </div>
  );
}

export function MenuItem({
  children,
  icon,
  onClick,
  active,
  danger,
  detail,
  badge,
  role = "menuitem"
}: {
  children: ReactNode;
  /** Leading glyph; reserves its slot even when absent so labels stay aligned. */
  icon?: ReactNode;
  onClick: () => void;
  active?: boolean;
  danger?: boolean;
  detail?: string;
  /** Trailing tag such as "Default" — states a fact about the row, not its state. */
  badge?: string;
  /**
   * Single-select groups (model, effort, permission mode) are `menuitemradio` so
   * the live choice is announced, not only drawn as a check glyph. Action-only
   * rows stay plain `menuitem`, which has no checked state to report.
   */
  role?: "menuitem" | "menuitemradio";
}) {
  return (
    <button
      type="button"
      className={`menu-item${active ? " is-active" : ""}${danger ? " is-danger" : ""}`}
      role={role}
      aria-checked={role === "menuitemradio" ? !!active : undefined}
      onClick={onClick}
    >
      <span className="menu-item-main">
        <span className="menu-item-icon" aria-hidden="true">
          {icon}
        </span>
        <span className="menu-item-label">{children}</span>
        {badge ? <span className="menu-item-badge">{badge}</span> : null}
        {active ? <Check size={12} /> : null}
      </span>
      {detail ? <span className="menu-item-detail">{detail}</span> : null}
    </button>
  );
}

export function MenuSection({ title, children }: { title?: string; children: ReactNode }) {
  return (
    <div className="menu-section">
      {title ? <div className="menu-section-title">{title}</div> : null}
      {children}
    </div>
  );
}

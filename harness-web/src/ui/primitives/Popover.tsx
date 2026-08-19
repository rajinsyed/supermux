import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type RefObject
} from "react";

/**
 * The pane's ONE floating surface.
 *
 * Round 4 shipped five popovers that were each built where they were needed:
 * the header menus, the model panel, the sessions browser, the context
 * breakdown, and the composer's completion list. They agreed on nothing — three
 * radii, three paddings, two z-indexes, one with a shadow and four without, and
 * four separate copies of "close on outside mousedown, close on Escape, walk the
 * rows with the arrow keys". That is what "the pickers and menus still look
 * ugly" names: not one bad menu, but no menu system at all.
 *
 * Everything that floats now comes from this file and `MenuList.tsx`, and wears
 * the material declared once in `styles/menu.css` — a crisp hairline, one
 * radius, shadcn's layered popover shadow, and 13px rows on a 7px radius. A
 * surface that needs its own geometry passes a class; nothing re-declares the
 * material.
 *
 * shadcn itself was considered and NOT adopted: it is Tailwind + Radix + cva,
 * and this pane is an esbuild single-file bundle whose entire palette is CSS
 * custom properties audited for contrast in tests/contrast.test.ts. Adopting it
 * would mean either a second styling system beside the token layer (a
 * half-adoption, which the brief rules out) or rewriting the audited palette as
 * Tailwind theme values, which the audit could no longer read. What was taken
 * from shadcn is the part that was actually missing: the New York preset's
 * geometry, weights, and layered shadow, applied through the tokens already
 * here.
 */

const ROW_SELECTOR = '[role="menuitem"], [role="menuitemradio"], [role="option"]';
const STOP_SELECTOR = `${ROW_SELECTOR}, button:not([disabled]), input:not([disabled])`;

/** The selectable rows of a popup, in DOM order. */
export function popoverRows(root: HTMLElement | null): HTMLElement[] {
  if (!root) return [];
  return Array.from(root.querySelectorAll<HTMLElement>(ROW_SELECTOR));
}

/** Every focusable stop, rows plus the inputs and buttons between them. */
export function popoverStops(root: HTMLElement | null): HTMLElement[] {
  if (!root) return [];
  return Array.from(root.querySelectorAll<HTMLElement>(STOP_SELECTOR));
}

/**
 * Arrow keys walk the rows; Tab cycles inside the popup.
 *
 * Leaving Tab to the browser walks into whatever sits behind the popup — the
 * next header trigger, or the composer's send button — while the popup is still
 * mounted, which is how a keyboard user ends up operating one menu from
 * another's row. Shared so every surface in the kit behaves identically rather
 * than each re-deriving it.
 */
export function usePopoverKeys(
  pop: RefObject<HTMLElement | null>
): (event: React.KeyboardEvent<HTMLElement>) => void {
  return useCallback(
    (event: React.KeyboardEvent<HTMLElement>) => {
      if (event.key !== "ArrowDown" && event.key !== "ArrowUp" && event.key !== "Tab") return;
      const stops = event.key === "Tab" ? popoverStops(pop.current) : popoverRows(pop.current);
      if (stops.length === 0) return;
      event.preventDefault();
      const at = stops.indexOf(document.activeElement as HTMLElement);
      const back = event.key === "ArrowUp" || (event.key === "Tab" && event.shiftKey);
      const next =
        at < 0
          ? back
            ? stops.length - 1
            : 0
          : (at + (back ? -1 : 1) + stops.length) % stops.length;
      stops[next].focus();
    },
    [pop]
  );
}

export type PopoverSide = "top" | "bottom";
export type PopoverAlign = "start" | "end" | "stretch";

export interface PopoverSurfaceProps {
  /** Which way the panel opens. The dock sits at the pane's foot, so "top". */
  side?: PopoverSide;
  align?: PopoverAlign;
  /** Surface-specific geometry only (width, max-height). Never material. */
  className?: string;
  role?: string;
  label?: string;
  surfaceRef?: RefObject<HTMLDivElement | null>;
  onKeyDown?(event: React.KeyboardEvent<HTMLDivElement>): void;
  children: ReactNode;
}

/**
 * The bare floating panel, for surfaces whose OPEN state is owned elsewhere —
 * the composer's completion list is driven by what is in the textarea, not by a
 * trigger button, and the context breakdown opens on hover as well as click.
 */
export function PopoverSurface({
  side = "top",
  align = "end",
  className,
  role,
  label,
  surfaceRef,
  onKeyDown,
  children
}: PopoverSurfaceProps) {
  return (
    <div
      ref={surfaceRef}
      className={`ui-pop is-${side} is-${align}${className ? ` ${className}` : ""}`}
      role={role}
      aria-label={label}
      onKeyDown={onKeyDown}
    >
      {children}
    </div>
  );
}

export interface PopoverProps {
  trigger(open: boolean): ReactNode;
  /**
   * `close(true)` hands focus back to the trigger. Rows that OPEN something say
   * so, because the row itself unmounts with the popover: a dialog launched from
   * a menu has no surviving element to return focus to when it closes, and focus
   * lands on `<body>` — out of the app entirely. Rows that merely act (compact,
   * clear, new session) leave focus alone, so the next printable key still
   * reaches the composer.
   */
  children(close: (restoreFocus?: boolean) => void): ReactNode;
  side?: PopoverSide;
  align?: PopoverAlign;
  /** Wrapper class, for the trigger's own placement in its bar. */
  className?: string;
  /** Panel class, for surface-specific geometry. */
  popClassName?: string;
  label: string;
  role?: string;
  /** Fired on open — the sessions list loads its rows here. */
  onOpen?(): void;
  /**
   * Which row takes focus when the panel appears. Defaults to leaving focus on
   * the trigger; the model picker points it at the CHECKED row so ↑↓ walk the
   * list immediately and the ring lands on the model already in use.
   */
  autoFocus?: "checked" | "first" | "none";
}

export function Popover({
  trigger,
  children,
  side = "top",
  align = "end",
  className,
  popClassName,
  label,
  role = "menu",
  onOpen,
  autoFocus = "none"
}: PopoverProps) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const pop = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const onPopKeyDown = usePopoverKeys(pop);

  const close = useCallback((restoreFocus = false) => {
    setOpen(false);
    if (restoreFocus) triggerRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.stopPropagation();
      close(true);
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [close, open]);

  useEffect(() => {
    if (!open || autoFocus === "none") return;
    const node = pop.current;
    if (!node) return;
    const rows = popoverRows(node);
    const target =
      autoFocus === "checked"
        ? node.querySelector<HTMLElement>('[aria-checked="true"]') ?? rows[0]
        : rows[0];
    target?.focus();
  }, [autoFocus, open]);

  return (
    <div className={`menu${className ? ` ${className}` : ""}`} ref={root}>
      <button
        ref={triggerRef}
        type="button"
        className={`menu-trigger${open ? " is-open" : ""}`}
        onClick={() => {
          if (open) {
            close();
            return;
          }
          onOpen?.();
          setOpen(true);
        }}
        aria-haspopup={role === "menu" ? "menu" : "dialog"}
        aria-expanded={open}
        aria-label={label}
      >
        {trigger(open)}
      </button>
      {open ? (
        <PopoverSurface
          side={side}
          align={align}
          className={popClassName}
          role={role}
          label={label}
          surfaceRef={pop}
          onKeyDown={onPopKeyDown}
        >
          {children((restoreFocus = false) => close(restoreFocus))}
        </PopoverSurface>
      ) : null}
    </div>
  );
}

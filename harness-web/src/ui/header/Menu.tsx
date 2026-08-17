import { useEffect, useRef, useState, type ReactNode } from "react";
import { Check } from "../Icons";

export function Menu({
  trigger,
  children,
  align = "end",
  className,
  label
}: {
  trigger: (open: boolean) => ReactNode;
  children: (close: () => void) => ReactNode;
  align?: "start" | "end";
  className?: string;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        setOpen(false);
      }
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey, true);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey, true);
    };
  }, [open]);

  return (
    <div className={`menu${className ? ` ${className}` : ""}`} ref={root}>
      <button
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
        <div className={`menu-pop is-${align}`} role="menu">
          {children(() => setOpen(false))}
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
  detail
}: {
  children: ReactNode;
  /** Leading glyph; reserves its slot even when absent so labels stay aligned. */
  icon?: ReactNode;
  onClick: () => void;
  active?: boolean;
  danger?: boolean;
  detail?: string;
}) {
  return (
    <button
      type="button"
      className={`menu-item${active ? " is-active" : ""}${danger ? " is-danger" : ""}`}
      role="menuitem"
      onClick={onClick}
    >
      <span className="menu-item-main">
        <span className="menu-item-icon" aria-hidden="true">
          {icon}
        </span>
        <span className="menu-item-label">{children}</span>
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

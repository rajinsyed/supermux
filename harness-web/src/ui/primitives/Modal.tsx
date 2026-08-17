import { useCallback, useEffect, useRef, type ReactNode } from "react";
import { useCopy } from "../CopyContext";
import { Close } from "../Icons";

const FOCUSABLE =
  'button:not([disabled]), input:not([disabled]), textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])';

/**
 * A modal that does not trap focus is a modal only visually: Tab walks straight
 * out into the transcript behind it, where a screen reader then reads a
 * conversation the user cannot see and cannot act on. Escape closes, the
 * backdrop closes, and focus returns to whatever opened it.
 */
export function Modal({
  title,
  onClose,
  children
}: {
  title: string;
  onClose(): void;
  children: ReactNode;
}) {
  const copy = useCopy();
  const panel = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLElement | null>(null);

  useEffect(() => {
    opener.current = document.activeElement as HTMLElement | null;
    return () => opener.current?.focus?.();
  }, []);

  const onKeyDown = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;
      const stops = Array.from(panel.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? []);
      if (stops.length === 0) return;
      const at = stops.indexOf(document.activeElement as HTMLElement);
      const back = event.shiftKey;
      const next = at < 0 ? (back ? stops.length - 1 : 0) : (at + (back ? -1 : 1) + stops.length) % stops.length;
      event.preventDefault();
      stops[next].focus();
    },
    [onClose]
  );

  return (
    <div className="modal-scrim" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onClose();
    }}>
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        ref={panel}
        onKeyDown={onKeyDown}
      >
        <div className="modal-head">
          <h2 className="modal-title">{title}</h2>
          <button
            type="button"
            className="icon-btn modal-close"
            onClick={onClose}
            aria-label={copy("supermux.harness.a11y.closeDialog")}
          >
            <Close size={12} />
          </button>
        </div>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

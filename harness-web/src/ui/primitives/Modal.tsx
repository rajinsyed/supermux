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
 *
 * All three of those depend on focus being INSIDE the dialog to begin with —
 * Escape and Tab are handled on the panel, so a dialog nobody has clicked into
 * hears neither key, and Escape does nothing until the user has manually tabbed
 * in. Focus therefore moves here on mount, and every consumer gets that rather
 * than each remembering to arrange it. A consumer that wants a particular
 * control instead (the binary dialog puts the caret in its path field) still
 * wins: Modal is its CHILD, and child effects run before the parent's.
 *
 * Round 6 gives it the popover kit's own motion language rather than a second
 * one: the scrim fades and the panel scales up from its centre on the same
 * exponential ease-out, at the same 150ms. A dialog and a menu are the two
 * things in this pane that arrive over content, and arriving differently made
 * them read as parts of two different products. `prefers-reduced-motion` is
 * honoured by base.css's blanket rule plus the explicit reset in modal.css.
 *
 * Sizing is the consumer's: `size="compact"` is the tight 400px dialog the
 * rewind confirm wants, and the default is the 460px form panel.
 */
export function Modal({
  title,
  subtitle,
  size = "default",
  onClose,
  children
}: {
  title: string;
  /** One line under the title, for a dialog whose title is not the whole story. */
  subtitle?: string;
  size?: "default" | "compact";
  onClose(): void;
  children: ReactNode;
}) {
  const copy = useCopy();
  const panel = useRef<HTMLDivElement>(null);
  const opener = useRef<HTMLElement | null>(null);

  useEffect(() => {
    const active = document.activeElement;
    // `<body>` is what `document.activeElement` reports when nothing is focused,
    // and "restore focus to the body" is indistinguishable from restoring
    // nothing — worse, it would mask the case where a caller has a better answer
    // of its own (a rewind puts the caret back in the composer).
    opener.current =
      active instanceof HTMLElement && active !== document.body ? active : null;
    // The panel, not its first control: it is the neutral landing spot, it makes
    // the dialog's own label the first thing announced, and it pre-arms no
    // button. What matters is that focus is in here at all, because Escape and
    // the Tab trap both hang off this node.
    panel.current?.focus();
    return () => {
      const target = opener.current;
      // A trigger that was itself removed while the dialog was up is not worth
      // chasing: focusing a detached node silently focuses nothing.
      if (target && target.isConnected) target.focus();
    };
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
        className={`modal is-${size}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        ref={panel}
        // Programmatically focusable, never a Tab stop of its own: the trap
        // cycles the controls, and landing back on the panel mid-cycle reads as
        // focus vanishing.
        tabIndex={-1}
        onKeyDown={onKeyDown}
      >
        <div className="modal-head">
          <div className="modal-heading">
            <h2 className="modal-title">{title}</h2>
            {subtitle ? <p className="modal-subtitle">{subtitle}</p> : null}
          </div>
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

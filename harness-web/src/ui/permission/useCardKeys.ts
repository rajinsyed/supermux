import { useEffect, type RefObject } from "react";

/**
 * Window-level keyboard handling for a pending permission / question / plan
 * card.
 *
 * Two things make a naive `window.addEventListener("keydown")` wrong here:
 *
 * 1. The card's OWN buttons already handle Enter and Space natively. Letting the
 *    window handler fire as well double-fires the shortcut — focusing Deny and
 *    pressing Enter would run the button's onClick AND the window's Enter
 *    branch, allowing the request the user meant to deny. So events originating
 *    on an interactive element inside the card are left to that element.
 * 2. Text inputs must keep their own keys, but only the ones INSIDE the card
 *    (the deny reason, the free-text answer). A keystroke in the composer is a
 *    different question — see `swallowsPrintableKeys` in Composer.
 */
export function useCardKeys(
  cardRef: RefObject<HTMLElement | null>,
  handler: (event: KeyboardEvent) => void
): void {
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      const target = event.target as HTMLElement | null;
      if (target) {
        if (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable) {
          return;
        }
        // A focused control inside the card owns its own activation keys.
        if (
          cardRef.current?.contains(target) &&
          target.closest("button, a, [role='button'], [role='menuitem']")
        ) {
          if (event.key === "Enter" || event.key === " " || event.key === "Spacebar") return;
        }
      }
      handler(event);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [cardRef, handler]);
}

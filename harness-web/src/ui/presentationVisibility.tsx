import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react";
import type { HarnessStore } from "../model/store";

const PresentationVisibilityContext = createContext(true);

/**
 * Testable presentation-visibility seam. The renderer is wired to this provider
 * in the behavior commit; until then its default keeps every existing caller
 * visible and unchanged.
 */
export function PresentationVisibilityProvider({
  store,
  children
}: {
  store: HarnessStore;
  children: ReactNode;
}) {
  const visible = useSyncExternalStore(
    store.subscribePresentation,
    store.getPresentationVisible,
    store.getPresentationVisible
  );
  return (
    <PresentationVisibilityContext.Provider value={visible}>
      {children}
    </PresentationVisibilityContext.Provider>
  );
}

export function usePresentationVisible(): boolean {
  return useContext(PresentationVisibilityContext);
}
